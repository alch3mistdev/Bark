# Contract: cloud TTS (ElevenLabs) + local fallback

## Synthesis request

```
POST https://api.elevenlabs.io/v1/text-to-speech/{voice_id}
xi-api-key: <key from Keychain>
Content-Type: application/json
Accept: audio/mpeg

{ "text": "<reply, truncated to 2000 chars>", "model_id": "eleven_flash_v2_5" }
```

Success is a 2xx whose body is MP3 audio. Non-2xx, an empty body, or a body the audio player
rejects are all failures (see fallback). The base URL, model ID, and voice ID are user-editable;
`CloudTTSRequest` builds the URL from the base so a self-hosted or proxied endpoint also works.

**Transmitted:** the reply string only. **Never transmitted:** raw microphone audio, the captured
screen context, the discussion transcript, dictation output, or any history. The reply is
*derived* from the capture and the user's speech and may quote or paraphrase either — the settings
warning states this rather than claiming the text is Bark-authored.

## Voice list (on demand, explicit user action)

```
GET https://api.elevenlabs.io/v1/voices
xi-api-key: <key>

→ { "voices": [ { "voice_id": "...", "name": "...", "category": "..." }, ... ] }
```

Decoded into `[ElevenLabsVoice]`. A failure leaves any previously fetched list intact.

## Conformer semantics (`SpeechSynthesizing`, unchanged from 017)

`speak(_:voice:)` returns when playback finishes or is stopped, and never throws. For the cloud
conformer that means:

1. Empty/whitespace text → return immediately, no request, no spend.
2. Missing key or voice → throw internally, surfaced to the composite as `notConfigured`.
3. Request under a 10 s deadline; `stop()` cancels the in-flight request **and** playback, and the
   pending `speak` returns.
4. On success, play to completion, then return.

`stop()` is idempotent and safe with nothing playing.

## Fallback composite

`FallbackSpeechSynthesizer(primary:fallback:)` implements Principle I's required failure
direction structurally:

- `speak`: attempt `primary`; if it reports failure, speak the same text through `fallback`
  (the on-device system voice) and return only when *that* playback completes. The half-duplex
  gate therefore holds on the fallback path too — the mic cannot arm while the fallback is
  speaking.
- `stop()`: forwarded to both.
- `availableVoices`: the fallback's (system) voices, since that is what the system-voice picker
  configures.
- The failure is reported once per configuration change, not once per turn (FR-012).

Because the primary is attempted first and the fallback only ever plays locally, there is no path
in which a cloud failure escalates to further transmission, and no path in which the session is
left silent.
