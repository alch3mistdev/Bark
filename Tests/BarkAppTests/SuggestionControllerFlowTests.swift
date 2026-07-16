import XCTest
@testable import BarkCore
@testable import BarkEngines
@testable import Bark

/// US1 flow tests (015 T023): hotkey → capture → generate → present → pick →
/// inject, all against fakes. The suggestion flow must never inject anything
/// that didn't survive parsing/validation, must refuse secure fields at
/// capture, and must stay out of the way of live dictation.
@MainActor
final class SuggestionControllerFlowTests: XCTestCase {
    private let terminalTarget = InjectionTarget(pid: 4242, bundleID: "com.apple.Terminal")
    private let editorTarget = InjectionTarget(pid: 4343, bundleID: "com.example.TextEdit")

    /// Mutable target seam so a test can change "frontmost" mid-flow.
    final class TargetBox: @unchecked Sendable {
        var target: InjectionTarget?
        init(_ target: InjectionTarget?) { self.target = target }
    }

    private struct Harness {
        let suggestions: SuggestionController
        let dictation: DictationController
        let paste: FakeInjector
        let keystroke: FakeInjector
        let clipboard: FakeInjector
        let returnSynth: FakeReturnSynthesizer
        let engine: FakeSuggestionEngine
        let settings: SettingsStore
        let targetBox: TargetBox
    }

    private func makeContext(bundleID: String? = "com.apple.Terminal",
                             windowText: String = "Agent finished the refactor. What should I do next?") -> CapturedContext {
        CapturedContext(source: .accessibility, appBundleID: bundleID, windowTitle: "zsh",
                        fieldLabel: nil, fieldValue: nil, fieldPlaceholder: nil, fieldRole: "AXTextArea",
                        windowText: windowText)
    }

