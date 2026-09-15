import XCTest
@testable import BarkCore
@testable import BarkEngines
@testable import Bark

/// 017 US2 + 018: spoken replies. Covers the half-duplex invariant (the mic is
/// never armed while TTS is mid-playback, SC-002), the opening-statement
/// exemption, voice selection reaching the engine, and the cloud backend's
/// fallback behavior.
///
/// Note on harness shape: the opening statement is deliberately NOT spoken, so
/// every test that asserts on speech must first advance past it. `advanceTurn`
/// does that; scripts therefore provide two replies.
@MainActor
final class DiscussionTTSGatingTests: XCTestCase {
    private let target = InjectionTarget(pid: 4242, bundleID: "com.example.TextEdit")

    private static let sampleContext = CapturedContext(
        source: .accessibility, appBundleID: "com.example.TextEdit", windowTitle: "Doc",
        fieldLabel: nil, fieldValue: nil, fieldPlaceholder: nil, fieldRole: "AXTextArea",
        windowText: "Notes")

    /// Counts every `start()` — the half-duplex assertion hangs on this
    /// staying flat while TTS is suspended.
    final class CountingAudioFactory: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var speechOnFirst = false
        var startCount: Int { lock.lock(); defer { lock.unlock() }; return count }

        /// When true, the FIRST engine emits one utterance (onset + hangover)
        /// and every later engine emits silence — enough to drive exactly one
        /// hands-free turn without the session then running away.
        init(speechOnFirstEngine: Bool = false) { speechOnFirst = speechOnFirstEngine }

