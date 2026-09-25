# Feature Specification: Opt-in cloud TTS for spoken discussion replies

**Feature Branch**: `018-elevenlabs-tts`

**Created**: 2026-09-15

**Status**: Implemented (2026-09-15)

**Input**: User description: "The TTS on the discuss feature is horrible, you need to use something
as good as ElevenLabs. Is there a local equivalent that gets close to ElevenLabs quality?" —
answered: no. The best local option (Kokoro-82M) is Apache-2.0, fast, and ANE-resident, but it
renders `?` and `!` acoustically identically to `.` (hexgrad/kokoro issues #78, #194, #264, all
open with reproduced audio), which is disqualifying for a feature whose entire output is
clarifying questions. Non-commercial weights were then permitted (the app is personal-use, never
sold), which changed nothing material: only Breeze TTS 2 (3B) clearly beats Kokoro on short
conversational lines, and it has no streaming Swift path and runs slower than real time on an
M3 Pro while competing with the resident Qwen3-4B for Metal. User elected the cloud opt-in.

## Clarifications

### Session 2026-09-15

- Q: Which provider and model? → A: ElevenLabs, default `eleven_flash_v2_5` (~75 ms
  time-to-first-byte, the lowest-latency model they publish); the model ID is user-editable so a
  higher-quality/slower model can be chosen without a code change.
- Q: Streaming or single-shot? → A: Single-shot request, then play the returned audio. Replies are
  one or two sentences, so the added complexity of chunked MP3 decode is not justified for v1.
  Deferred, not rejected — the `SpeechSynthesizing` contract already permits it.
- Q: What happens when the cloud call fails? → A: Fall back to the on-device system voice for that
  utterance and log it. Constitution Principle I requires failing *toward* the local engine; a
  silent non-response would also leave the user staring at an overlay with no idea why it went
  quiet.
