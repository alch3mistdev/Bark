import XCTest
@testable import BarkCore
@testable import BarkEngines
@testable import Bark

/// 017 US3: mid-session Recapture replaces the snapshot (grounding subsequent
/// prompts) and a failed recapture keeps the previous context.
@MainActor
final class DiscussionRecaptureTests: XCTestCase {
    private let target = InjectionTarget(pid: 4242, bundleID: "com.example.TextEdit")

    /// Capture whose scripted results are consumed one per call (test-local,
    /// like StreamingFakeEngine in the 016 suite).
    final class SequencedContextCapture: ContextCapturing, @unchecked Sendable {
        private var script: [Result<CapturedContext, ContextCaptureError>]
        private(set) var captureCount = 0
        init(_ script: [Result<CapturedContext, ContextCaptureError>]) { self.script = script }
        func capture(target: InjectionTarget) async throws -> CapturedContext {
            captureCount += 1
            guard !script.isEmpty else { throw ContextCaptureError.empty }
            switch script.removeFirst() {
            case .success(let context): return context
            case .failure(let error): throw error
            }
        }
    }

    private func context(_ text: String) -> CapturedContext {
        CapturedContext(source: .accessibility, appBundleID: "com.example.TextEdit",
                        windowTitle: "Doc", fieldLabel: nil, fieldValue: nil,
                        fieldPlaceholder: nil, fieldRole: "AXTextArea", windowText: text)
    }

    private func make(capture: SequencedContextCapture,
                      replies: [FakeDialogueEngine.Outcome])
    -> (DiscussionController, FakeDialogueEngine) {
        let defaults = UserDefaults(suiteName: "bark-recap-test-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults, key: "k")
        settings.update {
            $0.selectedModeID = "raw"; $0.llmEnabled = true
            $0.discussionEnabled = true; $0.discussionMicMode = .ptt
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
        let engine = FakeDialogueEngine(replies: replies)
        let controller = DiscussionController(
            settings: settings, dictation: dictation, hotkey: HotkeyManager(),
            capture: capture, localEngine: engine,
            secretStore: InMemorySecretStore(),
            stt: ScriptedSTTEngine(segments: ["what do you see now"]),
            audioFactory: { FakeAudioCapture() },
            synthesizer: FakeSpeechSynthesizer(),
            pasteInjector: FakeInjector(), keystrokeInjector: FakeInjector(),
            clipboardInjector: FakeInjector(),
            targetProvider: { [target] in target },
            replyDeadline: 5, synthesisDeadline: 5, sttFinalizeDeadline: 1, settleDelay: .zero
        )
        return (controller, engine)
    }

    private func waitFor(_ what: String, _ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for \(what)")
    }

    func testRecaptureReplacesSnapshotForSubsequentPrompts() async {
        let capture = SequencedContextCapture([
            .success(context("OLD WINDOW TEXT")),
            .success(context("NEW WINDOW TEXT")),
        ])
        let (c, engine) = make(capture: capture, replies: [
            .ok(#"{"reply": "Q1", "ready": false}"#),
            .ok(#"{"reply": "Q2", "ready": false}"#),
        ])
        c.begin()
        await waitFor("q1") { c.session.state == .awaitingUser }
        XCTAssertTrue(engine.replyCalls[0].system.contains("OLD WINDOW TEXT"))

        c.recapture()
        await waitFor("recaptured") { capture.captureCount == 2 }

        c.handleHotkey(); await waitFor("listening") { c.session.state == .listening }
        c.handleHotkey()
        await waitFor("q2") { engine.replyCalls.count == 2 }
        XCTAssertTrue(engine.replyCalls[1].system.contains("NEW WINDOW TEXT"))
        XCTAssertFalse(engine.replyCalls[1].system.contains("OLD WINDOW TEXT"))
        c.cancel()
    }

    func testFailedRecaptureKeepsPreviousContext() async {
        let capture = SequencedContextCapture([
            .success(context("ORIGINAL")),
            .failure(.accessibilityDenied),
        ])
        let (c, engine) = make(capture: capture, replies: [
            .ok(#"{"reply": "Q1", "ready": false}"#),
            .ok(#"{"reply": "Q2", "ready": false}"#),
        ])
        c.begin()
        await waitFor("q1") { c.session.state == .awaitingUser }

        c.recapture()
        await waitFor("recapture attempted") { capture.captureCount == 2 }
        await waitFor("notice surfaced") { c.lastError != nil }

        c.handleHotkey(); await waitFor("listening") { c.session.state == .listening }
        c.handleHotkey()
        await waitFor("q2") { engine.replyCalls.count == 2 }
        XCTAssertTrue(engine.replyCalls[1].system.contains("ORIGINAL"))   // prior snapshot retained
        c.cancel()
    }

    func testRecaptureIgnoredOutsideAllowedStates() async {
        let capture = SequencedContextCapture([.success(context("X"))])
        let (c, _) = make(capture: capture, replies: [.ok(#"{"reply": "Q1", "ready": false}"#)])
        c.recapture()   // idle: no session target → no-op
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(capture.captureCount, 0)
        c.begin()
        await waitFor("q1") { c.session.state == .awaitingUser }
        c.done()
        await waitFor("preview") { c.session.state == .previewing }
        c.recapture()   // previewing: not an allowed state
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(capture.captureCount, 1)
        c.cancel()
    }
}
