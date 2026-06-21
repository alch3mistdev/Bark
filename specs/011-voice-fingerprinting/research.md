# Research: Voice Fingerprinting (Speaker Gate)

Phase 0 — resolve technical unknowns. Source of truth: approved design at
`/Users/alch3mist/.claude/plans/cryptic-jingling-elephant.md` plus on-repo verification of the
FluidAudio/ParakeetEngine/ModelManifest/EncryptedHistoryStore patterns.

## D1 — Embedding model & library

**Decision**: Reuse **FluidAudio's WeSpeaker v2** speaker embedding (256-d, L2-normalized, CoreML/ANE,
Apache-2.0) behind the existing `FLUIDAUDIO` compile flag.

**Rationale**: FluidAudio is already an approved optional dependency (`Package-stt-extras.swift`, pulled
for Parakeet STT), so this adds **no new dependency and no SBOM delta**. It runs on the Neural Engine,
is fully offline once the model is local, and rides the existing `ModelManifest`/`ModelDownloader`/
`ModelStore` integrity-verified download machinery. The `#if FLUIDAUDIO … #else <stub>` pattern from
`ParakeetEngine.swift` gives a clean lean-build no-op.

**Alternatives considered**:
- *Apple Speech / SoundAnalysis (macOS 26)*: **rejected** — no public speaker-embedding or speaker-ID
  API. SoundAnalysis classifies sound events, not speaker identity.
- *ECAPA-TDNN (SpeechBrain) → CoreML, 192-d*: viable and ~equivalent accuracy, but requires owning a
  model-conversion + hosting pipeline. **Deferred** as the documented fallback if a non-FluidAudio lean
  build ever needs the gate. Same `SpeakerEmbedder` protocol, so swapping is local.
- *Resemblyzer / d-vector*: older, weaker; rejected.

## D2 — FluidAudio speaker API surface

**Decision**: Call the diarizer's single-utterance **embedding extractor** to get the 256 floats; load
models from the **locally verified path** via `DiarizerModels.load(localSegmentationModel:,localEmbeddingModel:)`
— never FluidAudio's networked `downloadIfNeeded()` (runtime network is banned by constitution I, and
it skips integrity verification, exactly the reason `ParakeetEngine` avoids `downloadAndLoad` when a
manifest is present).

**Rationale**: Mirrors the verified-load discipline already in `ParakeetEngine.prepare`.

**Risk / open at implementation (isolate to one line in the adapter)**: `extractEmbedding(_:)` is shown
in FluidAudio docs/examples but is thinly documented as stable public API in 0.7.9. If it is not public
on the pinned tag, fall back to running diarization on the single utterance and reading the per-speaker
256-d vector from `DiarizationResult.speakerDatabase`. The `SpeakerEmbedding` shape the pipeline reads is
the only contract — like `ParakeetEngine`'s note that "the `STTResult` shape we expose is the only
contract." Pin the exact FluidAudio version and re-verify the call site when the SDK is pulled in.

## D3 — Decision math, thresholds, sensitivity

**Decision**: Compare each utterance embedding to the enrolled **centroid** by **cosine similarity**
(both L2-normalized → dot product). Accept if `similarity ≥ threshold`. Expose a `low/medium/high`
sensitivity enum mirroring `VADSensitivity`, mapping to acceptance thresholds. **Starting** values
(to be calibrated on real device captures — these are not final):

| Sensitivity | acceptThreshold (cosine similarity) | Effect |
|---|---|---|
| low    | 0.40 | lenient — fewer self-rejections, more other-voices slip through |
| medium | 0.50 | default |
| high   | 0.62 | strict — for hostile rooms; more self-rejections |

**Rationale**: Short (1–3 s), possibly noisy command utterances are the worst case for text-independent
speaker verification — realistic EER is single-digit-to-low-teens %, not the ~0.7% clean-benchmark
figure. A lenient default with a tunable knob matches the convenience-gate intent. The enum + threshold
switch is the exact shape of `VADSensitivity.energyThreshold`.

**Polarity gotcha (recorded)**: FluidAudio's own `speakerThreshold` default is expressed as cosine
**distance** (~0.65). Bark works in cosine **similarity**. Do **not** pass FluidAudio's config through —
keep Bark's own similarity thresholds.

