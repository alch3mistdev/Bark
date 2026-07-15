import XCTest
@testable import BarkCore
@testable import BarkEngines
@testable import Bark

@MainActor
final class LLMStatusTests: XCTestCase {
    private func makeController(_ cleaner: TextCleaner?, idleUnloadAfter: Double = 15 * 60) -> DictationController {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "bark-llm-\(UUID().uuidString)")!, key: "k")
        let perms = PermissionsCoordinator()
        perms.overrideForTesting(microphone: .granted)
        return DictationController(
            settings: settings, permissions: perms, hotkey: HotkeyManager(),
            stt: FakeSTTEngine(), llmCleaner: cleaner, history: nil,
            audioFactory: { FakeAudioCapture() },
            pasteInjector: FakeInjector(), keystrokeInjector: FakeInjector(),
            llmIdleUnloadAfter: idleUnloadAfter,
            targetProvider: { InjectionTarget(pid: 1, bundleID: "x") }
        )
    }

    private func wait(_ c: DictationController, until predicate: @escaping (LLMStatus) -> Bool) async -> Bool {
        for _ in 0..<200 {
            if predicate(c.llmStatus) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    func testEngineAbsentIsUnavailable() {
        let c = makeController(nil)
        XCTAssertEqual(c.llmStatus, .unavailable)
        XCTAssertFalse(c.llmEnginePresent)
    }

    func testEnginePresentStartsNotLoaded() {
        let c = makeController(FakePreparingCleaner(.succeed))
        XCTAssertEqual(c.llmStatus, .notLoaded)
        XCTAssertTrue(c.llmEnginePresent)
    }

    func testEnableReachesReady() async {
        let c = makeController(FakePreparingCleaner(.succeed))
        c.llmEnabled = true
        let ready = await wait(c) { $0 == .ready }
        XCTAssertTrue(ready)
    }

    func testFailedDownloadSurfacesFailure() async {
        let c = makeController(FakePreparingCleaner(.fail))
        c.llmEnabled = true
        let failed = await wait(c) { if case .failed = $0 { return true } else { return false } }
        XCTAssertTrue(failed)
    }

    func testDisableMidDownloadCancelsAndDoesNotBecomeReady() async {
        let c = makeController(FakePreparingCleaner(.succeed))
        c.llmEnabled = true
        let downloading = await wait(c) { if case .downloading = $0 { return true } else { return false } }
        XCTAssertTrue(downloading)
        c.llmEnabled = false
        XCTAssertEqual(c.llmStatus, .notLoaded)
        // Must not flip to .ready after being cancelled.
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(c.llmStatus, .notLoaded)
    }

    // PR4 — lifecycle: off means "not resident", idle expires, re-prepare works.

    func testDisableUnloadsLoadedModel() async {
        let cleaner = FakePreparingCleaner(.succeed)
        let c = makeController(cleaner)
        c.llmEnabled = true
        let ready = await wait(c) { $0 == .ready }
        XCTAssertTrue(ready)

        c.llmEnabled = false
        XCTAssertEqual(c.llmStatus, .notLoaded)
        for _ in 0..<200 where cleaner.unloadCount == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(cleaner.unloadCount, 1)
        let available = await cleaner.isAvailable
        XCTAssertFalse(available)   // model actually released, not just status flipped
    }

    func testIdleTTLUnloadsAndCanReprepare() async {
        let cleaner = FakePreparingCleaner(.succeed)
        let c = makeController(cleaner, idleUnloadAfter: 0.15)
        c.llmEnabled = true
        let ready = await wait(c) { $0 == .ready }
        XCTAssertTrue(ready)

        // TTL fires: status returns to .notLoaded and the model is released.
        let expired = await wait(c) { $0 == .notLoaded }
        XCTAssertTrue(expired)
        for _ in 0..<200 where cleaner.unloadCount == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThanOrEqual(cleaner.unloadCount, 1)

        // Re-prepare from .notLoaded works (status and availability in sync).
        c.prepareLLM()
        let readyAgain = await wait(c) { $0 == .ready }
        XCTAssertTrue(readyAgain)
        let available = await cleaner.isAvailable
        XCTAssertTrue(available)
    }

    func testDictationStartWarmsModel() async {
        let cleaner = FakePreparingCleaner(.succeed)
        let c = makeController(cleaner)
        // Enable via settings directly so the setter's prepareLLM doesn't mask the
        // warm-at-start path; select an LLM mode.
        c.settings.update { $0.llmEnabled = true; $0.selectedModeID = "email" }
        XCTAssertEqual(c.llmStatus, .notLoaded)

        await c.warmModel()
        c.startDictation()
        let ready = await wait(c) { $0 == .ready }
        XCTAssertTrue(ready)   // load kicked off by dictation start, not first cleanup
        c.cancelDictation()
    }
}
