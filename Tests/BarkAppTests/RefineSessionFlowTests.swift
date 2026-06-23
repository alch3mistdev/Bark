import XCTest
@testable import BarkCore
@testable import BarkEngines
@testable import Bark

/// End-to-end hold-to-refine flow (012), driven with the scripted multi-segment
/// STT + continuous audio + scripted refine cleaner. The `Scripted*` fakes live
/// in Fakes.swift.
///
/// Segment-index model: each left-option boundary cuts a segment, so the STT
/// `segments` list is consumed in order — base, [instruction | between-dictation]…,
/// tail. A `.start` first closes a dictation segment (often empty between turns).
@MainActor
final class RefineSessionFlowTests: XCTestCase {
    private func make(
        segments: [String],
        refine: @escaping @Sendable (String, String) -> String = { _, instr in "[\(instr)]" },
        injector: FakeInjector = FakeInjector(),
        llmPresent: Bool = true,
        llmEnabled: Bool = true,
        holdToRefine: Bool = true,
        mode: String = "clean",
        deadline: Double = 1.0
    ) -> DictationController {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "refine-\(UUID().uuidString)")!, key: "k")
        settings.update {
            $0.selectedModeID = mode
            $0.llmEnabled = llmEnabled
            $0.holdToRefineEnabled = holdToRefine
        }
        let perms = PermissionsCoordinator()
        perms.overrideForTesting(microphone: .granted)
        let cleaner: TextCleaner? = llmPresent ? ScriptedRefineCleaner(refine) : nil
        return DictationController(
            settings: settings, permissions: perms, hotkey: HotkeyManager(),
            stt: ScriptedSTTEngine(segments: segments), llmCleaner: cleaner, history: nil,
            audioFactory: { ContinuousAudioCapture() },
            pasteInjector: injector, keystrokeInjector: injector, clipboardInjector: FakeInjector(),
            cleanupDeadline: deadline,
            targetProvider: { InjectionTarget(pid: 7, bundleID: "com.example.app") }
        )
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(70)) }

    private func waitFor(_ p: @escaping () -> Bool) async -> Bool {
        for _ in 0..<300 { if p() { return true }; try? await Task.sleep(for: .milliseconds(15)) }
        return false
    }

    private func waitTerminal(_ c: DictationController) async {
        _ = await waitFor { switch c.phase { case .idle, .completed, .failed: return true; default: return false } }
    }

    // US1 — single refinement before injection (spec example 2)
    func testSingleRefinementInjectsRefinedDraft() async {
        let injector = FakeInjector()
        let c = make(segments: ["hello my name is foo", "make it sound very happy", ""], injector: injector)
        await c.warmModel()
        c.startDictation();           await settle()
        c.beginRefineGesture();       await settle()   // close base, capture instruction
        c.endRefineGesture();         await settle()   // apply refine
        c.stopDictation()
        _ = await waitFor { injector.count >= 1 }
        await waitTerminal(c)
        XCTAssertEqual(injector.last, "[make it sound very happy]")
        XCTAssertEqual(injector.count, 1)              // only the final draft injected
    }

    // US2 — chained refinements; only the final draft injects (spec example 3)
    func testChainedRefinementsInjectOnlyFinalDraft() async {
        let injector = FakeInjector()
        // base, instr1, (empty between), instr2, tail
        let c = make(
            segments: ["hello my name is foo", "change name to bar", "", "make a longer introduction", ""],
            refine: { _, instr in instr.uppercased() },   // each turn replaces with the instruction, uppercased
            injector: injector)
        await c.warmModel()
        c.startDictation();           await settle()
        c.beginRefineGesture();       await settle()
        c.endRefineGesture();         await settle()      // refine1 → "CHANGE NAME TO BAR"
        c.beginRefineGesture();       await settle()
        c.endRefineGesture();         await settle()      // refine2 → "MAKE A LONGER INTRODUCTION"
        c.stopDictation()
        _ = await waitFor { injector.count >= 1 }
        await waitTerminal(c)
        XCTAssertEqual(injector.last, "MAKE A LONGER INTRODUCTION")
        XCTAssertEqual(injector.count, 1)                 // intermediate draft never injected (SC-005)
    }

    // US2 / SC-008 — repeatable empty-tap undo back to the base draft
    func testEmptyTapUndoRevertsRefinement() async {
        let injector = FakeInjector()
        // base, instr1, then two empty turns (between="", instruction="") to undo
        let c = make(segments: ["hello my name is foo", "change name to bar", "", "", ""],
                     refine: { _, instr in instr.uppercased() }, injector: injector)
        await c.warmModel()
        c.startDictation();           await settle()
        c.beginRefineGesture();       await settle()
        c.endRefineGesture();         await settle()      // refine1 → draft "CHANGE NAME TO BAR"
        c.beginRefineGesture();       await settle()
        c.endRefineGesture();         await settle()      // empty instruction → undo → back to base
        c.stopDictation()
        _ = await waitFor { injector.count >= 1 }
        await waitTerminal(c)
        XCTAssertEqual(injector.last, "Hello my name is foo")   // base (clean mode) restored
    }

    // US3 — dictation between refinements is appended to the draft
    func testDictationBetweenRefinementsIsAppended() async {
        let injector = FakeInjector()
        // base, instr1, BETWEEN dictation, instr2, tail — raw mode keeps text verbatim
        let c = make(
            segments: ["first point", "make a bullet", "second point", "tighten", ""],
            refine: { draft, instr in draft + "|" + instr },   // keep the draft so we can see the append
            injector: injector, mode: "raw")
        await c.warmModel()
        c.startDictation();           await settle()
        c.beginRefineGesture();       await settle()
        c.endRefineGesture();         await settle()      // refine1: "first point|make a bullet"
        c.beginRefineGesture();       await settle()      // closes the BETWEEN segment ("second point") → appended
        c.endRefineGesture();         await settle()      // refine2 sees the appended text
        c.stopDictation()
        _ = await waitFor { injector.count >= 1 }
        await waitTerminal(c)
        let out = injector.last ?? ""
        XCTAssertTrue(out.contains("second point"), "between-refinement dictation must be appended: \(out)")
        XCTAssertTrue(out.contains("make a bullet") && out.contains("tighten"), out)
    }

    // US4 — HUD-facing refine activity transitions
    func testRefineActivityTransitions() async {
        let c = make(segments: ["hello my name is foo", "happier", ""])
        await c.warmModel()
        XCTAssertEqual(c.refineActivity, .none)
        c.startDictation();           await settle()
        XCTAssertEqual(c.refineActivity, .dictating)
        c.beginRefineGesture();       await settle()
        XCTAssertEqual(c.refineActivity, .capturingInstruction)
        XCTAssertEqual(c.currentDraft, "Hello my name is foo")   // base seeded + visible in HUD
        c.endRefineGesture();         await settle()
        XCTAssertEqual(c.refineActivity, .dictating)             // back to dictation after the turn
        c.stopDictation()
        await waitTerminal(c)
        XCTAssertEqual(c.refineActivity, .none)
    }

    // US5 — no LLM engine: left-option ignored, base injects as today, hint shown
    func testNoLLMIgnoresGestureAndInjectsBase() async {
        let injector = FakeInjector()
        let c = make(segments: ["hello my name is foo"], injector: injector, llmPresent: false)
        await c.warmModel()
        c.startDictation();           await settle()
        c.beginRefineGesture();       await settle()      // ignored (no LLM)
        c.endRefineGesture();         await settle()
        c.stopDictation()
        _ = await waitFor { injector.count >= 1 }
        await waitTerminal(c)
        XCTAssertEqual(injector.last, "Hello my name is foo")   // base, unrefined
        XCTAssertNotNil(c.refineHint)                            // one-time hint surfaced
    }

    // US5 — toggle off: gesture ignored even with an LLM present
    func testToggleOffIgnoresGesture() async {
        let injector = FakeInjector()
        let c = make(segments: ["hello my name is foo"], injector: injector, holdToRefine: false)
        await c.warmModel()
        c.startDictation();           await settle()
        c.beginRefineGesture();       await settle()
        c.endRefineGesture();         await settle()
        c.stopDictation()
        _ = await waitFor { injector.count >= 1 }
        await waitTerminal(c)
        XCTAssertEqual(injector.last, "Hello my name is foo")
        XCTAssertEqual(injector.count, 1)
    }

    // US6 — a secure field focused at fn-release refuses; nothing injected
    func testSecureFieldRefusalDuringRefineSession() async {
        let injector = FakeInjector(.secure, failTimes: .max)
        let c = make(segments: ["hello my name is foo", "make it happy", ""], injector: injector)
        await c.warmModel()
        c.startDictation();           await settle()
        c.beginRefineGesture();       await settle()
        c.endRefineGesture();         await settle()
        c.stopDictation()
        await waitTerminal(c)
        XCTAssertEqual(injector.count, 0)
        if case .failed = c.phase {} else { XCTFail("expected .failed, got \(c.phase)") }
        XCTAssertNotNil(c.lastError)
    }

    // FR-015 — hands-free ignores the left-option gesture (push-to-talk only)
    func testHandsFreeIgnoresRefineGesture() async {
        let injector = FakeInjector()
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "hf-\(UUID().uuidString)")!, key: "k")
        settings.update { $0.selectedModeID = "clean"; $0.llmEnabled = true }
        let perms = PermissionsCoordinator(); perms.overrideForTesting(microphone: .granted)
        let c = DictationController(
            settings: settings, permissions: perms, hotkey: HotkeyManager(),
            stt: FakeSTTEngine(finalText: "hello world"), handsFreeHotkey: HotkeyManager(),
            llmCleaner: ScriptedRefineCleaner({ _, i in "[\(i)]" }), history: nil,
            audioFactory: { ScriptedAudioCapture(rmsLevels: [Float](repeating: 0.3, count: 3) + [Float](repeating: 0, count: 10)) },
            pasteInjector: injector, keystrokeInjector: injector,
            targetProvider: { InjectionTarget(pid: 1, bundleID: "com.example.app") })
        await c.warmModel()
        c.startHandsFree()
        c.beginRefineGesture()        // must be ignored during hands-free
        c.endRefineGesture()
        XCTAssertEqual(c.currentDraft, "")            // no refine session started
        XCTAssertEqual(c.refineActivity, .none)
        let injected = await waitFor { injector.count >= 1 }
        XCTAssertTrue(injected)
        XCTAssertEqual(injector.last, "Hello world")  // normal hands-free injection, unrefined
        c.stopHandsFree()
    }
}
