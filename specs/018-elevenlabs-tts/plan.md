# Implementation Plan: Opt-in cloud TTS for spoken discussion replies

**Branch**: `018-elevenlabs-tts` | **Date**: 2026-09-15 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/018-elevenlabs-tts/spec.md`

## Summary

Add a second `SpeechSynthesizing` conformer that synthesizes discussion replies through the
ElevenLabs HTTP API and plays the returned audio, selectable in Settings ▸ Discuss and off by
default. A composite conformer speaks through the on-device system voice whenever the cloud path
fails, so Principle I's "fail toward the local engine" is structural rather than a code path that
has to remember to do the right thing. The 017 seam already carries everything needed — `speak`
returns on playback completion and never throws — so no controller, state-machine, or overlay
change is required.

## Technical Context

**Language/Version**: Swift 6 (Xcode 26 toolchain), strict concurrency

**Primary Dependencies**: Foundation `URLSession` (ephemeral), AVFoundation `AVAudioPlayer` for
MP3 playback. No new third-party dependencies, no MLX involvement.

**Storage**: API key in the Keychain (`KeychainSecretStore`, new account
`elevenlabs-api-key`). Backend/model/voice IDs in the existing settings blob. Synthesized audio is
held in memory for the duration of playback and never written to disk.

**Testing**: XCTest via `swift test` — pure request/response shaping in `BarkCoreTests`; the
synthesizer and the fallback composite in `BarkAppTests` against a `URLProtocol` stub (the
pattern already established by `OpenAICompatClientTests`); half-duplex and
failure-never-stalls assertions in the existing discussion flow suites.

**Target Platform**: macOS 26+ on Apple Silicon

**Project Type**: Desktop menu-bar app (existing SwiftPM workspace)

**Performance Goals**: `eleven_flash_v2_5` publishes ~75 ms TTFB; with network RTT a short reply
is expected to begin playing within a few hundred milliseconds. Request deadline 10 s, after
which the fallback speaks — a turn can never hang.

**Constraints**: Only the reply string is transmitted, truncated to a documented bound; no raw
audio, capture, transcript, or dictation ever leaves the device. Off by default. The key never
enters the settings payload. The half-duplex invariant must hold on the cloud, fallback, and stop
paths.

**Scale/Scope**: 3 modules touched; ~5 new source files, ~4 edited; 3 new settings fields; one new
Keychain account; no new permissions (no microphone or accessibility implications — this is
audio output only).

## Constitution Check

*GATE: evaluated pre-Phase-0 and re-checked post-design — PASS with one documented carve-out,
recorded as ADR-012 with user sign-off (this session, 2026-09-15).*

- **I. Offline-First, Privacy by Construction**: **CARVE-OUT, mirroring ADR-010.** This
  transmits user-derived content to a third party, which the constitution permits only as an
  explicitly opt-in, per-feature, warned path that fails toward the local engine, with
  credentials in the Keychain and no captured content persisted. Every one of those conditions is
  implemented: default off; a warning naming exactly what is and is not sent (and explicitly
  declining to claim the text is Bark-authored only, since replies can quote the screen or the
  user); `FallbackSpeechSynthesizer` makes local the failure direction; ephemeral URL session;
  nothing persisted. Amendment recorded in the constitution's history and in ADR-012.
- **II. Evidence or It Didn't Happen**: PASS. Stubbed-endpoint tests cover success, 401, 429,
  transport failure, malformed body, and deadline; a "no network when backend is system" test
  fails if the session is touched; a settings-payload test asserts key absence. Live-key latency
  is explicitly *not* claimed as verified.
- **III. Swappable Engines Behind Protocols**: PASS — this is the 017 `SpeechSynthesizing` seam
  being used as designed. Pure request shaping lives in `BarkCore`; the network and playback
  live in `BarkEngines`; the controller is untouched.
- **IV. Least Privilege & Safe Injection (NON-NEGOTIABLE)**: PASS. No new permissions. Nothing
  about injection, secure-field policy, or Return synthesis is touched — this feature produces
  sound, never keystrokes.
- **V. Speed-First, Non-Blocking**: PASS. Deadline-bounded with a local fallback, so a slow
  network degrades the voice rather than the conversation.

## Project Structure

### Documentation (this feature)

```text
specs/018-elevenlabs-tts/
├── spec.md              # Feature specification
├── plan.md              # This file
├── contracts/
│   └── cloud-tts.md     # Wire contract + fallback semantics
└── tasks.md             # Phase 2
```

### Source Code (repository root)

```text
Sources/
├── BarkCore/Speech/
│   ├── DiscussionTTSBackend.swift        # NEW — system | elevenLabs
│   ├── CloudTTSRequest.swift             # NEW — pure URL/body shaping, text bound,
│   │                                     #   voice-list decoding, SpeechSynthesisError
│   └── SpeechSynthesizing.swift          # unchanged (017 seam already sufficient)
├── BarkEngines/Speech/
│   ├── ElevenLabsSynthesizer.swift       # NEW — URLSession + AVAudioPlayer conformer
│   └── FallbackSpeechSynthesizer.swift   # NEW — primary → local composite
└── Bark/
    ├── DiscussionController.swift        # EDIT — backend/key/voice settings surface,
    │                                     #   voice fetch, one-shot error surfacing
    ├── CompositionRoot.swift             # EDIT — build the composite synthesizer
    └── UI/Settings/DiscussionPane.swift  # EDIT — backend picker, key field, model/voice,
                                          #   fetch button, privacy warning
Sources/BarkCore/Settings/Settings.swift  # EDIT — 3 fields (tolerant decoder)

Tests/
├── BarkCoreTests/
│   └── CloudTTSRequestTests.swift        # NEW — URL shapes, body, truncation, decode, errors
└── BarkAppTests/
    ├── ElevenLabsSynthesizerTests.swift  # NEW — stubbed endpoint: success/401/429/transport/
    │                                     #   malformed/deadline; header and body assertions
    └── DiscussionTTSGatingTests.swift    # EDIT — half-duplex + no-stall across the new paths
```

**Structure Decision**: Same split as 015/016/017 — pure logic in `BarkCore`, OS/network adapters
in `BarkEngines`, orchestration/UI in `Bark`. No new targets, no new dependencies.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| Principle I carve-out: transmits user-derived text to a third party | No local model reaches the quality the user requires; the best local candidate (Kokoro-82M) renders `?` identically to `.` (kokoro #78/#194/#264), which is disqualifying for a feature whose output is questions | Staying local was tried first and shipped (the voice-tier fix in 017); it improves the system voice but cannot close the gap. Keeping the feature silent-but-offline was rejected by the user, who asked explicitly for ElevenLabs-grade output |
