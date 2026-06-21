# Quickstart: Voice Fingerprinting (Speaker Gate)

End-to-end validation that the speaker gate works. Two tracks: **lean** (proves no regression + pure logic
+ fail-open via stub) and **full** (proves real matching with the FluidAudio model).

## Prerequisites
- macOS 26+, Apple Silicon.
- A microphone with granted permission (existing Bark onboarding).
- For the full track: network access once to download the verified embedding model bundle; thereafter offline.

## Track A — Lean build (no FluidAudio): regression + unit + fail-open

```sh
# Default lean manifest is active (Package.swift). Build + test.
swift build
swift test
```

**Expected**
- `SpeakerVerifierTests` pass: cosine/mean/decide boundaries + sensitivity→threshold map.
- `HandsFreeSpeakerGateTests` pass: with the stub/`Noop` embedder (throws), the gate **fails open** —
  the user's own dictation is still injected; session keeps listening.
- All pre-existing tests still green (no regression; SC-005).

## Track B — Full build (FluidAudio): real enrollment + matching

```sh
cp Package-stt-extras.swift Package.swift     # opt into WhisperKit + FluidAudio (FLUIDAUDIO flag)
swift build -c release                        # first build compiles CoreML — slow
swift run Bark                                # or launch the packaged .app
git checkout Package.swift                    # revert to lean default when done
```

In the app:
1. **Settings → Hands-free → Speaker gate**: toggle **on** (off by default). If the model isn't present,
   accept the one-time verified download prompt.
2. **Enroll**: read the 5 short prompted phrases. Confirm "voiceprint saved". A too-short/too-quiet take
   asks for a re-record without losing the others.
3. **Accept (own voice)**: start hands-free, speak a sentence → it is typed as normal, no added delay.
4. **Reject (other voice)**: have a second person speak, or play a recording of a *different* person from
   a phone → **nothing is typed**, a faint cue distinct from the success sound plays, the session keeps
   listening (not stopped, no error).
5. **Strictness**: set sensitivity high → marginal non-you utterances are rejected more often; low → more
   lenient. Default medium.
6. **Honesty check**: read the gate's description — it must state it filters other speakers but does NOT
   stop a recording/clone of *your* voice and is not authentication (FR-011, SC-007).
7. **Fail-open checks**: delete the voiceprint → hands-free injects normally again (gate inert). Disable
   the gate → behaves exactly as before.
8. **Privacy check**: confirm `~/Library/Application Support/Bark/speaker.enc` exists, is `0600`, and is
   not plaintext; `delete voiceprint` removes it and its Keychain key.

## Calibration note (before release)
Record measured accept rate for the enrolled user (target ≥95% quiet-room, SC-002) and reject rate for a
different speaker (target ≥80% quiet-room, SC-003) across low/medium/high, and finalize the threshold
constants in `SpeakerVerificationSensitivity` (research D3). Evidence per constitution II.

## Maps to
- Spec acceptance scenarios US1 (steps 1–2, 7–8), US2 (steps 3–4, Track A fail-open), US3 (steps 5–6).
- Contracts: `speaker-embedder.md`, `speaker-verifier.md`, `speaker-profile-store.md`.
