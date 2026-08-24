import XCTest
@testable import BarkCore
@testable import BarkEngines
@testable import Bark

/// 016 flow tests: progressive candidate fill (US1), early selection / cancel
/// mid-stream (US2), and the prewarm-overlaps-capture guarantee (US3), all
/// against a scripted streaming fake engine.
@MainActor
final class SuggestionStreamingFlowTests: XCTestCase {
    private let terminalTarget = InjectionTarget(pid: 4242, bundleID: "com.apple.Terminal")

    /// Streaming engine the test drives by hand: emit chunks, finish, observe
    /// cancellation. `suggest` is intentionally unused — these tests exercise
    /// the native-streaming path; the batch default is covered by the 015
    /// suite (SC-005).
    final class StreamingFakeEngine: SuggestionEngine, @unchecked Sendable {
        private(set) var requests: [SuggestionRequest] = []
        private(set) var streamCancelled = false
        private var continuation: AsyncThrowingStream<String, Error>.Continuation?

        var streamStarted: Bool { continuation != nil }
        var isAvailable: Bool { get async { true } }

        func suggest(_ request: SuggestionRequest) async throws -> String { "" }

        func suggestStream(_ request: SuggestionRequest) -> AsyncThrowingStream<String, Error> {
            requests.append(request)
            return AsyncThrowingStream { cont in
                self.continuation = cont
                cont.onTermination = { [weak self] reason in
                    if case .cancelled = reason { self?.streamCancelled = true }
                }
            }
        }

        func emit(_ chunk: String) { continuation?.yield(chunk) }
        func finishStream() { continuation?.finish() }
    }

    /// Context capture that completes only when the test releases it — lets a
    /// test observe what happened strictly BEFORE capture finished (US3).
    final class GatedContextCapture: ContextCapturing, @unchecked Sendable {
        private let context: CapturedContext
        private(set) var captureStarted = false
        private(set) var captureCompleted = false
        private var release: CheckedContinuation<Void, Never>?
        private var released = false

        init(_ context: CapturedContext) { self.context = context }

        func capture(target: InjectionTarget) async throws -> CapturedContext {
            captureStarted = true
            if !released {
                await withCheckedContinuation { self.release = $0 }
            }
            captureCompleted = true
            return context
        }

        func releaseCapture() {
            released = true
            release?.resume()
            release = nil
        }
    }

    private struct Harness {
        let suggestions: SuggestionController
        let dictation: DictationController
        let keystroke: FakeInjector
        let paste: FakeInjector
        let engine: StreamingFakeEngine
    }

    private func makeContext() -> CapturedContext {
        CapturedContext(source: .accessibility, appBundleID: "com.apple.Terminal", windowTitle: "zsh",
                        fieldLabel: nil, fieldValue: nil, fieldPlaceholder: nil, fieldRole: "AXTextArea",
                        windowText: "Agent finished the refactor. What should I do next?")
    }