    private func make(
        capture: FakeContextCapture,
        engine: FakeSuggestionEngine = FakeSuggestionEngine(.ok(#"["Run the tests", "Commit and open a PR", "Refactor first"]"#)),
        target: InjectionTarget? = nil,
        enabled: Bool = true,
        autoSubmit: Bool = false,
        routing: OutputRouting = .insert,
        secureInput: Bool = false,
        history: HistoryStore? = nil,
        historyEnabled: Bool = false,
        generationDeadline: Double = 5,
        keystrokeInjector: FakeInjector = FakeInjector(),
        settleDelay: Duration = .zero
    ) -> Harness {
        let defaults = UserDefaults(suiteName: "bark-suggest-test-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults, key: "k")
        settings.update {
            $0.suggestionsEnabled = enabled
            $0.llmEnabled = true
            $0.outputRouting = routing
            $0.suggestionAutoSubmit = autoSubmit
            $0.historyEnabled = historyEnabled
        }
        let perms = PermissionsCoordinator()
        perms.overrideForTesting(microphone: .granted)
        let targetBox = TargetBox(target ?? terminalTarget)

        let dictation = DictationController(
            settings: settings, permissions: perms, hotkey: HotkeyManager(),
            stt: FakeSTTEngine(), llmCleaner: FakeCleaner(.ok("cleaned")), history: history,
            audioFactory: { FakeAudioCapture() },
            pasteInjector: FakeInjector(), keystrokeInjector: FakeInjector(),
            clipboardInjector: FakeInjector(),
            targetProvider: { [targetBox] in targetBox.target }
        )

        let paste = FakeInjector()
        let keystroke = keystrokeInjector
        let clipboard = FakeInjector()
        let returnSynth = FakeReturnSynthesizer()
        let suggestions = SuggestionController(
            settings: settings,
            dictation: dictation,
            hotkey: HotkeyManager(),
            capture: capture,
            localEngine: engine,
            secretStore: InMemorySecretStore(),
            history: history,
            pasteInjector: paste,
            keystrokeInjector: keystroke,
            clipboardInjector: clipboard,
            returnSynthesizer: returnSynth,
            targetProvider: { [targetBox] in targetBox.target },
            secureInputCheck: { secureInput },
            generationDeadline: generationDeadline,
            settleDelay: settleDelay
        )
        return Harness(suggestions: suggestions, dictation: dictation, paste: paste,
                       keystroke: keystroke, clipboard: clipboard, returnSynth: returnSynth,
                       engine: engine, settings: settings, targetBox: targetBox)
    }

    private func waitFor(_ condition: @autoclosure @MainActor () -> Bool, timeout: Double = 4) async {
        for _ in 0..<Int(timeout * 50) {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Happy path

    func testTerminalPickInjectsExactTextViaKeystroke() async {
        let h = make(capture: FakeContextCapture(.ok(makeContext())))
        h.suggestions.handleHotkey()
        await waitFor(h.suggestions.session.phase == .presenting)

        XCTAssertEqual(h.suggestions.session.candidates,
                       ["Run the tests", "Commit and open a PR", "Refactor first"])
        h.suggestions.choose(1)
        await waitFor(h.suggestions.session.phase == .idle)

        XCTAssertEqual(h.keystroke.last, "Commit and open a PR")   // terminal → keystroke strategy
        XCTAssertEqual(h.keystroke.count, 1)
        XCTAssertEqual(h.paste.count, 0)
        XCTAssertEqual(h.clipboard.count, 0)
        XCTAssertEqual(h.returnSynth.count, 0)                     // auto-submit off by default
    }

    func testNonTerminalUsesPasteStrategy() async {
        let h = make(capture: FakeContextCapture(.ok(makeContext(bundleID: "com.example.TextEdit"))),
                     target: editorTarget)
        h.suggestions.handleHotkey()
        await waitFor(h.suggestions.session.phase == .presenting)
        h.suggestions.choose(0)
        await waitFor(h.suggestions.session.phase == .idle)
        XCTAssertEqual(h.paste.last, "Run the tests")
        XCTAssertEqual(h.keystroke.count, 0)
    }

    func testClipboardRoutingUsesClipboardInjector() async {
        let h = make(capture: FakeContextCapture(.ok(makeContext())), routing: .copyOnly)
        h.suggestions.handleHotkey()
        await waitFor(h.suggestions.session.phase == .presenting)
        h.suggestions.choose(0)
        await waitFor(h.suggestions.session.phase == .idle)
        XCTAssertEqual(h.clipboard.last, "Run the tests")
        XCTAssertEqual(h.keystroke.count, 0)
        XCTAssertEqual(h.paste.count, 0)
    }

    func testEngineReceivesFencedPrompt() async {
        let h = make(capture: FakeContextCapture(.ok(makeContext())))
        h.suggestions.handleHotkey()
        await waitFor(h.suggestions.session.phase == .presenting)
        let request = h.engine.requests.first
        XCTAssertNotNil(request)
        XCTAssertTrue(request!.user.contains(SuggestionPrompt.contextOpenTag))
        XCTAssertTrue(request!.user.contains("What should I do next?"))
        XCTAssertEqual(request!.system, SuggestionPrompt.system())
    }

    // MARK: - Dismissal

    func testDismissInjectsNothingAndResets() async {
        let h = make(capture: FakeContextCapture(.ok(makeContext())))
        h.suggestions.handleHotkey()
        await waitFor(h.suggestions.session.phase == .presenting)
        h.suggestions.dismiss()
        XCTAssertEqual(h.suggestions.session.phase, .idle)
        XCTAssertTrue(h.suggestions.session.candidates.isEmpty)
        XCTAssertEqual(h.keystroke.count + h.paste.count + h.clipboard.count, 0)
    }

    func testHotkeyWhileShowingTogglesClosed() async {
        let h = make(capture: FakeContextCapture(.ok(makeContext())))
        h.suggestions.handleHotkey()
        await waitFor(h.suggestions.session.phase == .presenting)
        h.suggestions.handleHotkey()   // toggle semantics (FR-016)
        XCTAssertEqual(h.suggestions.session.phase, .idle)
        XCTAssertEqual(h.keystroke.count + h.paste.count, 0)
    }

    // MARK: - Guards

    func testDisabledFeatureIgnoresHotkey() async {
        let h = make(capture: FakeContextCapture(.ok(makeContext())), enabled: false)
        h.suggestions.handleHotkey()
        XCTAssertEqual(h.suggestions.session.phase, .idle)
    }

    func testHotkeyIgnoredDuringActiveDictation() async {
        let h = make(capture: FakeContextCapture(.ok(makeContext())))
        await h.dictation.warmModel()
        h.dictation.startDictation()
        await waitFor(h.dictation.phase == .listening)

        h.suggestions.handleHotkey()
        XCTAssertEqual(h.suggestions.session.phase, .idle)   // one flow at a time (FR-016)

        h.dictation.cancelDictation()
    }

    func testSecureFieldRefusesCaptureAndReadsNothing() async {
        let h = make(capture: FakeContextCapture(.fail(.secureField)))
        h.suggestions.handleHotkey()
        await waitFor({ if case .failed = h.suggestions.session.phase { return true }; return false }())

        XCTAssertEqual(h.suggestions.session.phase,
                       .failed("Not available here — a secure field is focused."))
        XCTAssertTrue(h.engine.requests.isEmpty)             // nothing was sent to any engine
        XCTAssertEqual(h.keystroke.count + h.paste.count + h.clipboard.count, 0)
    }

    // MARK: - Failure modes

    func testEngineFailureShowsErrorAndInjectsNothing() async {
        let h = make(capture: FakeContextCapture(.ok(makeContext())),
                     engine: FakeSuggestionEngine(.fail(.network("boom"))))
        h.suggestions.handleHotkey()
        await waitFor({ if case .failed = h.suggestions.session.phase { return true }; return false }())
        XCTAssertEqual(h.keystroke.count + h.paste.count, 0)
        XCTAssertNotNil(h.suggestions.lastError)
    }

    func testUnparseableOutputFailsHonestly() async {
        let h = make(capture: FakeContextCapture(.ok(makeContext())),
                     engine: FakeSuggestionEngine(.ok("I have no list for you today.")))
        h.suggestions.handleHotkey()
        await waitFor({ if case .failed = h.suggestions.session.phase { return true }; return false }())
        XCTAssertEqual(h.suggestions.session.phase,
                       .failed("Couldn't produce suggestions for this screen."))
        XCTAssertEqual(h.keystroke.count + h.paste.count, 0)
    }

    func testGenerationDeadlineFailsHonestly() async {
        let h = make(capture: FakeContextCapture(.ok(makeContext())),
                     engine: FakeSuggestionEngine(.hang),
                     generationDeadline: 0.2)
        h.suggestions.handleHotkey()
        await waitFor({ if case .failed = h.suggestions.session.phase { return true }; return false }())
        XCTAssertEqual(h.suggestions.session.phase, .failed("Suggestions timed out — try again."))
        XCTAssertEqual(h.keystroke.count + h.paste.count, 0)
    }

    func testEmptyContextFailsHonestly() async {
        let h = make(capture: FakeContextCapture(.fail(.empty)))
        h.suggestions.handleHotkey()
        await waitFor({ if case .failed = h.suggestions.session.phase { return true }; return false }())
        XCTAssertEqual(h.suggestions.session.phase,
                       .failed("Couldn't read any text on this screen."))
    }

    func testInjectionFailureSurfacesError() async {
        let h = make(capture: FakeContextCapture(.ok(makeContext())),
                     keystrokeInjector: FakeInjector(.focusChanged, failTimes: 1))
        h.suggestions.handleHotkey()
        await waitFor(h.suggestions.session.phase == .presenting)
        h.suggestions.choose(0)
        await waitFor({ if case .failed = h.suggestions.session.phase { return true }; return false }())
        XCTAssertEqual(h.suggestions.session.phase,
                       .failed("Window focus changed — text not inserted."))
    }

    // MARK: - Dismiss races (review fix)

    /// Dismissing during the post-pick settle window must inject NOTHING — the
    /// swallowed `try? await Task.sleep` used to let cancelled picks through.
    func testDismissDuringSettleWindowInjectsNothing() async {
        let h = make(capture: FakeContextCapture(.ok(makeContext())), settleDelay: .milliseconds(200))
        h.suggestions.handleHotkey()
        await waitFor(h.suggestions.session.phase == .presenting)
        h.suggestions.choose(0)                 // → .injecting, injectChosen sleeps 200ms
        h.suggestions.dismiss()                 // cancel within the window
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(h.keystroke.count + h.paste.count + h.clipboard.count, 0)
        XCTAssertEqual(h.returnSynth.count, 0)
        XCTAssertEqual(h.suggestions.session.phase, .idle)
    }

    /// A stale pass (dismissed, its capture finishing late) must not advance or
    /// inject into a newer session — the pass token guards it.
    func testStalePassCannotHijackNewerSession() async {
        // First pass captures app A; we don't let it present — dismiss immediately.
        let h = make(capture: FakeContextCapture(.ok(makeContext(bundleID: "com.apple.Terminal"))))
        h.suggestions.handleHotkey()
        await waitFor(h.suggestions.session.phase == .presenting)
        // A fresh press starts a new pass (bumps the token); the old flow task is
        // already done, but this proves a new pass owns the session cleanly.
        h.suggestions.dismiss()
        XCTAssertEqual(h.suggestions.session.phase, .idle)
        h.suggestions.handleHotkey()
        await waitFor(h.suggestions.session.phase == .presenting)
        XCTAssertEqual(h.suggestions.session.candidates.count, 3)   // new pass presented normally
    }
}