        func make() -> AudioCapturing {
            lock.lock()
            count += 1
            let wantsSpeech = speechOnFirst && count == 1
            lock.unlock()
            let levels: [Float] = wantsSpeech
                ? [0.05, 0.05, 0.05] + Array(repeating: 0.001, count: 10)
                : Array(repeating: 0.001, count: 30)
            return ScriptedAudioCapture(rmsLevels: levels)
        }
    }

    private struct Harness {
        let controller: DiscussionController
        let synth: FakeSpeechSynthesizer
        let dictation: DictationController
        let audio: CountingAudioFactory
        let settings: SettingsStore
    }

    private func make(
        micMode: DiscussionMicMode = .ptt,
        gatedTTS: Bool = false,
        ttsEnabled: Bool = true,
        speechOnFirstEngine: Bool = false,
        replies: [FakeDialogueEngine.Outcome] = [
            .ok(#"{"reply": "Q1", "ready": false}"#),
            .ok(#"{"reply": "Q2", "ready": false}"#),
        ],
        cloudPrimary: FallibleSpeechSynthesizing? = nil
    ) -> Harness {
        let defaults = UserDefaults(suiteName: "bark-tts-test-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults, key: "k")
        settings.update {
            $0.selectedModeID = "raw"
            $0.llmEnabled = true
            $0.discussionEnabled = true
            $0.discussionMicMode = micMode
            $0.discussionTTSEnabled = ttsEnabled
            if cloudPrimary != nil { $0.discussionTTSBackend = .elevenLabs }
        }
        let perms = PermissionsCoordinator()
        perms.overrideForTesting(microphone: .granted)
        let audio = CountingAudioFactory(speechOnFirstEngine: speechOnFirstEngine)
        let dictation = DictationController(
            settings: settings, permissions: perms, hotkey: HotkeyManager(),
            stt: FakeSTTEngine(finalText: "hi"), llmCleaner: FakeCleaner(.ok("hi")),
            history: nil, audioFactory: { FakeAudioCapture() },
            pasteInjector: FakeInjector(), keystrokeInjector: FakeInjector(),
            clipboardInjector: FakeInjector(),
            cleanupDeadline: 0.3, targetProvider: { [target] in target }
        )
        let engine = FakeDialogueEngine(replies: replies)
        let synth = FakeSpeechSynthesizer(gated: gatedTTS)
        let speech: SpeechSynthesizing
        var composite: FallbackSpeechSynthesizer?
        if let cloudPrimary {
            let c = FallbackSpeechSynthesizer(primary: cloudPrimary, fallback: synth)
            composite = c
            speech = c
        } else {
            speech = synth
        }
        let controller = DiscussionController(
            settings: settings, dictation: dictation, hotkey: HotkeyManager(),
            capture: FakeContextCapture(.ok(Self.sampleContext)), localEngine: engine,
            secretStore: InMemorySecretStore(),
            stt: ScriptedSTTEngine(segments: ["a launch email", "and keep it short"]),
            audioFactory: { audio.make() },
            synthesizer: speech,
            cloudConfig: CloudTTSConfigStore(),
            cloudTTS: composite,
            targetProvider: { [target] in target },
            replyDeadline: 5, synthesisDeadline: 5, sttFinalizeDeadline: 1, settleDelay: .zero
        )
        composite?.onCloudFailure = { [weak controller] error in
            Task { @MainActor in controller?.reportCloudTTSFailure(error) }
        }
        return Harness(controller: controller, synth: synth, dictation: dictation,
                       audio: audio, settings: settings)
    }

    private func waitFor(_ what: String, _ condition: @MainActor () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for \(what)")
    }

    /// Drives one complete push-to-talk turn, so the NEXT assistant reply is a
    /// non-opening one and therefore spoken.
    private func advanceTurn(_ c: DiscussionController) async {
        c.handleHotkey()
        await waitFor("listening") { c.session.state == .listening }
        c.handleHotkey()
    }

    // MARK: - Opening statement is silent (user can jump straight in)

    func testOpeningStatementIsNeverSpokenSoTheUserCanJumpIn() async {
        // The opening question arrives while the user is still deciding what
        // they want; narrating it would hold the mic shut behind playback for
        // exactly the turn where they most likely already have something to
        // say. It is shown, not spoken, and the turn opens immediately.
        let h = make(micMode: .ptt, gatedTTS: true)   // gated: would block if spoken
        let c = h.controller
        c.begin()
        await waitFor("turn open straight away") { c.session.state == .awaitingUser }
        XCTAssertTrue(h.synth.spoken.isEmpty)
        XCTAssertEqual(c.session.transcript.first?.text, "Q1")   // shown, just not spoken
        c.cancel()
    }

    func testSecondReplyIsSpoken() async {
        // Only the FIRST statement is silent — the conversation is still spoken.
        let h = make(micMode: .ptt)
        let c = h.controller
        c.begin()
        await waitFor("opening") { c.session.state == .awaitingUser }
        XCTAssertTrue(h.synth.spoken.isEmpty)

        await advanceTurn(c)
        await waitFor("second reply spoken") { h.synth.spoken == ["Q2"] }
        c.cancel()
    }

    // MARK: - Half-duplex (SC-002)

    func testMicNeverArmsWhileTTSPlays() async {
        // Hands-free: drive one utterance so reply 2 is spoken and gated, then
        // prove no new capture engine opens until playback is released.
        let h = make(micMode: .handsFree, gatedTTS: true, speechOnFirstEngine: true)
        let c = h.controller
        c.begin()
        await waitFor("TTS started for reply 2") { h.synth.spoken == ["Q2"] }
        XCTAssertEqual(c.session.state, .presenting)
        let armsBefore = h.audio.startCount

        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(c.session.state, .presenting)
        XCTAssertEqual(h.audio.startCount, armsBefore)   // mic did not reopen
        XCTAssertFalse(c.session.state.allowsMic)

        h.synth.releaseAll()
        await waitFor("mic armed after playback") { c.session.state == .awaitingUser }
        await waitFor("new engine opened") { h.audio.startCount > armsBefore }
        c.cancel()
    }

    func testPTTStaysClosedUntilTap() async {
        let h = make(micMode: .ptt, gatedTTS: true)
        let c = h.controller
        c.begin()
        await waitFor("opening") { c.session.state == .awaitingUser }
        await advanceTurn(c)
        await waitFor("speaking reply 2") { h.synth.spoken == ["Q2"] }
        h.synth.releaseAll()
        await waitFor("awaiting user") { c.session.state == .awaitingUser }

        // PTT: no capture engine opens until the key is tapped.
        let armsBefore = h.audio.startCount
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(h.audio.startCount, armsBefore)
        c.handleHotkey()
        await waitFor("listening") { c.session.state == .listening }
        XCTAssertGreaterThan(h.audio.startCount, armsBefore)
        c.cancel()
    }

    func testKeyTapSkipsSpeechImmediately() async {
        let h = make(micMode: .ptt, gatedTTS: true)
        let c = h.controller
        c.begin()
        await waitFor("opening") { c.session.state == .awaitingUser }
        await advanceTurn(c)
        await waitFor("speaking") { h.synth.spoken == ["Q2"] }
        XCTAssertEqual(c.session.state, .presenting)

        c.handleHotkey()   // tap during playback = skip
        await waitFor("stopped") { h.synth.stopCount >= 1 }
        await waitFor("turn open") { c.session.state == .awaitingUser }
        c.cancel()
    }

    func testTTSFailureDegradesToTextOnly() async {
        // An instantly-returning synthesizer (a failed/very short synthesis):
        // the session proceeds with no user-facing error.
        let h = make(micMode: .ptt, gatedTTS: false)
        let c = h.controller
        c.begin()
        await waitFor("opening") { c.session.state == .awaitingUser }
        await advanceTurn(c)
        await waitFor("proceeded past TTS") {
            h.synth.spoken == ["Q2"] && c.session.state == .awaitingUser
        }
        XCTAssertNil(c.lastError)
        c.cancel()
    }

    // MARK: - Voice selection reaches the engine

    func testResolvedVoiceAndRateReachTheSynthesizer() async {
        // The 017 bug: no voice was ever set, so AVSpeechSynthesizer used the
        // platform default (a compact voice). Prove the selection travels.
        let h = make(micMode: .ptt)
        let c = h.controller
        h.synth.voices = [
            VoiceOption(identifier: "com.apple.speech.synthesis.voice.BadNews",
                        name: "Bad News", language: "en-US", tier: .basic),
            VoiceOption(identifier: "com.apple.voice.compact.en-US.Samantha",
                        name: "Samantha", language: "en-US", tier: .basic),
            VoiceOption(identifier: "com.apple.voice.premium.en-US.Ava",
                        name: "Ava", language: "en-US", tier: .premium),
        ]
        c.speechRate = 0.55
        XCTAssertEqual(c.resolvedVoice?.name, "Ava")        // best tier, not the novelty voice
        XCTAssertFalse(c.shouldSuggestVoiceDownload)         // a Premium voice IS installed

        c.begin()
        await waitFor("opening") { c.session.state == .awaitingUser }
        await advanceTurn(c)
        await waitFor("spoke") { h.synth.spoken == ["Q2"] }
        XCTAssertEqual(h.synth.spokenVoices.first??.voiceIdentifier,
                       "com.apple.voice.premium.en-US.Ava")
        XCTAssertEqual(h.synth.spokenVoices.first??.rate, 0.55)
        c.cancel()
    }

    func testStockMacSuggestsAVoiceDownload() async {
        let h = make()
        h.synth.voices = [
            VoiceOption(identifier: "com.apple.voice.compact.en-US.Samantha",
                        name: "Samantha", language: "en-US", tier: .basic),
            VoiceOption(identifier: "com.apple.speech.synthesis.voice.Zarvox",
                        name: "Zarvox", language: "en-US", tier: .basic),
        ]
        XCTAssertTrue(h.controller.shouldSuggestVoiceDownload)
        XCTAssertEqual(h.controller.resolvedVoice?.name, "Samantha")
    }

    func testUserVoiceChoiceOverridesAutoSelection() async {
        let h = make(micMode: .ptt)
        let c = h.controller
        h.synth.voices = [
            VoiceOption(identifier: "com.apple.voice.premium.en-US.Ava",
                        name: "Ava", language: "en-US", tier: .premium),
            VoiceOption(identifier: "com.apple.speech.synthesis.voice.Zarvox",
                        name: "Zarvox", language: "en-US", tier: .basic),
        ]
        c.voiceID = "com.apple.speech.synthesis.voice.Zarvox"
        c.begin()
        await waitFor("opening") { c.session.state == .awaitingUser }
        await advanceTurn(c)
        await waitFor("spoke") { h.synth.spoken == ["Q2"] }
        XCTAssertEqual(h.synth.spokenVoices.first??.voiceIdentifier,
                       "com.apple.speech.synthesis.voice.Zarvox")
        c.cancel()
    }

    // MARK: - 018: cloud failure falls back locally without breaking the gate

    func testCloudFailureSpeaksLocallyAndKeepsMicClosedMeanwhile() async {
        // SC-002/SC-003: the cloud attempt fails, the local voice takes over,
        // and the mic stays shut for the whole of the FALLBACK playback.
        let primary = FailingCloudPrimary(.http(429))
        let h = make(micMode: .ptt, gatedTTS: true, cloudPrimary: primary)
        let c = h.controller
        c.begin()
        await waitFor("opening") { c.session.state == .awaitingUser }
        await advanceTurn(c)
        await waitFor("fallback speaking") { h.synth.spoken == ["Q2"] }
        XCTAssertEqual(primary.attempts, 1)
        XCTAssertEqual(c.session.state, .presenting)

        let armsBefore = h.audio.startCount
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(h.audio.startCount, armsBefore)   // closed mid-fallback
        XCTAssertEqual(c.session.state, .presenting)

        h.synth.releaseAll()
        await waitFor("turn opens after fallback") { c.session.state == .awaitingUser }
        c.cancel()
    }

    func testCloudFailureIsSurfacedOnceAndSessionProceeds() async {
        let primary = FailingCloudPrimary(.http(429))
        let h = make(micMode: .ptt, cloudPrimary: primary)
        let c = h.controller
        c.begin()
        await waitFor("opening") { c.session.state == .awaitingUser }
        await advanceTurn(c)
        await waitFor("proceeded") {
            h.synth.spoken == ["Q2"] && c.session.state == .awaitingUser
        }
        // The user is told why the voice changed, once.
        XCTAssertEqual(c.lastError,
                       DiscussionController.cloudTTSMessage(SpeechSynthesisError.http(429)))
        c.cancel()
    }

    func testNoCloudRequestForTheSilentOpeningStatement() async {
        // The opening statement isn't spoken, so it must not be synthesized
        // either — no request, no spend, for a line nobody hears.
        let primary = FailingCloudPrimary(.http(429))
        let h = make(micMode: .ptt, cloudPrimary: primary)
        let c = h.controller
        c.begin()
        await waitFor("opening") { c.session.state == .awaitingUser }
        XCTAssertEqual(primary.attempts, 0)
        c.cancel()
    }

    // MARK: - Key handling (018)

    func testAPIKeyRoundTripsThroughTheSecretStoreAndDeletesOnEmpty() async {
        // T012/SC-005: the key lives in the Keychain (here an in-memory
        // stand-in) under its own account, and clearing the field deletes it.
        let defaults = UserDefaults(suiteName: "bark-key-test-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults, key: "k")
        let secrets = InMemorySecretStore()
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
        let store = CloudTTSConfigStore()
        let c = DiscussionController(
            settings: settings, dictation: dictation, hotkey: HotkeyManager(),
            capture: FakeContextCapture(.ok(Self.sampleContext)),
            localEngine: FakeDialogueEngine(replies: []),
            secretStore: secrets,
            stt: ScriptedSTTEngine(segments: []),
            audioFactory: { FakeAudioCapture() },
            synthesizer: FakeSpeechSynthesizer(),
            cloudConfig: store,
            targetProvider: { [target] in target },
            settleDelay: .zero
        )

        c.ttsAPIKey = "sk-secret"
        XCTAssertEqual(c.ttsAPIKey, "sk-secret")
        XCTAssertEqual(secrets.read(account: DiscussionController.ttsKeyAccount), "sk-secret")
        // Distinct account from the LLM endpoint's key, so either deletes alone.
        XCTAssertNotEqual(DiscussionController.ttsKeyAccount, SuggestionController.apiKeyAccount)
        XCTAssertNil(secrets.read(account: SuggestionController.apiKeyAccount))

        // Backend still on-device → the config pushed to the engine is disabled,
        // which is what makes the zero-egress guarantee structural.
        c.previewVoice()
        await waitFor("config pushed") { store.current.apiKey == "sk-secret" }
        XCTAssertFalse(store.current.enabled)
        XCTAssertFalse(c.cloudTTSNeedsKey)   // backend is .system, so no key is demanded

        c.ttsBackend = .elevenLabs
        c.previewVoice()
        await waitFor("enabled") { store.current.enabled }

        c.ttsAPIKey = ""
        XCTAssertNil(secrets.read(account: DiscussionController.ttsKeyAccount))
        XCTAssertTrue(c.cloudTTSNeedsKey)    // selected but unusable → pane says so
    }
}
