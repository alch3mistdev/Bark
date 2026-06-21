# Implementation Plan: Voice Fingerprinting (Speaker Gate for Hands-Free)

**Branch**: `011-voice-fingerprinting` | **Date**: 2026-06-21 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/011-voice-fingerprinting/spec.md`

## Summary

Add an opt-in **speaker gate** to hands-free (continuous) dictation: only inject text when a
completed utterance matches the enrolled primary user's voice; silently decline other speakers
(coworker, TV, bystander) with a faint cue and keep listening. Implemented on-device and offline by
extracting a 256-d speaker embedding per utterance and comparing it (cosine similarity) to an enrolled
centroid, behind the existing optional `FLUIDAUDIO` build (graceful no-op stub in the lean build).
**Fail-open** everywhere — a missing/disabled/erroring gate never blocks the user's own dictation.
Framed honestly as a multi-speaker convenience filter, **not** anti-spoofing or authentication (a
recording or clone of the user still passes).

## Technical Context

**Language/Version**: Swift 6 (strict concurrency)

**Primary Dependencies**: None in the lean build. Optional: FluidAudio ≥0.7.9 (CoreML/ANE, Apache-2.0)
— already pulled by `Package-stt-extras.swift` for Parakeet STT; reused here for the WeSpeaker speaker
embedding. No new dependency, no SBOM delta.

**Storage**: `SpeakerProfile` (the voiceprint centroid + metadata) encrypted at rest with AES-256-GCM,
key in Keychain (`…WhenUnlockedThisDeviceOnly`), file `0600`, excluded from backup — same scheme as
`EncryptedHistoryStore`. Settings (two new fields) in `UserDefaults` via the existing tolerant codec.
The CoreML model bundle is cached under `~/Library/Application Support/Bark/models/` via `ModelStore`.

**Testing**: XCTest. Pure logic unit-tested in `BarkCoreTests` (lean build, stub embedder); hands-free
gate orchestration tested in `BarkAppTests` with an injected fake `SpeakerEmbedder` (mirrors
`HandsFreeTests`/`ScriptedAudioCapture`).

**Target Platform**: macOS 26+, Apple Silicon. Menu-bar desktop app.

**Project Type**: Desktop app — single SwiftPM package, three-layer split (`BarkCore` pure / `BarkEngines`
OS+ML adapters / `Bark` app).

**Performance Goals**: One embedding extraction per utterance on ANE (low tens of ms), overlapped with
existing cleanup via `async let`; **no user-perceptible delay** added to the user's own dictation (SC-004).

**Constraints**: Offline at runtime (no network except the one integrity-verified model download).
Realtime audio thread untouched. Utterance buffer bounded by the existing `maxUtteranceFrames` (~30 s ≈
≤1.9 MB). Voiceprint never leaves device.

**Scale/Scope**: One voiceprint per device (single primary user). ~7 new source files + edits to
`runHandsFree`, `Settings`, `CompositionRoot`, and the Settings/onboarding UI.

## Constitution Check

*GATE: must pass before Phase 0. Re-checked after Phase 1 design.*

| Principle | Status | How this plan satisfies it |
|---|---|---|
| **I. Offline-First, Privacy by Construction** | ✅ Pass | All enrollment + matching on-device. Voiceprint never transmitted. Only network event = the user-initiated, SHA-256-verified model download via existing `ModelManifest`/`ModelDownloader` (never FluidAudio's unverified `downloadIfNeeded`). No telemetry. |
| **II. Evidence or It Didn't Happen** | ✅ Pass | Pure decision logic unit-tested; gate tested with injected fake; e2e enroll/accept/reject demonstrated on the real model with **measured** strictness thresholds recorded before release (SC-002/003/007). |
| **III. Swappable Engines Behind Protocols** | ✅ Pass | New `SpeakerEmbedder` protocol in `BarkCore` (zero deps). Concrete `FluidAudioSpeakerEmbedder` + `NoopSpeakerEmbedder` stub in `BarkEngines`; pipeline depends only on the protocol + pure `SpeakerVerifier`. |
| **IV. Least Privilege & Safe Injection (NON-NEGOTIABLE)** | ✅ Pass | No new permission (reuses the mic already granted for dictation). The gate only **suppresses** injection — it never injects more, never synthesizes keys, never relaxes secure-field rules. Voiceprint is biometric-adjacent → encrypted at rest + opt-in + deletable. **Residual documented honestly**: convenience filter, not anti-spoofing/auth (FR-011). |
| **V. Speed-First, Non-Blocking** | ✅ Pass | Embedding runs off the MainActor on an actor, kicked off at utterance end and overlapped with cleanup; only the accept/reject decision is awaited at the gate. Fail-open guarantees the user's own dictation is never blocked by gate latency or error. |

**Quality gates**: voiceprint encrypted at rest + opt-in (✅); SBOM unchanged — FluidAudio already
recorded (✅); pure logic unit-tested, OS/ML adapter documented best-effort with named residuals (✅).

**Result**: No violations. Complexity Tracking left empty.

## Project Structure

### Documentation (this feature)

```text
specs/011-voice-fingerprinting/
├── plan.md              # This file
├── research.md          # Phase 0: model/threshold/API decisions
├── data-model.md        # Phase 1: entities (SpeakerEmbedding, SpeakerProfile, decision, sensitivity)
├── quickstart.md        # Phase 1: build + enroll + verify end-to-end
├── contracts/
│   ├── speaker-embedder.md      # SpeakerEmbedder protocol (the BarkCore↔BarkEngines seam)
│   ├── speaker-verifier.md      # Pure decision contract + sensitivity→threshold map
│   └── speaker-profile-store.md # Encrypted persistence contract
└── checklists/requirements.md   # (from /speckit-specify)
```

### Source Code (repository root)

```text
Sources/
├── BarkCore/Speaker/                         # NEW — pure, zero-dependency, unit-tested
│   ├── SpeakerEmbedding.swift                # [Float] wrapper: l2normalized, cosineSimilarity, mean
│   ├── SpeakerProfile.swift                  # centroid + sampleCount + enrolledAt + modelID
│   ├── SpeakerVerifier.swift                 # decide(utterance:profile:threshold:) -> SpeakerDecision
│   ├── SpeakerVerificationSensitivity.swift  # low/medium/high -> acceptThreshold (mirrors VADSensitivity)
│   └── SpeakerEmbedder.swift                 # protocol: embed([Float]) async throws -> SpeakerEmbedding
├── BarkEngines/Speaker/                      # NEW — OS/ML adapters
│   ├── FluidAudioSpeakerEmbedder.swift       # #if FLUIDAUDIO real impl / #else NoopSpeakerEmbedder stub
│   └── EncryptedSpeakerProfileStore.swift    # AES-256-GCM + Keychain (clone of EncryptedHistoryStore)
├── Bark/
│   ├── DictationController.swift             # EDIT — accumulate utteranceSamples; insert gate in runHandsFree
│   ├── SpeakerEnrollmentController.swift     # NEW — guided 5-phrase enrollment → centroid → store
│   ├── CompositionRoot.swift                 # EDIT — wire embedder + profile store + manifest
│   └── UI/SettingsView.swift, UI/OnboardingView.swift  # EDIT — gate toggle, strictness, enroll/delete, limits copy
└── BarkCore/Settings/Settings.swift          # EDIT — speakerGateEnabled, speakerSensitivity (tolerant decode)

Resources/manifest-speaker.json               # NEW — pinned HTTPS URL + SHA-256 for the embedding model bundle

Tests/
├── BarkCoreTests/SpeakerVerifierTests.swift            # NEW — cosine/mean/decide/sensitivity
└── BarkAppTests/HandsFreeSpeakerGateTests.swift        # NEW — accept/reject/fail-open with fake embedder
```

**Structure Decision**: Reuse the established three-layer split (constitution III). Only the 256-float
embedding extraction crosses into `BarkEngines`/CoreML; every other concern (cosine, averaging,
thresholding, decision, persistence shape, settings) is pure `BarkCore`. The adapter mirrors
`ParakeetEngine`'s `#if FLUIDAUDIO … #else <stub> #endif`; the store mirrors `EncryptedHistoryStore`.

## Complexity Tracking

> No constitution violations. Section intentionally empty.
