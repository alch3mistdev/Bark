import Foundation
import AVFoundation
import BarkCore

/// On-device TTS over `AVSpeechSynthesizer` (017 US2). `speak` returns when
/// playback finishes or is stopped — the semantic the controller's half-duplex
/// gate hangs on — and never throws: a synthesizer failure just returns
/// promptly so the session degrades to text-only. System default voice; the
/// synthesizer runs entirely on-device (constitution I).
///
/// Concurrency hardening (ADV-010): the pending continuation is keyed to its
/// own `AVSpeechUtterance`, so a late delegate callback for an OLD utterance
/// can never release a NEW utterance's gate; and `stop()` bumps an epoch under
/// the same lock, so a stop that lands between continuation install and
/// `speak()` suppresses the enqueue instead of letting orphaned audio play.
public final class AVSpeechSynthesizerEngine: NSObject, SpeechSynthesizing, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private let lock = NSLock()
    private var pending: (utterance: AVSpeechUtterance, continuation: CheckedContinuation<Void, Never>)?
    private var stopEpoch = 0

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    public func speak(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // One utterance at a time by contract; a straggler is released first.
        releasePending(matching: nil)
        let utterance = AVSpeechUtterance(string: trimmed)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            let epoch = stopEpoch
            pending = (utterance, cont)
            lock.unlock()

            lock.lock()
            let stoppedMeanwhile = stopEpoch != epoch
            lock.unlock()
            if stoppedMeanwhile {
                releasePending(matching: utterance)   // stop() raced the install — don't play
            } else {
                synthesizer.speak(utterance)
            }
        }
    }

    public func stop() {
        lock.lock()
        stopEpoch += 1
        lock.unlock()
        synthesizer.stopSpeaking(at: .immediate)   // fires didCancel → release
        releasePending(matching: nil)              // belt-and-braces if no delegate call comes
    }

    /// Resume the pending continuation. `matching == nil` releases whatever is
    /// pending (stop/straggler paths); a non-nil utterance releases only ITS
    /// continuation, so stale delegate callbacks are ignored.
    private func releasePending(matching utterance: AVSpeechUtterance?) {
        lock.lock()
        guard let current = pending, utterance == nil || current.utterance === utterance else {
            lock.unlock()
            return
        }
        pending = nil
        lock.unlock()
        current.continuation.resume()
    }

    // MARK: - AVSpeechSynthesizerDelegate

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        releasePending(matching: utterance)
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        releasePending(matching: utterance)
    }
}
