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
    /// Lock-protected: recapture can run while a turn's own capture is still
    /// in flight, so this fake IS called concurrently. Mutating the script
    /// array unsynchronized (as the first version did behind `@unchecked
    /// Sendable`) corrupted the heap and crashed an unrelated suite later in
    /// the run.
    final class SequencedContextCapture: ContextCapturing, @unchecked Sendable {
        private let lock = NSLock()
        private var script: [Result<CapturedContext, ContextCaptureError>]
        private var count = 0

        init(_ script: [Result<CapturedContext, ContextCaptureError>]) { self.script = script }

        var captureCount: Int { lock.lock(); defer { lock.unlock() }; return count }

        private func next() -> Result<CapturedContext, ContextCaptureError> {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            guard !script.isEmpty else { return .failure(.empty) }
            return script.removeFirst()
        }

        func capture(target: InjectionTarget) async throws -> CapturedContext {
            switch next() {
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

    func testRecaptureWorksInEveryStateWhereTheButtonIsOffered() async {
        // The old guard allowed only awaitingUser/presenting/turnFailed while
        // the overlay showed the button in thinking/listening/transcribing too,
        // so those clicks silently did nothing. Recapture only swaps the data
        // the NEXT prompt is built from, so it is valid in all of them.
        let capture = SequencedContextCapture([
            .success(context("FIRST")), .success(context("SECOND")), .success(context("THIRD")),
        ])
        let (c, _) = make(capture: capture, replies: [
            .ok(#"{"reply": "Q1", "ready": false}"#),
            .ok(#"{"reply": "Q2", "ready": false}"#),
        ])
        c.begin()
        await waitFor("awaitingUser") { c.session.state == .awaitingUser }
        XCTAssertTrue(c.canRecapture)

        // listening: mid-utterance re-read is harmless and now permitted.
        c.handleHotkey()
        await waitFor("listening") { c.session.state == .listening }
        XCTAssertTrue(c.canRecapture)
        c.recapture()
        await waitFor("re-read while listening") { capture.captureCount == 2 }
        XCTAssertEqual(c.session.contextVersion, 1)

        c.cancel()
    }

    func testSuccessfulRecaptureIsObservable() async {
        // The original bug as the user experienced it: a working recapture
        // changed nothing on screen. contextVersion is what the overlay shows.
        let capture = SequencedContextCapture([
            .success(context("BEFORE")), .success(context("AFTER")),
        ])
        let (c, _) = make(capture: capture, replies: [.ok(#"{"reply": "Q1", "ready": false}"#)])
        c.begin()
        await waitFor("q1") { c.session.state == .awaitingUser }
        XCTAssertEqual(c.session.contextVersion, 0)
        XCTAssertTrue(c.session.hasContext)

        c.recapture()
        await waitFor("version bumped") { c.session.contextVersion == 1 }
        XCTAssertFalse(c.isRecapturing)      // progress flag clears
        XCTAssertNil(c.lastError)
        XCTAssertEqual(c.session.state, .awaitingUser)   // state untouched by a refresh
        c.cancel()
    }

    func testFailedRecaptureDoesNotClaimSuccess() async {
        let capture = SequencedContextCapture([
            .success(context("ORIGINAL")), .failure(.empty),
        ])
        let (c, _) = make(capture: capture, replies: [.ok(#"{"reply": "Q1", "ready": false}"#)])
        c.begin()
        await waitFor("q1") { c.session.state == .awaitingUser }
        c.recapture()
        await waitFor("failure surfaced") { c.lastError != nil }
        XCTAssertEqual(c.session.contextVersion, 0)   // no false confirmation
        XCTAssertFalse(c.isRecapturing)
        c.cancel()
    }

    func testSecureFieldOnRecaptureIsReportedDistinctly() async {
        let capture = SequencedContextCapture([
            .success(context("ORIGINAL")), .failure(.secureField),
        ])
        let (c, _) = make(capture: capture, replies: [.ok(#"{"reply": "Q1", "ready": false}"#)])
        c.begin()
        await waitFor("q1") { c.session.state == .awaitingUser }
        c.recapture()
        await waitFor("refusal surfaced") { c.lastError != nil }
        XCTAssertTrue(c.lastError?.contains("secure field") ?? false)
        XCTAssertEqual(c.session.contextVersion, 0)
        c.cancel()
    }

    func testRecaptureIgnoredOutsideAllowedStates() async {
        let capture = SequencedContextCapture([.success(context("X"))])
        let (c, _) = make(capture: capture, replies: [
            .ok(#"{"reply": "Q1", "ready": false}"#),
            .ok(#"{"reply": "Q2", "ready": false}"#),
        ])
        c.recapture()   // idle: no session target → no-op
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(capture.captureCount, 0)
        c.begin()
        await waitFor("q1") { c.session.state == .awaitingUser }
        // A user turn is required before Done will synthesize.
        c.handleHotkey()
        await waitFor("listening") { c.session.state == .listening }
        c.handleHotkey()
        await waitFor("turn processed") { c.session.state == .awaitingUser }
        c.done()
        await waitFor("preview") { c.session.state == .previewing }
        XCTAssertFalse(c.canRecapture)   // the draft is already written
        c.recapture()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(capture.captureCount, 1)
        c.cancel()
    }
}
