import XCTest
@testable import BarkCore
@testable import BarkEngines
@testable import Bark

/// US2 flow tests (015 T031/T035): "Other…" runs ONE hands-free utterance and
/// stops; auto-submit posts Return only in the single approved case — never on
/// the dictation path, secure input, focus drift, clipboard routing, or with
/// the setting off (ADR-010 / FR-011 / FR-012).
@MainActor
final class SuggestionOtherAndAutoSubmitTests: XCTestCase {
    private let terminalTarget = InjectionTarget(pid: 4242, bundleID: "com.apple.Terminal")

    /// Speech then silence — one complete hands-free utterance for the VAD.
    private let oneUtterance = [Float](repeating: 0.3, count: 20) + [Float](repeating: 0, count: 12)

    final class TargetBox: @unchecked Sendable {
        var target: InjectionTarget?
        init(_ target: InjectionTarget?) { self.target = target }
    }

    final class SecureFlag: @unchecked Sendable {
        var active = false
    }

    private struct Harness {
        let suggestions: SuggestionController
        let dictation: DictationController
        let dictationInjector: FakeInjector
        let suggestionInjector: FakeInjector
        let returnSynth: FakeReturnSynthesizer
        let targetBox: TargetBox
        let secureFlag: SecureFlag
    }

    private func makeContext() -> CapturedContext {
        CapturedContext(source: .accessibility, appBundleID: "com.apple.Terminal", windowTitle: "zsh",
                        fieldLabel: nil, fieldValue: nil, fieldPlaceholder: nil, fieldRole: "AXTextArea",
                        windowText: "Agent finished. What next?")
    }

