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

    func testResolvedVoiceAndRateReachTheSynthesizer() async {
        // The 017 bug: no voice was ever set, so AVSpeechSynthesizer used the
        // platform default (a compact voice). Prove the selection now travels.
        let (c, synth, _) = make(micMode: .ptt, gatedTTS: false)
        synth.voices = [
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
        await waitFor("spoke") { synth.spoken.count == 1 }
        XCTAssertEqual(synth.spokenVoices.first??.voiceIdentifier,
                       "com.apple.voice.premium.en-US.Ava")
        XCTAssertEqual(synth.spokenVoices.first??.rate, 0.55)
        c.cancel()
    }

    func testStockMacSuggestsAVoiceDownload() async {
        let (c, synth, _) = make(micMode: .ptt, gatedTTS: false)
        synth.voices = [
            VoiceOption(identifier: "com.apple.voice.compact.en-US.Samantha",
                        name: "Samantha", language: "en-US", tier: .basic),
            VoiceOption(identifier: "com.apple.speech.synthesis.voice.Zarvox",
                        name: "Zarvox", language: "en-US", tier: .basic),
        ]
        XCTAssertTrue(c.shouldSuggestVoiceDownload)
        XCTAssertEqual(c.resolvedVoice?.name, "Samantha")
    }

    func testUserVoiceChoiceOverridesAutoSelection() async {
        let (c, synth, _) = make(micMode: .ptt, gatedTTS: false)
        synth.voices = [
            VoiceOption(identifier: "com.apple.voice.premium.en-US.Ava",
                        name: "Ava", language: "en-US", tier: .premium),
            VoiceOption(identifier: "com.apple.speech.synthesis.voice.Zarvox",
                        name: "Zarvox", language: "en-US", tier: .basic),
        ]
        c.voiceID = "com.apple.speech.synthesis.voice.Zarvox"
        c.begin()
        await waitFor("spoke") { synth.spoken.count == 1 }
        XCTAssertEqual(synth.spokenVoices.first??.voiceIdentifier,
                       "com.apple.speech.synthesis.voice.Zarvox")
        c.cancel()
    }

    // MARK: - 018: cloud failure falls back locally without breaking the gate

    /// Builds a controller whose speech path is the real composite with an
    /// always-failing cloud primary and a *gated* local fallback.
    private func makeWithFailingCloud()
    -> (DiscussionController, FakeSpeechSynthesizer, FailingCloudPrimary, CountingAudioFactory) {
        let defaults = UserDefaults(suiteName: "bark-cloudtts-test-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults, key: "k")
        settings.update {
            $0.selectedModeID = "raw"; $0.llmEnabled = true
            $0.discussionEnabled = true
            $0.discussionMicMode = .handsFree
            $0.discussionTTSEnabled = true
            $0.discussionTTSBackend = .elevenLabs
        }
        let perms = PermissionsCoordinator()
        perms.overrideForTesting(microphone: .granted)
        let audio = CountingAudioFactory()
        let dictation = DictationController(
            settings: settings, permissions: perms, hotkey: HotkeyManager(),
            stt: FakeSTTEngine(finalText: "hi"), llmCleaner: FakeCleaner(.ok("hi")),
            history: nil, audioFactory: { FakeAudioCapture() },
            pasteInjector: FakeInjector(), keystrokeInjector: FakeInjector(),
            clipboardInjector: FakeInjector(),
            cleanupDeadline: 0.3, targetProvider: { [target] in target }
        )
        let local = FakeSpeechSynthesizer(gated: true)
        let primary = FailingCloudPrimary(.http(429))
        let composite = FallbackSpeechSynthesizer(primary: primary, fallback: local)
        let engine = FakeDialogueEngine(replies: [.ok(#"{"reply": "Q1", "ready": false}"#)])
        let controller = DiscussionController(
            settings: settings, dictation: dictation, hotkey: HotkeyManager(),
            capture: FakeContextCapture(.ok(Self.sampleContext)), localEngine: engine,
            secretStore: InMemorySecretStore(),
            stt: ScriptedSTTEngine(segments: []),
            audioFactory: { audio.make() },
            synthesizer: composite,
            cloudConfig: CloudTTSConfigStore(),
            cloudTTS: composite,
            targetProvider: { [target] in target },
            replyDeadline: 5, synthesisDeadline: 5, sttFinalizeDeadline: 1, settleDelay: .zero
        )
        composite.onCloudFailure = { [weak controller] error in
            Task { @MainActor in controller?.reportCloudTTSFailure(error) }
        }
        return (controller, local, primary, audio)
    }

    func testCloudFailureSpeaksLocallyAndKeepsMicClosedMeanwhile() async {
        // SC-002/SC-003: the cloud attempt fails, the local voice takes over,
        // and the mic must stay shut for the whole of the FALLBACK playback.
        let (c, local, primary, audio) = makeWithFailingCloud()
        c.begin()
        await waitFor("fallback speaking") { local.spoken.count == 1 }
        XCTAssertEqual(primary.attempts, 1)
        XCTAssertEqual(c.session.state, .presenting)

        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(audio.startCount, 0)          // mic still closed mid-fallback
        XCTAssertEqual(c.session.state, .presenting)

        local.releaseAll()
        await waitFor("mic armed after fallback") { c.session.state == .awaitingUser }
        await waitFor("audio opened") { audio.startCount == 1 }
        c.cancel()
    }

    func testAPIKeyRoundTripsThroughTheSecretStoreAndDeletesOnEmpty() async {
        // T012/SC-005: the key lives in the Keychain (here an in-memory stand-in)
        // under its own account, and clearing the field deletes it.
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
        XCTAssertTrue(c.cloudTTSNeedsKey == false)   // backend is .system, so no key is demanded

        c.ttsBackend = .elevenLabs
        c.previewVoice()
        await waitFor("enabled") { store.current.enabled }

        c.ttsAPIKey = ""
        XCTAssertNil(secrets.read(account: DiscussionController.ttsKeyAccount))
        XCTAssertTrue(c.cloudTTSNeedsKey)            // selected but unusable → pane says so
    }

    func testCloudFailureIsSurfacedOnceAndSessionProceeds() async {
        let (c, local, _, _) = makeWithFailingCloud()
        c.begin()
        await waitFor("fallback speaking") { local.spoken.count == 1 }
        local.releaseAll()
        await waitFor("proceeded") { c.session.state == .awaitingUser }
        // The user is told why the voice changed, once.
        XCTAssertEqual(c.lastError,
                       DiscussionController.cloudTTSMessage(SpeechSynthesisError.http(429)))
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
