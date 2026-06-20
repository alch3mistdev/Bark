# ADR-006 — Pluggable STT backends behind `STTEngineFactory`

**Status:** Accepted
**Date:** 2026-06-19
**Context:** ADR-002 left `ParakeetEngine` / `WhisperKitEngine` as a future
adapter; the README documented them as "designed, wired via protocols, not yet
implemented". This ADR closes that gap and adds the download path needed for
non-Apple backends, including the SHA-256 verification promised by SEC-003.

## Context

The day-1 pipeline ships only `SpeechAnalyzerEngine` (Apple, macOS 26). Two
additional backends were named in ADR-002 but never wired:

- **WhisperKit** (Argmax) — Whisper on Core ML, ANE-friendly, 99+ languages,
  broader accent / noise robustness than Apple STT, ~200–600 ms typical latency
  vs ~55–60 ms for Apple STT.
- **Parakeet TDT-0.6b-v3** via **FluidAudio** — Core ML, ANE, 25 languages,
  Apache-2.0, narrow decoder that sits between Apple's STT and WhisperKit on
  the latency / coverage trade-off.

Both require model weights that are *not* bundled with the OS (Apple STT gets
its weights from a locale asset installed by the system on first use). Without
a download / verify path, adopting either backend would require either
pre-bundling multi-GB weights in the `.app` (wasteful) or shipping an
unverified downloader (a security regression flagged in SECURITY.md ☐ for
SEC-003 / T-010).

## Decision

### 1. `STTEngineFactory` selects the backend at composition time

`Sources/BarkEngines/STT/STTEngineFactory.swift` is the single seam. It maps a
persisted `STTBackendID` (`.apple | .whisperkit | .parakeet`) to a concrete
`STTEngine`. If the persisted backend is not compiled into the running binary,
the factory falls back to `SpeechAnalyzerEngine()` and logs a one-shot warning
— a stale setting from a future build can never brick the app.

### 2. Backends compile behind `#if` flags, mirroring the MLX pattern

`Sources/BarkEngines/STT/WhisperKitEngine.swift` and
`Sources/BarkEngines/STT/ParakeetEngine.swift` each have two definitions:

- Under `#if WHISPERKIT` / `#if FLUIDAUDIO`: the real actor wrapping the
  vendor SDK. Push-to-stream protocol is preserved by `AsyncThrowingStream`.
- Under `#else`: a stub `final class` that conforms to `STTEngine` and throws
  `.engineFailure("... not compiled in this build")` on `prepare`. This keeps
  the lean `Package.swift` (no external deps, fully offline build, 72 tests)
  runnable and testable.

The opt-in manifest `Package-stt-extras.swift` adds the WhisperKit and
FluidAudio SwiftPM dependencies and defines `WHISPERKIT` + `FLUIDAUDIO`. It
mirrors `Package-mlx.swift` exactly: lean default, opt-in extension, simple
swap with `git checkout Package.swift` to revert.

### 3. SHA-256-verified model download (`SEC-003 / T-010`)

`Sources/BarkEngines/STT/ModelManifest.swift` defines the integrity schema:

```json
{
  "modelID":  "whisper-large-v3-turbo-coreml",
  "backend":  "whisperkit",
  "url":      "https://...",
  "sha256":   "<64-char hex>",
  "sizeBytes": 821456789
}
```

`ModelDownloader` (`Sources/BarkEngines/STT/ModelDownloader.swift`) is the
actor that resolves a manifest to a verified on-disk path:

1. If a cached file matches the manifest's SHA-256, return it (cache hit).
2. Otherwise download (HTTPS-only), verify SHA-256, atomically move into
   `~/Library/Application Support/Bark/models/<backend>--<model>.bin`.
3. Hash mismatch → delete the file, throw `ModelError.hashMismatch`. **Never**
   written to the cache path. (SEC-003)
4. Size mismatch → throw `ModelError.sizeMismatch`. (Defense-in-depth; the
   manifest's size is independently checked before hashing.)

`ModelStore` (`Sources/BarkEngines/STT/ModelStore.swift`) is the on-disk
location helper. Stable paths derived from `(backend, modelID)`, not from the
URL — so re-pointing a manifest at a mirror does not invalidate the cache.

Manifests are bundled in the app (read at composition time); they are NOT
fetched at runtime. A future hardening — detached ed25519 manifest signature
verified against a baked-in public key — is documented as the next step.

### 4. UI surfaces the choice, hides uncompiled backends

`Settings.sttBackend` (default `.apple`) is persisted through the existing
tolerant decode so older settings payloads upgrade silently. The Settings UI
shows a picker containing only `STTBackendID.allCases.filter { $0.isCompiledIn }`,
so the lean build never offers a choice it can't honour.

A live `controller.sttBackend` setter rebuilds the engine via the factory and
triggers `prepareModel`. Mid-session swaps are refused (single-use analyzer;
see ADV-007 in `SpeechAnalyzerEngine`).

## Consequences

- **Lean build stays lean.** `swift build` / `swift test` still run with zero
  external dependencies, fully offline. 72 existing tests + 22 new tests all
  pass in the lean build.
- **Privacy posture is preserved.** No new network events beyond a
  user-initiated model download over HTTPS. The SHA-256 check closes the
  SECURITY.md ☐ for SEC-003 / T-010.
- **The protocol contract is unchanged.** `STTEngine`, `AudioFrames`,
  `STTResult`, `STTError` are all that the rest of the app knows. Real
  adapters slot in behind `#if` flags with no edits to `DictationController`,
  tests, or settings UI plumbing.
- **Trade-offs surfaced to the user, not hidden.** Apple STT is the default
  because it's the fastest and zero-weight. WhisperKit is opt-in for users who
  need wider language coverage; the model download is consented explicitly
  (the user toggles the backend on, which triggers `prepareModel`, which
  downloads).
- **Future hardening tracked.** Manifest signing (detached ed25519) is the
  obvious next step — it would let manifests be fetched at runtime from a
  pinned URL without weakening SEC-003. Out of scope for this PR.

## Alternatives considered

- **Ship the model weights in the `.app`.** Rejected: 2.5–10 GB per backend
  inflates the binary, breaks delta updates, and complicates notarization.
- **Single WhisperKit backend that subsumes Apple STT.** Rejected: WhisperKit's
  cold-start latency on Apple Silicon is materially worse than
  `SpeechAnalyzer` for English (~200–600 ms vs ~55–60 ms), and Apple STT has
  zero bundled weight. Apple STT is the right default; WhisperKit is the
  right opt-in for non-English / heavy-accent workloads.
- **Use `swift-huggingface` directly.** Rejected for parity with the MLX
  build (which already pulls it), but kept as a follow-up: once a single
  downloader abstracts the SDK, both engines can share the same fetch path.
  For now each backend uses its native loader; the manifest layer sits above
  both.

## Verification

- `swift build` clean (lean build, no new errors).
- `swift test` — 94 tests pass (72 existing + 22 new: manifest, downloader,
  factory, stub conformance, settings round-trip).
- Manual: lean build shows only `.apple` in the picker; switching to
  `Package-stt-extras.swift` adds `.whisperkit` and `.parakeet`.
- SHA-256 verified against published vectors in
  `Tests/BarkAppTests/ModelManifestTests.swift`.
- SECURITY.md ☐ → ☑ for SEC-003 / T-010 (downloaded model path now
  sha256-verified).
