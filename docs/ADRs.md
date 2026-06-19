# Architecture Decision Records — Bark

Condensed from the design phase (ef-architect, cross-checked with Codex). Status: Accepted.

## ADR-001 — Native Swift / SwiftUI, single process
**Decision.** Native Swift 6 + SwiftUI `MenuBarExtra`, one process.
**Why.** The whole product is realtime audio + ANE speech + global hotkey + cross-app text
injection — all native Apple-Silicon APIs with first-class Swift bindings. Electron ships ~150 MB of
Chromium and still needs native shims for every privileged API; Python+Tauri adds a runtime and a
webview without solving the realtime/ANE path.
**Consequence.** macOS-only; Swift 6 strict concurrency (good — forces the actor isolation we want).
App Sandbox is **not** viable with a global `CGEventTap` + Accessibility injection → ship
**non-sandboxed, Developer-ID notarized** (not Mac App Store). See ARCH-006.

## ADR-002 — Swappable `STTEngine` protocol
**Decision.** `protocol STTEngine` with `SpeechAnalyzerEngine` (Apple, macOS 26) as the day-1 default;
`ParakeetEngine` / `WhisperKitEngine` drop in later behind the same protocol.
**Why.** ef-ai-ml picks Apple SpeechAnalyzer for speed (≈55–60 ms latency, ANE, zero bundled model
weight, fully offline after the locale asset installs) with Parakeet TDT-0.6b-v3 (25 languages) as the
multilingual fallback. The pipeline must not be coupled to either.
**Consequence.** A stable `AudioFrames` / `STTResult` contract; per-engine asset/download semantics
hidden behind `prepare()`.

## ADR-003 — LLM cleanup via MLX-Swift, behind `TextCleaner`
**Decision.** `protocol TextCleaner` with two impls: `BasicTextCleaner` (deterministic, always on) and
`MLXTextCleaner` (Qwen3-4B-Instruct 4-bit via MLX-Swift, optional).
**Why.** MLX is Apple's blessed on-Silicon inference path; Qwen3-4B-4bit is the best rewrite quality at
~40–60 tok/s on M3 Pro. But the LLM stage costs ~0.7–1.2 s, so it must never block delivery.
**Consequence.** Deterministic text is produced first and always; the LLM only runs for LLM-modes,
is timeout-bounded and cancellable, and falls back to deterministic output on any failure (ARCH-004).
LLM is a build-time opt-in so the core stays fast/offline/verifiable (see README).

## ADR-004 — Text injection strategy
**Decision.** Default `PasteboardInjector` (snapshot full clipboard → set text → ⌘V → restore);
automatic `KeystrokeInjector` fallback for terminals / when paste is rejected.
**Why.** Pasteboard+⌘V is fast and Unicode/emoji/IME-safe in one shot; per-character synthesis is the
fragile fallback.
**Consequence (mandatory controls).** Refuse secure/password fields and when Secure Input is active;
never synthesize Return/Enter; snapshot **all** pasteboard types (string-only restore is data loss);
guard restore with `changeCount`; re-verify focused window before injecting (ARCH-001/005, SEC-002/004/005/007).

## ADR-005 — Packaging & model distribution
**Decision.** Ship an Xcode/SwiftPM-built `.app`, Developer-ID signed + hardened-runtime + notarized,
outside the Mac App Store. Speech models are **not bundled** — the OS installs the SpeechAnalyzer
locale asset on first use; any future downloaded model is sha256-verified.
**Why.** A menu-bar app needs `LSUIElement`, usage strings, entitlements; models are large and update
independently. CGEventTap + Accessibility forbid the MAS sandbox.
**Consequence.** A notarization step (`scripts/make-app.sh` + `notarytool`); first-run asset install is
the only network event; offline thereafter.

## ADR-006 — Pluggable STT backends behind `STTEngineFactory`
**Decision.** Add WhisperKit and Parakeet TDT (via FluidAudio) as optional `STTEngine`
implementations, selected by `STTEngineFactory` from a persisted `Settings.sttBackend`. The
opt-in manifest `Package-stt-extras.swift` adds the SwiftPM dependencies and the `WHISPERKIT` /
`FLUIDAUDIO` flags; the lean build compiles stub implementations that throw a clear "not
compiled in this build" error so the pipeline stays runnable offline. Model downloads are
sha256-verified against a bundled `ModelManifest` (`ModelDownloader.ensureModel`); mismatch
deletes the file and never writes it to the cache (`SEC-003 / T-010`).
**Why.** ADR-002 named these adapters as a future extension; this closes that gap with the
smallest possible surface (one factory + one manifest schema + one downloader). It also closes
the SECURITY.md ☐ for downloaded-model integrity and gives WhisperKit users a clear path to
opt in without compromising the lean build's offline guarantees.
**Consequence.** Lean build is unchanged. Extras build adds two backends and a model
download path. Settings UI hides uncompiled backends. Stale settings from a future build can
never brick the app — the factory falls back to `SpeechAnalyzerEngine()` and logs a warning.
See `docs/ADR-006-stt-engine-selection.md` for the full record (alternatives, verification).

