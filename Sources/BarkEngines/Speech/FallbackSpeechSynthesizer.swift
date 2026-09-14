import Foundation
import BarkCore

/// Anything that can try to speak and report failure. `ElevenLabsSynthesizer`
/// is the only conformer; the seam exists so the composite below can be tested
/// with a fake that fails on demand.
public protocol FallibleSpeechSynthesizing: Sendable {
    /// Speaks `text`, returning when playback completes. Throws only if
    /// nothing was played.
    func synthesizeAndPlay(_ text: String) async throws
    func stop()
}

extension ElevenLabsSynthesizer: FallibleSpeechSynthesizing {}

/// Tries a cloud primary and speaks on-device when it fails (018). This is
/// where constitution Principle I's "fail toward the local engine, never the
/// reverse" is implemented structurally rather than left to a code path that
/// has to remember: the primary's only failure action is local playback, and
/// local playback never escalates to transmission.
///
/// Crucially for 017's half-duplex invariant, `speak` returns only after the
/// *fallback* playback finishes too — so the microphone cannot arm while the
/// on-device voice is still talking.
public final class FallbackSpeechSynthesizer: SpeechSynthesizing, @unchecked Sendable {
    private let primary: FallibleSpeechSynthesizing
    private let fallback: SpeechSynthesizing

    private let lock = NSLock()
    private var reportedFailure = false
    private var failureHandler: (@Sendable (SpeechSynthesisError) -> Void)?

    /// Set by the app layer after construction (the controller that displays
    /// the error doesn't exist yet when this is built).
    public var onCloudFailure: (@Sendable (SpeechSynthesisError) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return failureHandler }
        set { lock.lock(); failureHandler = newValue; lock.unlock() }
    }

    public init(primary: FallibleSpeechSynthesizing, fallback: SpeechSynthesizing) {
        self.primary = primary
        self.fallback = fallback
    }

    /// Voices the *system* picker configures — the cloud engine has its own
    /// separately-fetched voice list, so conflating them would be misleading.
    public var availableVoices: [VoiceOption] { fallback.availableVoices }

    public func speak(_ text: String, voice: SpeechVoiceConfig?) async {
        do {
            try await primary.synthesizeAndPlay(text)
        } catch {
            report(error)
            await fallback.speak(text, voice: voice)
        }
    }

    public func stop() {
        primary.stop()
        fallback.stop()
    }

    /// Surface a failure once per configuration, not once per turn (FR-012):
    /// a dead endpoint would otherwise replace the AI's question with an error
    /// banner on every single turn.
    private func report(_ error: Error) {
        let typed = (error as? SpeechSynthesisError) ?? .transport(String(describing: error))
        // `.notConfigured` is the ordinary state when the user is on the
        // system-voice backend (or hasn't entered a key yet) — that's what the
        // settings pane is for, not an error banner mid-conversation.
        guard typed != .notConfigured else { return }
        lock.lock()
        let alreadyReported = reportedFailure
        reportedFailure = true
        let handler = failureHandler
        lock.unlock()
        guard !alreadyReported else { return }
        handler?(typed)
    }

    /// Called when the user changes the cloud configuration, so the next
    /// failure is reported again.
    public func resetFailureReporting() {
        lock.lock()
        reportedFailure = false
        lock.unlock()
    }
}
