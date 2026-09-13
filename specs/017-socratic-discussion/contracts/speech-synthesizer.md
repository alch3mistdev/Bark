# Contract: SpeechSynthesizing

```swift
public protocol SpeechSynthesizing: Sendable {
    /// Speaks `text` aloud and returns when playback finishes or is stopped.
    /// Never throws: any synthesis failure returns promptly (logged internally),
    /// so the session degrades to text-only with no user-facing error (US2/AS3).
    func speak(_ text: String) async

    /// Stops playback immediately; the pending `speak` returns. Idempotent.
    func stop()
}
```

## Semantics the controller relies on

- **Completion == permission to re-arm the mic.** The half-duplex invariant (SC-002) is
  implemented as: `presenting → awaitingUser` only after `speak` returns (or immediately when
  TTS is disabled). No other component reasons about audio output.
- Key-tap skip (US2/AS2): controller calls `stop()`; the in-flight `speak` returns; the turn
  opens.
- `stop()` with nothing playing is a no-op.
- One utterance at a time: the controller never overlaps `speak` calls.

## Conformer

`AVSpeechSynthesizerEngine` (`BarkEngines/Speech/`): wraps `AVSpeechSynthesizer`;
`AVSpeechSynthesizerDelegate.didFinish`/`didCancel` resumes a `CheckedContinuation`; system
default voice and rate; fully on-device (constitution I). First AVFoundation speech-output use
in the repo — no other component touches audio output except `Feedback` (NSSound cues).

## Test fake

`FakeSpeechSynthesizer`: records spoken texts; `speak` suspends until the test releases it
(gated continuation), so tests can assert the mic is not armed mid-playback and that `stop()`
releases it.
