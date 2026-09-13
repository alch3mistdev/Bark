import Foundation
import AVFoundation
import BarkCore

/// On-device TTS over `AVSpeechSynthesizer` (017 US2). `speak` returns when
/// playback finishes or is stopped — the semantic the controller's half-duplex
/// gate hangs on — and never throws: a synthesizer failure just returns
/// promptly so the session degrades to text-only. System default voice; the
/// synthesizer runs entirely on-device (constitution I).
public final class AVSpeechSynthesizerEngine: NSObject, SpeechSynthesizing, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    public func speak(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // One utterance at a time by contract; a straggler is released first.
        finishPending()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            continuation = cont
            lock.unlock()
            let utterance = AVSpeechUtterance(string: trimmed)
            synthesizer.speak(utterance)
        }
    }

    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)   // fires didCancel → resume
        finishPending()                            // belt-and-braces if no delegate call comes
    }

    private func finishPending() {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }

    // MARK: - AVSpeechSynthesizerDelegate

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finishPending()
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finishPending()
    }
}