- Q: How does the user pick a voice? → A: Fetch the account's voice list on demand (one `GET
  /v1/voices`, triggered by an explicit button) and offer it in a picker. Pasting opaque voice IDs
  is hostile, and the fetch is the same trust boundary the synthesis call already crosses.
- Q: Default state? → A: Off. The system voice remains the default TTS backend; this is an
  explicit opt-in with a privacy warning, exactly the ADR-010 shape already used for the external
  LLM endpoint.
- Q: Is the transmitted text just the AI's own words? → A: **No — and the warning must say so.**
  The AI's reply is *derived from* the captured screen content and the user's speech, and can
  paraphrase or quote either. Only the reply string is transmitted, never the raw capture,
  transcript, or audio; but claiming "only Bark's own words leave the device" would overclaim.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Hear discussion replies in a high-quality cloud voice (Priority: P1)

A user who finds the on-device system voices unacceptable enters an ElevenLabs API key in
Settings ▸ Discuss, switches the spoken-replies backend to ElevenLabs, fetches and picks a voice,
and previews it. Subsequent discussion sessions speak every AI reply in that voice. The mic
remains closed for the whole of playback, exactly as with the system voice.

**Why this priority**: This is the feature. Without it the user's complaint is unresolved.

**Independent Test**: With a key configured and the backend set to ElevenLabs, run a discussion
turn and confirm the reply is spoken in the chosen cloud voice, that the microphone does not arm
until playback completes, and that a tap of the discussion hotkey stops playback immediately.

**Acceptance Scenarios**:

1. **Given** the ElevenLabs backend is selected with a valid key and voice, **When** the AI
   produces a reply, **Then** the reply text is synthesized by ElevenLabs and played to
   completion, and only then does the mic arm (the half-duplex invariant, SC-002 of 017, holds
   unchanged for the new backend).
2. **Given** playback is in progress, **When** the user taps the discussion hotkey, **Then**
   playback stops immediately and the user's turn opens.
3. **Given** the backend is selected but no key is stored, **When** a reply is presented, **Then**
   the system voice speaks it and the settings pane shows that a key is required.
4. **Given** a valid configuration, **When** the user presses Preview in Settings, **Then** a
   sample line is spoken in the selected cloud voice without starting a discussion session.

---

### User Story 2 - Failure never leaves the session silent or stalled (Priority: P1)

The endpoint is unreachable, the key is rejected, the account is out of credits, or the request
exceeds its deadline. The session continues: the utterance is spoken by the on-device system voice
instead, the failure is surfaced once in the overlay rather than repeatedly, and the discussion
loop proceeds normally.

**Why this priority**: A paid network dependency in the middle of a conversation loop is the most
likely thing to break, and 017's half-duplex gate depends on `speak` always returning.

**Independent Test**: Point the backend at a stubbed endpoint returning 401, then 429, then a
timeout; each turn must still be spoken (by the system voice) and the session must reach
`awaitingUser` every time.

**Acceptance Scenarios**:

1. **Given** the cloud request fails for any reason, **When** the reply is presented, **Then** the
   system voice speaks it and the mic arms only after that fallback playback completes.
2. **Given** the cloud request exceeds its deadline, **When** the deadline fires, **Then** the
   in-flight request is cancelled and the fallback speaks, so no turn can hang.
3. **Given** a failure has been surfaced, **When** subsequent turns also fail, **Then** the user
   is not spammed with a new error for every turn.

---

### User Story 3 - Understand and control what leaves the device (Priority: P2)

Before enabling the backend the user can read exactly what is transmitted, to whom, and what is
not. The key is stored in the Keychain, never in the settings file. Turning the backend off stops
all transmission immediately, and the key can be deleted.

**Why this priority**: The app's entire premise is offline-first; the constitution permits an
external endpoint only as an explicit, warned, per-feature opt-in.

**Acceptance Scenarios**:

1. **Given** the Discuss settings pane, **When** the ElevenLabs backend is selected, **Then** a
   warning names what is sent (the AI's reply text, which may paraphrase or quote the captured
   screen content and the user's speech), what is not (raw audio, the screen capture, the
   transcript, dictation), and that the text is subject to the provider's retention policy.
2. **Given** a stored key, **When** the settings file is inspected, **Then** the key is absent
   from it.
3. **Given** the backend is switched back to the system voice, **When** a reply is presented,
   **Then** no network request is made.

---

### Edge Cases

- Empty or whitespace-only reply text: no request is made (no spend, no playback).
- Reply longer than the provider's per-request character limit: the text is truncated to a
  documented bound before sending, so a runaway reply cannot produce a surprise bill.
- Key present but voice ID empty: a documented default voice ID is used so the feature works
  before the user fetches the voice list.
- Voice fetch fails: the picker keeps any previously fetched list and surfaces the error; the
  voice ID remains editable by hand.
- Backend switched mid-session: the change takes effect on the next utterance; in-flight playback
  is unaffected.
- Lean build: unchanged. This backend has no MLX dependency, so it is available in every build;
  its absence of configuration is what disables it.
- Preview pressed while a session reply is being spoken: refused (017 behavior, unchanged), so
  auditioning can never overlap session speech.
- Network available but system asleep/offline mid-request: treated as any other transport failure.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: A `SpeechSynthesizing` conformer MUST synthesize text via the ElevenLabs
  text-to-speech HTTP API and play the returned audio, returning only when playback finishes or
  is stopped (the 017 contract, unchanged).
- **FR-002**: The spoken-replies backend MUST be user-selectable between the on-device system
  voice (default) and ElevenLabs, persisted in settings.
- **FR-003**: The API key MUST be stored in the Keychain under its own account, never in the
  settings blob, and MUST be deletable from the UI.
- **FR-004**: Model ID and voice ID MUST be user-editable, with documented defaults
  (`eleven_flash_v2_5`; a default voice ID) so the feature works immediately after a key is
  entered.
- **FR-005**: The user MUST be able to fetch the account's voice list on demand and select from
  it; a fetch failure MUST NOT clear a previously fetched list.
- **FR-006**: Any failure — transport, non-2xx, empty/undecodable audio, or deadline — MUST fall
  back to the on-device system voice for that utterance, and MUST NOT throw out of `speak`.
- **FR-007**: Requests MUST be deadline-bounded and cancellable, and `stop()` MUST abort both an
  in-flight request and any playback.
- **FR-008**: Only the reply text MUST be transmitted. The raw audio, the captured screen context,
  the discussion transcript, and dictation output MUST NOT be transmitted. Request text MUST be
  truncated to a documented character bound.
- **FR-009**: The session MUST NOT be able to hang on this backend: the half-duplex invariant
  (mic armed only after playback completes) MUST hold for the cloud path, the fallback path, and
  the stop/skip path.
- **FR-010**: The settings UI MUST show a privacy warning naming exactly what is and is not
  transmitted, and MUST NOT claim that only Bark-authored text leaves the device.
- **FR-011**: The URL session MUST NOT persist request or response content (ephemeral
  configuration), matching the existing external-LLM client.
- **FR-012**: Repeated failures MUST NOT produce repeated user-facing errors for every turn.

### Key Entities

- **DiscussionTTSBackend** (BarkCore): `system | elevenLabs`, Codable, default `system`.
- **ElevenLabsVoice** (BarkCore): `{ id, name, category? }` — one entry of a fetched voice list.
- **ElevenLabsRequest** (BarkCore, pure): URL construction, request-body encoding, text
  truncation bound, and response decoding for the voice list — all unit-testable without network,
  mirroring `OpenAICompatClient.chatCompletionsURL`.
- **SpeechSynthesisError** (BarkCore): `notConfigured | http(Int) | transport(String) |
  badAudio(String) | deadlineExceeded`.
- **ElevenLabsSynthesizer** (BarkEngines): `SpeechSynthesizing` conformer — URLSession +
  audio playback, delegate bridged to a continuation.
- **FallbackSpeechSynthesizer** (BarkEngines): composite that tries a primary conformer and
  speaks through a secondary on failure — the mechanism implementing "fail toward local".

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: With a configured key, discussion replies are spoken in the selected ElevenLabs
  voice, and the user judges the quality acceptable (the complaint that motivated the feature).
- **SC-002**: The 017 half-duplex invariant holds for every new path — cloud success, cloud
  failure with fallback, and stop/skip — asserted by orchestration tests with a stubbed endpoint.
- **SC-003**: No failure mode leaves a turn silent or stalled: every one of transport failure,
  401, 429, malformed body, and deadline results in the utterance being spoken by the system voice
  and the session reaching `awaitingUser`.
- **SC-004**: With the backend set to `system`, zero network requests are made by the speech path
  (asserted by a stubbed session that fails the test if called).
- **SC-005**: The API key never appears in the persisted settings payload (asserted by encoding
  settings and searching the output).
- **SC-006**: All existing 017 behavior is unchanged when the backend is `system` (existing suites
  pass unmodified).

## Assumptions

- The user holds their own ElevenLabs API key and accepts the provider's pricing and retention
  policy. Bark neither bundles nor proxies credentials.
- `eleven_flash_v2_5` at ~75 ms TTFB plus network RTT is fast enough for a conversational turn;
  total perceived latency for a short reply is expected in the few-hundred-millisecond range but
  is not measured in CI (it needs a live key and network).
- Single-shot synthesis is sufficient for one-to-two-sentence replies; streaming is deferred.
- MP3 playback via the platform audio player is adequate; no custom decode path is needed.
- This feature is used personally and not redistributed with a key, so no credential-provisioning
  or rate-limit-sharing design is required.
