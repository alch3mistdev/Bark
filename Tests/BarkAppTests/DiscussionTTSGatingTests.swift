import XCTest
@testable import BarkCore
@testable import BarkEngines
@testable import Bark

/// 017 US2: spoken replies with the half-duplex invariant — the mic is never
/// armed while TTS is mid-playback (SC-002), a key tap skips speech, and a
/// broken synthesizer degrades the session to text-only.
@MainActor
final class DiscussionTTSGatingTests: XCTestCase {
    private let target = InjectionTarget(pid: 4242, bundleID: "com.example.TextEdit")

    private static let sampleContext = CapturedContext(
        source: .accessibility, appBundleID: "com.example.TextEdit", windowTitle: "Doc",
        fieldLabel: nil, fieldValue: nil, fieldPlaceholder: nil, fieldRole: "AXTextArea",
        windowText: "Notes")

    /// Audio factory that counts every `start()` — the half-duplex assertion
    /// hangs on this count staying flat while TTS is suspended.
    final class CountingAudioFactory: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var startCount: Int { lock.lock(); defer { lock.unlock() }; return count }
        func make() -> AudioCapturing {
            lock.lock(); count += 1; lock.unlock()
            return FakeAudioCapture()
        }
    }

    private func make(
        micMode: DiscussionMicMode = .handsFree,
        gatedTTS: Bool = true,
        audioFactory: (@Sendable () -> AudioCapturing)? = nil
    ) -> (DiscussionController, FakeSpeechSynthesizer, DictationController) {
        let defaults = UserDefaults(suiteName: "bark-tts-test-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults, key: "k")
        settings.update {
            $0.selectedModeID = "raw"
            $0.llmEnabled = true
            $0.discussionEnabled = true
            $0.discussionMicMode = micMode
            $0.discussionTTSEnabled = true
        }
        let perms = PermissionsCoordinator()
        perms.overrideForTesting(microphone: .granted)
        let dictation = DictationController(
            settings: settings, permissions: perms, hotkey: HotkeyManager(),
            stt: FakeSTTEngine(finalText: "hi"), llmCleaner: FakeCleaner(.ok("hi")),
            history: nil, audioFactory: { FakeAudioCapture() },
            pasteInjector: FakeInjector(), keystrokeInjector: FakeInjector(),
            clipboardInjector: FakeInjector(),
            cleanupDeadline: 0.3, targetProvider: { [target] in target }
        )
        let engine = FakeDialogueEngine(replies: [
            .ok(#"{"reply": "What's the goal?", "ready": false}"#),
        ])
        let synth = FakeSpeechSynthesizer(gated: gatedTTS)
        let controller = DiscussionController(
            settings: settings, dictation: dictation, hotkey: HotkeyManager(),
            capture: FakeContextCapture(.ok(Self.sampleContext)), localEngine: engine,
            secretStore: InMemorySecretStore(),
            stt: ScriptedSTTEngine(segments: ["hello"]),
            audioFactory: audioFactory ?? { FakeAudioCapture() },
            synthesizer: synth,
            pasteInjector: FakeInjector(), keystrokeInjector: FakeInjector(),
            clipboardInjector: FakeInjector(),
            targetProvider: { [target] in target },
            replyDeadline: 5, synthesisDeadline: 5, sttFinalizeDeadline: 1, settleDelay: .zero
        )
        return (controller, synth, dictation)
    }

    private func waitFor(_ what: String, _ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for \(what)")
    }

    func testMicNeverArmsWhileTTSPlays() async {
        // Gated TTS: speak() suspends until released. The session must sit in
        // `presenting` with ZERO audio-capture starts the whole time (SC-002).
        let audio = CountingAudioFactory()
        let (c, synth, _) = make(micMode: .handsFree, audioFactory: { audio.make() })

        c.begin()
        await waitFor("TTS started") { synth.spoken.count == 1 }
        XCTAssertEqual(c.session.state, .presenting)

        // Hold playback for a while: state stays presenting, mic stays closed.
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(c.session.state, .presenting)
        XCTAssertEqual(audio.startCount, 0)
        XCTAssertFalse(c.session.state.allowsMic)

        // Release playback → presentationFinished → mic arms (VAD mode).
        synth.releaseAll()
        await waitFor("mic armed") { c.session.state == .awaitingUser }
        await waitFor("audio started") { audio.startCount == 1 }
        c.cancel()
    }

    func testSpokenTextMatchesReplyAndPTTStaysClosedUntilTap() async {
        let audio = CountingAudioFactory()
        let (c, synth, _) = make(micMode: .ptt, audioFactory: { audio.make() })
        c.begin()
        await waitFor("TTS started") { synth.spoken.count == 1 }
        XCTAssertEqual(synth.spoken, ["What's the goal?"])
        synth.releaseAll()
        await waitFor("awaiting user") { c.session.state == .awaitingUser }
        // PTT: even after speech ends, no audio starts until the key tap.
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(audio.startCount, 0)
        c.handleHotkey()
        await waitFor("listening") { c.session.state == .listening }
        XCTAssertEqual(audio.startCount, 1)
        c.cancel()
    }

    func testKeyTapSkipsSpeechImmediately() async {
        let (c, synth, _) = make(micMode: .ptt)
        c.begin()
        await waitFor("TTS started") { synth.spoken.count == 1 }
        XCTAssertEqual(c.session.state, .presenting)

        c.handleHotkey()   // tap during playback = skip
        await waitFor("stopped") { synth.stopCount >= 1 }
        await waitFor("turn open") { c.session.state == .awaitingUser }
        c.cancel()
    }

    func testTTSFailureDegradesToTextOnly() async {
        // Ungated fake = speak() returns immediately (a failed/very-short
        // synthesis). The session must proceed with no user-facing error.
        let (c, synth, _) = make(micMode: .ptt, gatedTTS: false)
        c.begin()
        await waitFor("proceeded past TTS") { c.session.state == .awaitingUser }
        XCTAssertEqual(synth.spoken.count, 1)
        XCTAssertNil(c.lastError)
        c.cancel()
    }
}
