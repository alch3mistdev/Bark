import XCTest
@testable import BarkCore
@testable import BarkEngines
@testable import Bark

/// 017 US1: the full dialogue → synthesis → preview → inject loop with
/// injected fakes, in both mic modes, plus refusal/degrade/teardown paths.
@MainActor
final class DiscussionControllerFlowTests: XCTestCase {
    private let target = InjectionTarget(pid: 4242, bundleID: "com.example.TextEdit")

    private static let sampleContext = CapturedContext(
        source: .accessibility, appBundleID: "com.example.TextEdit", windowTitle: "Doc",
        fieldLabel: nil, fieldValue: nil, fieldPlaceholder: nil, fieldRole: "AXTextArea",
        windowText: "Quarterly report draft")

    private struct Harness {
        let controller: DiscussionController
        let dictation: DictationController
        let engine: FakeDialogueEngine
        let capture: FakeContextCapture
        let paste: FakeInjector
        let clip: FakeInjector
        let synth: FakeSpeechSynthesizer
        let settings: SettingsStore
    }

    private func make(
        replies: [FakeDialogueEngine.Outcome] = [
            .ok(#"{"reply": "What's the goal?", "ready": false}"#),
            .ok(#"{"reply": "Anything else?", "ready": false}"#),
            .ok(#"{"reply": "Ready for me to draft it?", "ready": true}"#),
            .ok(#"{"reply": "", "ready": true}"#),
        ],
        synthesis: FakeDialogueEngine.Outcome = .ok("Final prompt."),
        captureBehavior: FakeContextCapture.Behavior? = nil,
        sttSegments: [String] = ["I need a status update email", "keep it short", "yes"],
        micMode: DiscussionMicMode = .ptt,
        ttsEnabled: Bool = false,
        gatedTTS: Bool = false,
        pasteInjector: FakeInjector = FakeInjector(),
        audioFactory: @escaping @Sendable () -> AudioCapturing = { FakeAudioCapture() },
        replyDeadline: Double = 5,
        synthesisDeadline: Double = 5
    ) -> Harness {
        let defaults = UserDefaults(suiteName: "bark-discuss-test-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults, key: "k")
        settings.update {
            $0.selectedModeID = "raw"
            $0.llmEnabled = true
            $0.discussionEnabled = true
            $0.discussionMicMode = micMode
            $0.discussionTTSEnabled = ttsEnabled
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
        let engine = FakeDialogueEngine(replies: replies, synthesis: synthesis)
        let capture = FakeContextCapture(captureBehavior ?? .ok(Self.sampleContext))
        let clip = FakeInjector()
        let synth = FakeSpeechSynthesizer(gated: gatedTTS)
        let controller = DiscussionController(
            settings: settings, dictation: dictation, hotkey: HotkeyManager(),
            capture: capture, localEngine: engine,
            secretStore: InMemorySecretStore(),
            stt: ScriptedSTTEngine(segments: sttSegments),
            audioFactory: audioFactory,
            synthesizer: synth,
            pasteInjector: pasteInjector, keystrokeInjector: pasteInjector,
            clipboardInjector: clip,
            targetProvider: { [target] in target },
            replyDeadline: replyDeadline, synthesisDeadline: synthesisDeadline,
            sttFinalizeDeadline: 1, settleDelay: .zero
        )
        return Harness(controller: controller, dictation: dictation, engine: engine,
                       capture: capture, paste: pasteInjector, clip: clip, synth: synth,
                       settings: settings)
    }

    /// Polls until `condition` holds (or ~2 s passes).
    private func waitFor(_ what: String = "", _ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for \(what)")
    }

    // MARK: - Happy loop (PTT)

    func testFullLoopPTT() async {
        let h = make()
        let c = h.controller

        c.handleHotkey()   // F7: start session
        await waitFor("opening question") { c.session.state == .awaitingUser }
        XCTAssertTrue(c.session.hasContext)
        XCTAssertEqual(c.session.transcript.last?.text, "What's the goal?")
        XCTAssertEqual(h.dictation.micLeaseHeld, true)

        c.handleHotkey()   // F7: open turn
        await waitFor("listening") { c.session.state == .listening }
        c.handleHotkey()   // F7: close turn → STT final → engine reply
        await waitFor("second question") {
            c.session.state == .awaitingUser && c.session.transcript.count == 3
        }
        XCTAssertEqual(c.session.transcript[1],
                       DialogueTurn(role: .user, text: "I need a status update email"))

        c.done()
        await waitFor("preview") { c.session.state == .previewing }
        XCTAssertEqual(c.session.synthesizedPrompt, "Final prompt.")

        c.confirm()
        await waitFor("teardown") { c.session.state == .idle }
        XCTAssertEqual(h.paste.last, "Final prompt.")
        XCTAssertTrue(c.session.transcript.isEmpty)          // FR-010 wipe
        XCTAssertFalse(h.dictation.micLeaseHeld)             // lease released

        // The synthesis prompt was grounded in the fenced transcript.
        XCTAssertEqual(h.engine.synthesizeCalls.count, 1)
        XCTAssertTrue(h.engine.synthesizeCalls[0].turns.contains {
            $0.role == .user && $0.text.contains("status update email")
        })
    }

    // MARK: - Happy loop (hands-free VAD)

    func testVADTurnHandsFree() async {
        // 3 loud frames (onset at 2) + 10 quiet (hangover 8 → speechEnded).
        let h = make(micMode: .handsFree, audioFactory: {
            ScriptedAudioCapture(rmsLevels: [0.05, 0.05, 0.05] + Array(repeating: 0.001, count: 10))
        })
        let c = h.controller

        c.begin()
        await waitFor("opening question") { c.session.state != .capturing && c.session.state != .thinking }
        // VAD armed automatically; the scripted audio drives one utterance.
        await waitFor("user turn transcribed") { c.session.transcript.count >= 3 }
        XCTAssertEqual(c.session.transcript[1],
                       DialogueTurn(role: .user, text: "I need a status update email"))
        await waitFor("back to user") { c.session.state == .awaitingUser }
        c.cancel()
        await waitFor("idle") { c.session.state == .idle }
    }

    // MARK: - Readiness / synthesis trigger

    func testEngineTriggerSynthesizesWithoutDone() async {
        let h = make(
            replies: [
                .ok(#"{"reply": "What's the goal?", "ready": false}"#),
                .ok(#"{"reply": "Ready for me to draft it?", "ready": true}"#),
                .ok(#"{"reply": "", "ready": true}"#),   // trigger after the user's "yes"
            ],
            sttSegments: ["a launch email", "yes"]
        )
        let c = h.controller
        c.begin()
        await waitFor("q1") { c.session.state == .awaitingUser }

        c.handleHotkey(); await waitFor("listen1") { c.session.state == .listening }
        c.handleHotkey()
        await waitFor("ready question") { c.session.readySignaled }

        c.handleHotkey(); await waitFor("listen2") { c.session.state == .listening }
        c.handleHotkey()
        await waitFor("preview via trigger") { c.session.state == .previewing }
        XCTAssertEqual(c.session.synthesizedPrompt, "Final prompt.")
        XCTAssertEqual(h.engine.synthesizeCalls.count, 1)
    }

    // MARK: - Refusals & degrades

    func testDisabledHotkeyIsNoOp() async {
        let h = make()
        h.settings.update { $0.discussionEnabled = false }
        h.controller.handleHotkey()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(h.controller.session.state, .idle)
        XCTAssertEqual(h.capture.captureCount, 0)
    }

    func testSecureFieldRefusesSession() async {
        let h = make(captureBehavior: .fail(.secureField))
        let c = h.controller
        c.begin()
        await waitFor("refused") { c.session.state == .idle }
        XCTAssertNotNil(c.lastError)
        XCTAssertFalse(h.dictation.micLeaseHeld)   // lease released on refusal
        XCTAssertEqual(h.engine.replyCalls.count, 0)
    }

    func testCaptureFailureDegradesToContextless() async {
        let h = make(captureBehavior: .fail(.accessibilityDenied))
        let c = h.controller
        c.begin()
        await waitFor("opening question") { c.session.state == .awaitingUser }
        XCTAssertFalse(c.session.hasContext)
        // The engine got a system prompt without a context block.
        XCTAssertFalse(h.engine.replyCalls[0].system.contains(SuggestionPrompt.contextOpenTag + "\n"))
    }

    func testHotkeyDuringActiveSessionStartsNoSecondSession() async {
        let h = make(micMode: .handsFree)   // hotkey has no PTT meaning here
        let c = h.controller
        c.begin()
        await waitFor("active") { c.session.state == .awaitingUser }
        c.handleHotkey()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(h.capture.captureCount, 1)
        c.cancel()
    }

    // MARK: - Mic lease + hands-free suspend/resume

    func testHandsFreeSuspendedAndResumedAroundSession() async {
        let h = make()
        await h.dictation.warmModel()
        h.dictation.startHandsFree()
        XCTAssertTrue(h.dictation.handsFreeActive)

        h.controller.begin()
        await waitFor("session up") { h.controller.session.state == .awaitingUser }
        XCTAssertFalse(h.dictation.handsFreeActive)   // suspended
        XCTAssertTrue(h.dictation.micLeaseHeld)

        h.controller.cancel()
        await waitFor("idle") { h.controller.session.state == .idle }
        XCTAssertTrue(h.dictation.handsFreeActive)    // resumed
        XCTAssertFalse(h.dictation.micLeaseHeld)
        h.dictation.stopHandsFree()
    }

    // MARK: - Engine failure paths

    func testEngineFailureKeepsTranscriptAndRetryWorks() async {
        let h = make(replies: [
            .ok(#"{"reply": "What's the goal?", "ready": false}"#),
            .fail(.transport("boom")),
            .ok(#"{"reply": "Recovered question", "ready": false}"#),
        ])
        let c = h.controller
        c.begin()
        await waitFor("q1") { c.session.state == .awaitingUser }
        c.handleHotkey(); await waitFor("listen") { c.session.state == .listening }
        c.handleHotkey()
        await waitFor("turn failed") { c.session.state == .turnFailed }
        XCTAssertEqual(c.session.transcript.count, 2)   // opening + user turn intact
        XCTAssertNotNil(c.lastError)

        c.retryTurn()
        await waitFor("recovered") {
            c.session.state == .awaitingUser && c.session.transcript.count == 3
        }
        XCTAssertEqual(c.session.transcript.last?.text, "Recovered question")
    }

    func testEngineDeadlineSurfacesAsTurnFailed() async {
        let h = make(replies: [.hang], replyDeadline: 0.15)
        let c = h.controller
        c.begin()
        await waitFor("deadline") { c.session.state == .turnFailed }
        XCTAssertEqual(c.lastError, DiscussionController.engineMessage(DialogueError.deadlineExceeded))
    }

    func testSynthesisFailureTwiceThenTranscriptCopy() async {
        let h = make(synthesis: .fail(.badResponse("junk")))
        let c = h.controller
        c.begin()
        await waitFor("q1") { c.session.state == .awaitingUser }
        c.done()
        await waitFor("fail 1") { c.session.state == .synthesisFailed }
        XCTAssertEqual(c.session.synthesisFailures, 1)
        c.retrySynthesis()
        await waitFor("fail 2") { c.session.synthesisFailures == 2 }
        XCTAssertFalse(c.session.transcript.isEmpty)   // never lost (SC-004)

        c.copyTranscript()
        await waitFor("copied") { h.clip.count == 1 }
        XCTAssertTrue(h.clip.last?.contains("What's the goal?") ?? false)
    }

    // MARK: - Preview / injection

    func testResumeDiscardsPromptAndSecondDoneRedrafts() async {
        let h = make()
        let c = h.controller
        c.begin()
        await waitFor("q1") { c.session.state == .awaitingUser }
        c.done()
        await waitFor("preview") { c.session.state == .previewing }
        c.resume()
        XCTAssertEqual(c.session.state, .awaitingUser)
        XCTAssertNil(c.session.synthesizedPrompt)
        c.done()
        await waitFor("preview 2") { c.session.state == .previewing }
        XCTAssertEqual(h.engine.synthesizeCalls.count, 2)
    }

    func testInjectionFocusChangeReturnsToPreviewAndCopyWorks() async {
        let h = make(pasteInjector: FakeInjector(.focusChanged, failTimes: 99))
        let c = h.controller
        c.begin()
        await waitFor("q1") { c.session.state == .awaitingUser }
        c.done()
        await waitFor("preview") { c.session.state == .previewing }
        c.confirm()
        await waitFor("back to preview") {
            c.session.state == .previewing && c.lastError != nil
        }
        XCTAssertEqual(c.session.synthesizedPrompt, "Final prompt.")   // prompt survives

        c.copyPrompt()
        await waitFor("copied") { h.clip.count == 1 }
        XCTAssertEqual(h.clip.last, "Final prompt.")
    }

    func testInjectionSecureFieldRefusal() async {
        let h = make(pasteInjector: FakeInjector(.secure, failTimes: 99))
        let c = h.controller
        c.begin()
        await waitFor("q1") { c.session.state == .awaitingUser }
        c.done()
        await waitFor("preview") { c.session.state == .previewing }
        c.confirm()
        await waitFor("refused") { c.session.state == .previewing && c.lastError != nil }
        XCTAssertEqual(c.lastError, DiscussionController.injectionMessage(InjectionError.secureFieldBlocked))
        XCTAssertEqual(h.paste.count, 0)
    }

    func testCancelWipesEverything() async {
        let h = make()
        let c = h.controller
        c.begin()
        await waitFor("q1") { c.session.state == .awaitingUser }
        XCTAssertFalse(c.session.transcript.isEmpty)
        c.cancel()
        await waitFor("idle") { c.session.state == .idle }
        XCTAssertTrue(c.session.transcript.isEmpty)
        XCTAssertNil(c.session.synthesizedPrompt)
        XCTAssertFalse(h.dictation.micLeaseHeld)
        XCTAssertEqual(h.paste.count, 0)
    }
}