    private func make(
        autoSubmit: Bool = false,
        routing: OutputRouting = .insert,
        micGranted: Bool = true,
        raw: String = #"["Run the tests", "Ship it"]"#
    ) async -> Harness {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "sug-us2-\(UUID().uuidString)")!, key: "k")
        settings.update {
            $0.suggestionsEnabled = true
            $0.llmEnabled = true
            $0.outputRouting = routing
            $0.suggestionAutoSubmit = autoSubmit
        }
        let perms = PermissionsCoordinator()
        perms.overrideForTesting(microphone: micGranted ? .granted : .denied)
        let targetBox = TargetBox(terminalTarget)
        let secureFlag = SecureFlag()

        let dictationInjector = FakeInjector()
        let script = oneUtterance
        let dictation = DictationController(
            settings: settings, permissions: perms, hotkey: HotkeyManager(),
            stt: FakeSTTEngine(finalText: "my custom reply"), handsFreeHotkey: HotkeyManager(),
            llmCleaner: nil, history: nil,
            audioFactory: { ScriptedAudioCapture(rmsLevels: script) },
            pasteInjector: dictationInjector, keystrokeInjector: dictationInjector,
            clipboardInjector: dictationInjector,
            targetProvider: { [targetBox] in targetBox.target }
        )
        await dictation.warmModel()

        let suggestionInjector = FakeInjector()
        let returnSynth = FakeReturnSynthesizer()
        let suggestions = SuggestionController(
            settings: settings, dictation: dictation, hotkey: HotkeyManager(),
            capture: FakeContextCapture(.ok(makeContext())),
            localEngine: FakeSuggestionEngine(.ok(raw)),
            secretStore: InMemorySecretStore(),
            pasteInjector: suggestionInjector, keystrokeInjector: suggestionInjector,
            clipboardInjector: suggestionInjector, returnSynthesizer: returnSynth,
            targetProvider: { [targetBox] in targetBox.target },
            secureInputCheck: { [secureFlag] in secureFlag.active },
            generationDeadline: 5, settleDelay: .zero
        )
        // The BarkApp multiplex, reproduced for tests (T032).
        dictation.onPhaseChange = { [weak suggestions] phase in
            suggestions?.notifyDictationPhase(phase)
        }
        return Harness(suggestions: suggestions, dictation: dictation,
                       dictationInjector: dictationInjector, suggestionInjector: suggestionInjector,
                       returnSynth: returnSynth, targetBox: targetBox, secureFlag: secureFlag)
    }

    private func waitFor(_ condition: @autoclosure @MainActor () -> Bool, timeout: Double = 5) async {
        for _ in 0..<Int(timeout * 50) {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - "Other…" one-shot (T031)

    func testOtherRunsOneUtteranceThenStops() async {
        let h = await make()
        h.suggestions.handleHotkey()
        await waitFor(h.suggestions.session.phase == .presenting)

        h.suggestions.chooseOther()
        XCTAssertEqual(h.suggestions.session.phase, .dictating)
        XCTAssertTrue(h.dictation.handsFreeActive)

        // The scripted utterance completes → injected via the DICTATION pipeline,
        // then the one-shot multiplex stops hands-free and ends the session.
        await waitFor(h.dictationInjector.count >= 1)
        XCTAssertEqual(h.dictationInjector.last, "My custom reply")   // clean mode capitalizes
        await waitFor(h.suggestions.session.phase == .idle)
        XCTAssertFalse(h.dictation.handsFreeActive)                   // stopped after ONE utterance
        XCTAssertEqual(h.suggestionInjector.count, 0)                 // suggestion injectors untouched
        XCTAssertEqual(h.returnSynth.count, 0)                        // never auto-submits dictated replies
    }

    func testOtherWithDeniedMicEndsSessionImmediately() async {
        let h = await make(micGranted: false)
        h.suggestions.handleHotkey()
        await waitFor(h.suggestions.session.phase == .presenting)

        h.suggestions.chooseOther()
        await waitFor(h.suggestions.session.phase == .idle)
        XCTAssertFalse(h.dictation.handsFreeActive)
        XCTAssertEqual(h.dictationInjector.count, 0)
    }

    func testDismissDuringOtherStopsHandsFree() async {
        let h = await make()
        h.suggestions.handleHotkey()
        await waitFor(h.suggestions.session.phase == .presenting)
        h.suggestions.chooseOther()
        XCTAssertTrue(h.dictation.handsFreeActive)

        h.suggestions.dismiss()
        XCTAssertEqual(h.suggestions.session.phase, .idle)
        XCTAssertFalse(h.dictation.handsFreeActive)
    }

    // MARK: - Auto-submit (T033/T035)

    func testAutoSubmitPostsReturnAfterPickedSuggestion() async {
        let h = await make(autoSubmit: true)
        h.suggestions.handleHotkey()
        await waitFor(h.suggestions.session.phase == .presenting)
        h.suggestions.choose(0)
        await waitFor(h.suggestions.session.phase == .idle)

        XCTAssertEqual(h.suggestionInjector.last, "Run the tests")
        XCTAssertEqual(h.returnSynth.count, 1)
        XCTAssertEqual(h.returnSynth.lastPlan?.target, terminalTarget)   // terminals deliberately allowed
    }

    func testAutoSubmitOffByDefaultNeverFires() async {
        let h = await make(autoSubmit: false)
        h.suggestions.handleHotkey()
        await waitFor(h.suggestions.session.phase == .presenting)
        h.suggestions.choose(0)
        await waitFor(h.suggestions.session.phase == .idle)
        XCTAssertEqual(h.returnSynth.count, 0)
    }

    func testAutoSubmitRefusedWhenSecureInputActive() async {
        let h = await make(autoSubmit: true)
        h.suggestions.handleHotkey()
        await waitFor(h.suggestions.session.phase == .presenting)
        h.secureFlag.active = true   // secure input appears between pick and submit
        h.suggestions.choose(0)
        await waitFor(h.suggestions.session.phase == .idle)
        XCTAssertEqual(h.suggestionInjector.count, 1)   // insertion itself already happened
        XCTAssertEqual(h.returnSynth.count, 0)          // Return refused
    }

    func testAutoSubmitRefusedWhenFocusChanged() async {
        let h = await make(autoSubmit: true)
        h.suggestions.handleHotkey()
        await waitFor(h.suggestions.session.phase == .presenting)
        h.targetBox.target = InjectionTarget(pid: 9999, bundleID: "com.other.App")
        h.suggestions.choose(0)
        await waitFor(h.suggestions.session.phase == .idle)
        XCTAssertEqual(h.returnSynth.count, 0)
    }

    func testAutoSubmitRefusedOnClipboardRouting() async {
        let h = await make(autoSubmit: true, routing: .copyOnly)
        h.suggestions.handleHotkey()
        await waitFor(h.suggestions.session.phase == .presenting)
        h.suggestions.choose(0)
        await waitFor(h.suggestions.session.phase == .idle)
        XCTAssertEqual(h.suggestionInjector.count, 1)   // clipboard injector got the text
        XCTAssertEqual(h.returnSynth.count, 0)          // nothing was typed → nothing to submit
    }
}