**Enrollment**: capture **5** short varied phrases, each ≥1.0 s voiced; embed each; `mean` (average +
re-normalize) → centroid. ≥1.0 s gate matches FluidAudio's `minSpeechDuration`. Reject/redo individual
takes that are too short/quiet without discarding good ones.

**Runtime input guard**: only score utterances with ≥1.0 s voiced audio; shorter → `tooShort` → fail-open.

## D4 — Security posture (honest framing)

**Decision**: Ship as a **convenience multi-speaker gate**, not a security control. v1 has **no**
anti-spoofing/liveness.

**Rationale & residuals (constitution IV: never overclaim a control)**:
- Reliably rejects **other people** (coworkers, TV, bystanders) → real value for shared/noisy rooms,
  and raises the bar on a bystander verbally injecting commands.
- Does **NOT** stop a recording/replay of the user's voice, nor a TTS voice-clone — both yield a
  near-identical embedding and are accepted. It is not liveness or authentication.
- Anti-spoofing (ASVspoof/AASIST-style) is a separate, heavier model with weak real-world generalization
  and extra false-rejects → **out of scope for v1**, noted as a possible future increment. Adding it now
  would risk overclaiming.
- In-app + README copy must state these limits plainly (FR-011, SC-007).

## D5 — Fail-open policy

**Decision**: The gate **fails open**. Inject as normal when: gate disabled, not enrolled, capability not
compiled (lean build), model bundle missing, utterance `tooShort`, or the embedder throws. Only an
explicit `reject` (matched check ran and scored below threshold) suppresses injection.

**Rationale**: This is a personal-machine convenience filter (constitution V — never block the user's own
dictation; matches `ParakeetEngine`'s "don't brick the app" ethos). Fail-closed is explicitly rejected
for v1 — a transient error must not lock a user out of their own dictation.

## D6 — Voiceprint storage (biometric-adjacent)

**Decision**: Persist `SpeakerProfile` with the **same** scheme as `EncryptedHistoryStore`: AES-256-GCM,
key in Keychain `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, file `0600`, excluded from backup. Use a
**distinct** `keyService` (`com.bark.speaker`) and account so deleting the voiceprint and purging history
are independent. Store a `modelID`/version tag in the profile so a future embedding-model change
invalidates an incompatible voiceprint (→ treated as not-enrolled, prompt re-enroll) rather than
silently mis-scoring.

**Rationale**: A voiceprint is sensitive personal data; the project already mandates encrypted-at-rest +
opt-in for transcripts (quality gates) — apply the same bar. Opt-in + easy delete satisfy least-privilege.

## D7 — Integration point in `runHandsFree`

**Decision**: Two surgical edits in `DictationController.runHandsFree` (the loop currently feeds frames to
STT but discards raw audio):
1. Accumulate `var utteranceSamples: [Float]` — seed with preroll where preroll is fed to STT (~L769),
   append next to `await stt.feed(frames)` (~L780), clear at finalize alongside `finalSegments`/`volatileTail`.
2. Insert the accept/reject gate in the `!transcript.isEmpty` branch, **after** `produceText` and the
   existing `guard handsFreeActive` (~L800) and **before** `performInjection` (~L803). Kick off
   `async let embedding = embedder.embed(utteranceSamples)` at capture-end so the ANE pass overlaps
   cleanup; await only the decision at the gate. On `reject`: skip injection, `machine.handle(.reset)`,
   faint cue, **continue** the loop (not an error). All other outcomes → inject (fail-open, D5).

**Rationale**: Push-to-talk is untouched (already deliberate intent, FR-008). Overlap keeps added latency
imperceptible (SC-004). Per-utterance reject must not tear down the session (FR-014), consistent with the
existing `ADV-001` per-utterance-resilience comments in the loop.

## Open items carried to tasks
1. Verify `extractEmbedding` public API on pinned FluidAudio tag; else `speakerDatabase` fallback (D2).
2. Obtain the WeSpeaker + segmentation CoreML bundle URL + SHA-256 + size for `manifest-speaker.json`.
3. Calibrate `low/medium/high` thresholds on real noisy captures; record measured accept/reject rates
   (SC-002/003/007) before release.
