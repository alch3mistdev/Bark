# Tasks: Opt-in cloud TTS for spoken discussion replies

**Input**: Design documents from `/specs/018-elevenlabs-tts/`

**Tests**: Included (constitution quality gates; SC-002…SC-006 name specific test deliverables).
Within each task: failing test first, then implementation.

**Organization**: By user story. US1 = the working cloud voice; US2 = failure never stalls or
silences; US3 = transparency and control.

## Phase 1: Foundational

- [ ] T001 [P] Add `DiscussionTTSBackend` (`system` | `elevenLabs`, Codable, default `system`) in
      `Sources/BarkCore/Speech/DiscussionTTSBackend.swift`
- [ ] T002 [P] Add pure request shaping in `Sources/BarkCore/Speech/CloudTTSRequest.swift`:
      synthesis URL from a user-editable base + voice ID, JSON body, 2000-char text bound,
      voice-list decoding, `SpeechSynthesisError` taxonomy, and documented defaults
      (`eleven_flash_v2_5`, default voice ID). Tests first in
      `Tests/BarkCoreTests/CloudTTSRequestTests.swift` (URL variants incl. trailing slash and a
      custom base, body encoding, truncation at the bound, voice-list decode, malformed decode)
- [ ] T003 Add Settings fields `discussionTTSBackend`, `elevenLabsVoiceID`, `elevenLabsModelID`
      with tolerant-decoder lines in `Sources/BarkCore/Settings/Settings.swift`; extend
      `Tests/BarkCoreTests/SettingsTests.swift` (defaults, old-payload decode, and SC-005: the
      encoded payload contains no API key)

## Phase 2: User Story 1 — cloud voice works (P1) 🎯 MVP

- [ ] T004 [US1] Implement `ElevenLabsSynthesizer` in
      `Sources/BarkEngines/Speech/ElevenLabsSynthesizer.swift`: ephemeral URLSession, `xi-api-key`
      header, 10 s deadline, `AVAudioPlayer` playback bridged to a continuation, `stop()`
      cancelling both request and playback, empty-text short-circuit. Tests first in
      `Tests/BarkAppTests/ElevenLabsSynthesizerTests.swift` using a `URLProtocol` stub
      (`OpenAICompatClientTests` pattern): header present, body shape, URL, empty text makes no
      request
- [ ] T005 [US1] Implement `FallbackSpeechSynthesizer` in
      `Sources/BarkEngines/Speech/FallbackSpeechSynthesizer.swift` per `contracts/cloud-tts.md`
      (primary → local; `stop()` forwarded to both; `availableVoices` from the fallback). Tests
      with fake conformers: success uses primary only, failure speaks via fallback exactly once
- [ ] T006 [US1] Extend `DiscussionController` settings surface in
      `Sources/Bark/DiscussionController.swift`: `ttsBackend`, `elevenLabsAPIKey` (Keychain
      account `elevenlabs-api-key`), `elevenLabsVoiceID`, `elevenLabsModelID`, fetched
      `elevenLabsVoices` + `fetchElevenLabsVoices()`, and one-shot error surfacing (FR-012)
- [ ] T007 [US1] Wire `CompositionRoot` to build
      `FallbackSpeechSynthesizer(primary: ElevenLabsSynthesizer(...), fallback:
      AVSpeechSynthesizerEngine())` when the backend is `elevenLabs`, else the system engine
      alone, reading the key from the Keychain at call time (so entering a key takes effect
      without a restart)
- [ ] T008 [US1] Settings UI in `Sources/Bark/UI/Settings/DiscussionPane.swift`: backend picker,
      SecureField for the key with a Delete action, model and voice fields, "Fetch voices" button
      + picker, Preview, and the FR-010 privacy warning naming what is and is not transmitted

## Phase 3: User Story 2 — failure never stalls or silences (P1)

- [ ] T009 [US2] Failure-matrix tests in `Tests/BarkAppTests/ElevenLabsSynthesizerTests.swift`:
      401, 429, transport error, empty body, undecodable audio, and deadline each report failure
      (never throw out of `speak`) and cancel cleanly
- [ ] T010 [US2] Half-duplex + no-stall tests in
      `Tests/BarkAppTests/DiscussionTTSGatingTests.swift`: with a stubbed failing cloud primary
      and a gated local fallback, the mic must not arm while the fallback is speaking, and the
      session must reach `awaitingUser` after every failure mode (SC-002, SC-003)

## Phase 4: User Story 3 — transparency and control (P2)

- [ ] T011 [US3] Zero-egress test (SC-004): with the backend set to `system`, a URLProtocol stub
      that fails the test if invoked proves the speech path makes no request
- [ ] T012 [US3] Key handling: Keychain round-trip via `InMemorySecretStore` in tests, Delete
      clears it, and switching the backend to `system` stops transmission immediately

## Phase 5: Polish

- [ ] T013 [P] `docs/ADR-012-cloud-tts-privacy-exception.md` + an ADR-012 entry in
      `docs/ADRs.md`: the Principle I carve-out, why no local model suffices (Kokoro `?`/`!`
      defect with issue links; Breeze latency/Metal contention), the exact data flow, and the
      honest note that replies can quote captured content
- [ ] T014 [P] `docs/SECURITY.md`: extend the Discussion surface with the cloud-TTS egress path,
      its controls, and residuals (provider retention; reply text derived from capture)
- [ ] T015 [P] Constitution amendment history entry for the ADR-012 carve-out in
      `.specify/memory/constitution.md`, and a README note in the discussion bullet
- [ ] T016 Final gate: `swift build` clean, full `swift test` green with counts, lean build
      verified, spec Status → Implemented

## Dependencies

T001–T003 block everything. US1: T004 → T005 → T006 → T007 → T008. US2 depends on T004/T005/T007.
US3 depends on T007/T008. Polish last.

## Implementation strategy

MVP = Phases 1–2 (a working, opt-in cloud voice). Phase 3 is required before it can be trusted in
a live conversation. Phases 4–5 close transparency and documentation.
