import XCTest
@testable import BarkCore
@testable import BarkEngines
@testable import Bark

@MainActor
final class LLMStatusTests: XCTestCase {
    private func makeController(_ cleaner: TextCleaner?) -> DictationController {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "bark-llm-\(UUID().uuidString)")!, key: "k")
        let perms = PermissionsCoordinator()
        perms.overrideForTesting(microphone: .granted)
        return DictationController(
            settings: settings, permissions: perms, hotkey: HotkeyManager(),
            stt: FakeSTTEngine(), llmCleaner: cleaner, history: nil,
            audioFactory: { FakeAudioCapture() },
            pasteInjector: FakeInjector(), keystrokeInjector: FakeInjector(),
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
}
