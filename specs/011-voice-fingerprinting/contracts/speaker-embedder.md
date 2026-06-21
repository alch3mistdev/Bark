# Contract: SpeakerEmbedder

The single seam between pure `BarkCore` logic and the CoreML/ML adapter in `BarkEngines`. The only place
the 256-float extraction crosses the layer boundary (constitution III).

## Protocol (BarkCore)

```swift
public protocol SpeakerEmbedder: Sendable {
    /// Produce a speaker embedding from 16 kHz mono Float PCM samples.
    /// - Returns: an L2-normalized SpeakerEmbedding (256-d for WeSpeaker v2).
    /// - Throws: if the model is unavailable or extraction fails. Callers MUST
    ///   treat any throw as fail-open (inject as normal) — never block dictation.
    func embed(_ samples: [Float]) async throws -> SpeakerEmbedding

    /// The model/version tag stamped into enrolled profiles, so an incompatible
    /// stored voiceprint is detected and re-enrollment is prompted.
    var modelID: String { get }
}
```

## Implementations (BarkEngines)

### `FluidAudioSpeakerEmbedder` — `#if FLUIDAUDIO`
- `actor`. Lazily loads `DiarizerModels.load(localSegmentationModel:,localEmbeddingModel:)` from the
  **verified** local path returned by `ModelDownloader.ensureModel(for: manifest-speaker)`. **Never**
  calls FluidAudio's networked `downloadIfNeeded()` (constitution I; mirrors `ParakeetEngine.prepare`).
- `embed(samples)` → diarizer embedding extractor → wrap 256 floats → `l2normalized()`.
- `modelID` = the WeSpeaker bundle's `modelID` from the manifest.
- **Implementation risk (research D2)**: confirm `extractEmbedding(_:)` is public on the pinned tag; else
  fall back to `DiarizationResult.speakerDatabase`. Isolate to one call site.

### `NoopSpeakerEmbedder` — `#else` (lean build)
- `embed(_:)` throws `engineFailure("Speaker ID not compiled in this build. Use Package-stt-extras.swift and rebuild.")`.
- `modelID` = `"noop"`.
- Keeps the lean pipeline runnable; callers fail-open, so dictation is unaffected.

## Caller obligations (DictationController)
- Call `embed` **only** when: `speakerGateEnabled` && profile enrolled && profile.modelID == embedder.modelID
  && voiced duration ≥ 1.0 s. Otherwise skip and inject (fail-open).
- Run off the MainActor; kick off via `async let` at utterance end; await only at the gate.
- Any thrown error ⇒ inject (fail-open) + `BarkLog` at debug.

## Test double
`FakeSpeakerEmbedder` (in `BarkAppTests`): returns a configured embedding (or throws) for scripted
accept / reject / error scenarios. No FluidAudio dependency, runs in the lean test build.
