import Foundation

/// Text-to-speech seam (017). The controller's half-duplex invariant hangs
/// on one semantic: `speak` returns only when playback has finished or been
/// stopped, and returning is the sole permission to re-arm the mic — no
/// other component reasons about audio output. `speak` never throws: a
/// synthesis failure returns promptly (logged by the conformer) so the
/// session degrades to text-only with no user-facing error (US2/AS3).
public protocol SpeechSynthesizing: Sendable {
    /// Speaks `text`, applying `voice` when the conformer supports it (a
    /// conformer that has no notion of voices ignores it). Passed per call
    /// rather than held as engine state so the value stays `Sendable` and the
    /// caller — which already owns Settings — remains the single source of
    /// truth for the user's choice.
    func speak(_ text: String, voice: SpeechVoiceConfig?) async

    /// Stops playback immediately; the pending `speak` returns. Idempotent.
    func stop()

    /// Voices this conformer can speak with, for the settings picker. Empty
    /// when the engine has no selectable voices.
    var availableVoices: [VoiceOption] { get }
}

public extension SpeechSynthesizing {
    /// Platform-default voice.
    func speak(_ text: String) async { await speak(text, voice: nil) }

    var availableVoices: [VoiceOption] { [] }
}
