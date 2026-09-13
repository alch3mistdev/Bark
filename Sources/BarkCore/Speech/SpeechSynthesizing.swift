import Foundation

/// Text-to-speech seam (017). The controller's half-duplex invariant hangs
/// on one semantic: `speak` returns only when playback has finished or been
/// stopped, and returning is the sole permission to re-arm the mic — no
/// other component reasons about audio output. `speak` never throws: a
/// synthesis failure returns promptly (logged by the conformer) so the
/// session degrades to text-only with no user-facing error (US2/AS3).
public protocol SpeechSynthesizing: Sendable {
    func speak(_ text: String) async
    /// Stops playback immediately; the pending `speak` returns. Idempotent.
    func stop()
}