    private func make(capture: ContextCapturing,
                      engine: StreamingFakeEngine = StreamingFakeEngine(),
                      generationDeadline: Double = 5) -> Harness {
        let defaults = UserDefaults(suiteName: "bark-stream-test-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults, key: "k")
        settings.update {
            $0.suggestionsEnabled = true
            $0.llmEnabled = true
            $0.outputRouting = .insert
        }
        let perms = PermissionsCoordinator()
        perms.overrideForTesting(microphone: .granted)

        let dictation = DictationController(
            settings: settings, permissions: perms, hotkey: HotkeyManager(),
            stt: FakeSTTEngine(), llmCleaner: FakeCleaner(.ok("cleaned")), history: nil,
            audioFactory: { FakeAudioCapture() },
            pasteInjector: FakeInjector(), keystrokeInjector: FakeInjector(),
            clipboardInjector: FakeInjector(),
            targetProvider: { [target = terminalTarget] in target }
        )

        let keystroke = FakeInjector()
        let paste = FakeInjector()
        let suggestions = SuggestionController(
            settings: settings,
            dictation: dictation,
            hotkey: HotkeyManager(),
            capture: capture,
            localEngine: engine,
            secretStore: InMemorySecretStore(),
            pasteInjector: paste,
            keystrokeInjector: keystroke,
            clipboardInjector: FakeInjector(),
            returnSynthesizer: FakeReturnSynthesizer(),
            targetProvider: { [target = terminalTarget] in target },
            secureInputCheck: { false },
            generationDeadline: generationDeadline,
            settleDelay: .zero
        )
        return Harness(suggestions: suggestions, dictation: dictation,
                       keystroke: keystroke, paste: paste, engine: engine)
    }

    private func waitFor(_ condition: @autoclosure @MainActor () -> Bool, timeout: Double = 4) async {
        for _ in 0..<Int(timeout * 50) {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - US1: progressive fill

    func testCandidatesAppearProgressivelyWithStableNumbering() async {
        let h = make(capture: FakeContextCapture(.ok(makeContext())))
        h.suggestions.handleHotkey()
        await waitFor(h.engine.streamStarted)
        XCTAssertEqual(h.suggestions.session.phase, .generating)
        XCTAssertTrue(h.suggestions.session.isStreaming)

        h.engine.emit(#"["Run the tests", "#)
        await waitFor(h.suggestions.session.candidates.count == 1)
        XCTAssertEqual(h.suggestions.session.phase, .presenting)     // first candidate presents immediately
        XCTAssertEqual(h.suggestions.session.candidates, ["Run the tests"])
        XCTAssertTrue(h.suggestions.session.isStreaming)

        h.engine.emit(#""Commit and open a PR", "Refac"#)
        await waitFor(h.suggestions.session.candidates.count == 2)
        XCTAssertEqual(h.suggestions.session.candidates, ["Run the tests", "Commit and open a PR"])

        h.engine.emit(#"tor first"]"#)
        await waitFor(h.suggestions.session.candidates.count == 3)
        XCTAssertEqual(h.suggestions.session.candidates,
                       ["Run the tests", "Commit and open a PR", "Refactor first"])   // arrival order, never reordered

        h.engine.finishStream()
        await waitFor(!h.suggestions.session.isStreaming)
        XCTAssertEqual(h.suggestions.session.phase, .presenting)     // footer cleared, rows intact
        XCTAssertEqual(h.suggestions.session.candidates.count, 3)
    }

    func testZeroCandidateStreamFailsHonestly() async {
        let h = make(capture: FakeContextCapture(.ok(makeContext())))
        h.suggestions.handleHotkey()
        await waitFor(h.engine.streamStarted)
        h.engine.emit("I have no list for you today.")
        h.engine.finishStream()
        await waitFor({ if case .failed = h.suggestions.session.phase { return true }; return false }())
        XCTAssertEqual(h.suggestions.session.phase,
                       .failed("Couldn't produce suggestions for this screen."))
        XCTAssertEqual(h.keystroke.count + h.paste.count, 0)
    }

    func testDeadlineWithPartialSetCompletesNormally() async {
        let h = make(capture: FakeContextCapture(.ok(makeContext())), generationDeadline: 0.3)
        h.suggestions.handleHotkey()
        await waitFor(h.engine.streamStarted)
        h.engine.emit(#"["Run the tests", "#)   // one candidate shown, stream never finishes
        await waitFor(h.suggestions.session.candidates.count == 1)

        await waitFor(!h.suggestions.session.isStreaming, timeout: 2)   // deadline fires
        XCTAssertEqual(h.suggestions.session.phase, .presenting)        // FR-011: partial set is success
        XCTAssertEqual(h.suggestions.session.candidates, ["Run the tests"])
    }

    func testCandidateCapTearsDownStream() async {
        let h = make(capture: FakeContextCapture(.ok(makeContext())))
        h.suggestions.handleHotkey()
        await waitFor(h.engine.streamStarted)
        h.engine.emit(#"["a1","b2","c3","d4","e5","f6"]"#)
        await waitFor(h.suggestions.session.candidates.count == 4)
        XCTAssertEqual(h.suggestions.session.candidates, ["a1", "b2", "c3", "d4"])
        await waitFor(h.engine.streamCancelled)
        XCTAssertTrue(h.engine.streamCancelled)   // producer stopped at the cap
        await waitFor(!h.suggestions.session.isStreaming)
        XCTAssertEqual(h.suggestions.session.phase, .presenting)
    }

    // MARK: - US2: act immediately

    func testEarlySelectionMidStreamInjectsExactTextAndCancelsRest() async {
        let h = make(capture: FakeContextCapture(.ok(makeContext())))
        h.suggestions.handleHotkey()
        await waitFor(h.engine.streamStarted)
        h.engine.emit(#"["Run the tests", "#)
        await waitFor(h.suggestions.session.candidates.count == 1)

        h.suggestions.choose(0)                      // pick while 2–4 still pending
        await waitFor(h.suggestions.session.phase == .idle)
        XCTAssertEqual(h.keystroke.last, "Run the tests")   // exactly the chosen text
        XCTAssertEqual(h.keystroke.count, 1)
        await waitFor(h.engine.streamCancelled)
        XCTAssertTrue(h.engine.streamCancelled)

        // A late chunk after dismissal must not resurrect any UI state.
        h.engine.emit(#""Late arrival"]"#)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(h.suggestions.session.phase, .idle)
        XCTAssertTrue(h.suggestions.session.candidates.isEmpty)
        XCTAssertEqual(h.keystroke.count, 1)
    }

    func testEscapeMidStreamCancelsGenerationAndInjectsNothing() async {
        let h = make(capture: FakeContextCapture(.ok(makeContext())))
        h.suggestions.handleHotkey()
        await waitFor(h.engine.streamStarted)
        h.engine.emit(#"["Run the tests", "#)
        await waitFor(h.suggestions.session.candidates.count == 1)

        h.suggestions.dismiss()
        XCTAssertEqual(h.suggestions.session.phase, .idle)
        await waitFor(h.engine.streamCancelled)
        XCTAssertTrue(h.engine.streamCancelled)
        XCTAssertEqual(h.keystroke.count + h.paste.count, 0)

        h.engine.emit(#""Late"]"#)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(h.suggestions.session.phase, .idle)   // no post-dismiss updates
    }

    func testOtherBeforeFirstCandidateStartsDictationAndAbandonsGeneration() async {
        let h = make(capture: FakeContextCapture(.ok(makeContext())))
        await h.dictation.warmModel()   // one-shot dictation needs a ready pipeline
        h.suggestions.handleHotkey()
        await waitFor(h.engine.streamStarted)
        XCTAssertEqual(h.suggestions.session.phase, .generating)

        h.suggestions.chooseOther()                  // FR-012: escape hatch before any candidate
        XCTAssertEqual(h.suggestions.session.phase, .dictating)
        await waitFor(h.engine.streamCancelled)
        XCTAssertTrue(h.engine.streamCancelled)
        XCTAssertEqual(h.keystroke.count + h.paste.count, 0)
    }

    // MARK: - US3: prewarm guarantee

    func testEnginePreparationBeginsBeforeCaptureCompletes() async {
        let capture = GatedContextCapture(makeContext())
        let h = make(capture: capture)
        let statusBefore = h.dictation.llmStatus

        h.suggestions.handleHotkey()
        await waitFor(capture.captureStarted)
        // Capture is still gated open — prewarm must already be underway.
        await waitFor(h.dictation.llmStatus != statusBefore, timeout: 2)
        XCTAssertFalse(capture.captureCompleted)
        XCTAssertNotEqual(h.dictation.llmStatus, statusBefore)

        capture.releaseCapture()                     // flow proceeds normally afterwards
        await waitFor(h.engine.streamStarted)
        h.engine.emit(#"["Run the tests"]"#)
        h.engine.finishStream()
        await waitFor(h.suggestions.session.phase == .presenting)
        XCTAssertEqual(h.suggestions.session.candidates, ["Run the tests"])
    }

    func testSecureFieldRefusalNeverStartsAStream() async {
        let engine = StreamingFakeEngine()
        let h = make(capture: FakeContextCapture(.fail(.secureField)), engine: engine)
        h.suggestions.handleHotkey()
        await waitFor({ if case .failed = h.suggestions.session.phase { return true }; return false }())
        XCTAssertEqual(h.suggestions.session.phase,
                       .failed("Not available here — a secure field is focused."))
        XCTAssertFalse(engine.streamStarted)         // no request ever reached the engine
        XCTAssertTrue(engine.requests.isEmpty)
        XCTAssertEqual(h.keystroke.count + h.paste.count, 0)
    }
}
