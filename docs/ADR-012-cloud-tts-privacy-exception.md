# ADR-012 — Opt-in cloud TTS for spoken discussion replies

**Status**: Accepted (2026-09-15) · **Supersedes**: nothing · **Related**: ADR-010 (external LLM
endpoint), ADR-011 (Socratic discussion), `specs/018-elevenlabs-tts/`

## Context

017 shipped spoken discussion replies through `AVSpeechSynthesizer`. The user's verdict was
blunt: "the TTS on the discuss feature is horrible, you need to use something as good as
ElevenLabs."

Two separate causes were investigated.

**Cause 1 — a bug, now fixed.** 017 created a bare `AVSpeechUtterance` and never set a voice, so
the platform picked its default: on a stock Mac a *compact* voice. Measured on the user's machine:
180 voices installed, **zero** Enhanced, **zero** Premium, `en-US` resolving to
`com.apple.voice.compact.en-US.Samantha`. `VoiceSelector` now picks the best installed tier and
the settings pane prompts for the one-time Enhanced/Premium download. This materially improves
on-device speech and is shipped independently of this decision.

**Cause 2 — a ceiling, not a bug.** No local model closes the gap:

- **Kokoro-82M** is the best on-device candidate (Apache-2.0, ANE-resident, ~150–400 ms for a
  short reply, no Metal contention with the resident Qwen3-4B). It is disqualified for *this*
  feature by a specific defect: its `?` and `!` tokens are acoustically inert — a question is
  rendered identically to a statement (hexgrad/kokoro
  [#78](https://github.com/hexgrad/kokoro/issues/78),
  [#194](https://github.com/hexgrad/kokoro/issues/194),
  [#264](https://github.com/hexgrad/kokoro/issues/264), all open with reproduced audio, verified
  against the GitHub API). A Socratic questioner whose questions land as flat declaratives is the
  worst possible match. It is also documented by its own `VOICES.md` as weak below 10–20 tokens,
  and only two of its voices grade above B−.
- Permitting **non-commercial weights** (this app is personal-use and never sold) changed nothing
  material. Only **Breeze TTS 2** (3B) clearly beats Kokoro on short conversational lines, and it
  has no streaming Swift path and runs slower than real time on an M3 Pro while competing for
  Metal with the dialogue model. Fish S2 Pro, Voxtral, Higgs v2/v3, F5-TTS and OpenAudio S1-mini
  either tie Kokoro or lose to it on this workload.
- Evidence quality, stated honestly: the Artificial Analysis arena measures 92–184-character
  prompts — genuinely this workload — and puts ElevenLabs v3 ~65/35 over Kokoro, with the gap
  *wider* on assistant-style lines. The HuggingFace TTS Arena, using arbitrary user text, puts
  them within 23 Elo. No controlled human listening test comparing these models exists at any
  length. How large a gap a user perceives depends on how characterful the replies are.

## Decision

Add an **opt-in** `SpeechSynthesizing` conformer that synthesizes discussion replies via the
ElevenLabs HTTP API, defaulting to `eleven_flash_v2_5` (~75 ms TTFB). The on-device system voice
remains the default backend. This is a deliberate carve-out from constitution Principle I,
granted on the same terms as ADR-010 and with the user's explicit sign-off in the session that
produced `specs/018-elevenlabs-tts/`.

Controls, all implemented rather than promised:

- **Default off.** `Settings.discussionTTSBackend == .system`. Selecting the on-device backend
  makes the cloud primary refuse *before* touching `URLSession`, so zero network requests occur —
  asserted by a stub that fails the test if invoked.
- **Fails toward local, structurally.** `FallbackSpeechSynthesizer` is the speech path; the cloud
  engine's only failure action is local playback. There is no code path in which a cloud failure
  escalates to further transmission, and none in which the session goes silent.
- **The half-duplex invariant survives.** `speak` returns only after the *fallback* finishes
  playing, so the microphone cannot open while either voice is talking (tested with a gated local
  fake behind a failing cloud primary).
- **Credentials in the Keychain** under `elevenlabs-api-key` — a distinct account from ADR-010's
  `external-llm-key`, so either can be deleted independently. Never in the settings payload
  (asserted by encoding settings and searching the output).
- **Bounded, ephemeral, unpersisted.** Transmitted text is capped at 2000 characters; the URL
  session is `.ephemeral`; audio lives in memory for playback only.
- **Deadline-bounded** at 10 s with cancellation, so a turn cannot hang.
- **One error, not one per turn.** A dead endpoint reports once per configuration change rather
  than replacing every AI question with a banner.

## Honest statement of what leaves the device

Transmitted: **the AI's reply text**, per spoken turn.

Not transmitted: microphone audio, the captured screen content itself, the discussion transcript,
dictation output, history.

**The important caveat, which the settings warning states verbatim rather than eliding:** the
reply is *derived from* the captured screen content and the user's speech, and can paraphrase or
quote either. It would be false to tell the user "only Bark's own words leave your Mac." The text
is also subject to ElevenLabs' retention policy, which Bark does not control.

## Consequences

`Settings` gains three tolerant-decoded fields. One new Keychain account. No new permissions —
this feature produces sound, never keystrokes, and touches nothing in the injection path. ~30 new
tests (pure request shaping, a stubbed failure matrix, composite fallback semantics, and
half-duplex on the fallback path). Streaming synthesis is deferred: replies are one or two
sentences, so chunked MP3 decode buys little, and the contract already permits adding it.

Residual risks, recorded in `docs/SECURITY.md` as L-23…L-25: provider-side retention is outside
Bark's control; reply text can quote captured content; and a user who enables this has
deliberately traded the offline guarantee for voice quality on this one feature.
