import XCTest
@testable import BarkCore
@testable import BarkEngines
@testable import Bark

@MainActor
final class DictationControllerTests: XCTestCase {
    private let target = InjectionTarget(pid: 4242, bundleID: "com.example.TextEdit")

    private func make(
        stt: FakeSTTEngine = FakeSTTEngine(),
        cleaner: FakeCleaner = FakeCleaner(.ok("UNUSED")),
        injector: FakeInjector = FakeInjector(),
        mode: String = "clean",
        llmEnabled: Bool = true,
        deadline: Double = 0.3
    ) -> DictationController {
        let defaults = UserDefaults(suiteName: "bark-test-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults, key: "k")
        settings.update { $0.selectedModeID = mode; $0.llmEnabled = llmEnabled }
        let perms = PermissionsCoordinator()
        perms.overrideForTesting(microphone: .granted)
        return DictationController(
            settings: settings, permissions: perms, hotkey: HotkeyManager(),
            stt: stt, llmCleaner: cleaner, history: nil,
            audioFactory: { FakeAudioCapture() },
            pasteInjector: injector, keystrokeInjector: injector,
            cleanupDeadline: deadline, targetProvider: { [target] in target }
        )
    }

    /// Drives a full dictation and waits for a terminal phase.
    private func dictate(_ c: DictationController) async {
        await c.warmModel()
        c.startDictation()
        try? await Task.sleep(for: .milliseconds(80))  // let beginPipeline wire up
        c.stopDictation()
        await waitForTerminal(c)
    }

    private func waitForTerminal(_ c: DictationController) async {
        for _ in 0..<200 { // up to ~4s
            switch c.phase {
            case .idle, .completed, .failed: return
            default: try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    func testRawHappyPathInjectsCleanedText() async {
        let injector = FakeInjector()
        let c = make(stt: FakeSTTEngine(finalText: "hello world"), injector: injector, mode: "clean")
        await dictate(c)
        XCTAssertEqual(injector.last, "Hello world") // deterministic cleaner capitalised
        XCTAssertEqual(c.phase, .idle)  // controller resets to idle after a successful insert
    }

    func testLLMModeUsesCleanerOutput() async {
        let injector = FakeInjector()
        let c = make(cleaner: FakeCleaner(.ok("Rewritten email body.")), injector: injector, mode: "email")
        await dictate(c)
        XCTAssertEqual(injector.last, "Rewritten email body.")
        XCTAssertEqual(c.phase, .idle)  // controller resets to idle after a successful insert
    }

    func testLLMFailureFallsBackToDeterministic() async {
        let injector = FakeInjector()
        let c = make(stt: FakeSTTEngine(finalText: "hello world"),
                     cleaner: FakeCleaner(.fail), injector: injector, mode: "email")
        await dictate(c)
        XCTAssertEqual(injector.last, "Hello world") // fell back to basic cleaner
        XCTAssertEqual(c.phase, .idle)  // controller resets to idle after a successful insert
    }

    func testLLMTimeoutFallsBackToDeterministic() async {
        let injector = FakeInjector()
        let c = make(stt: FakeSTTEngine(finalText: "hello world"),
                     cleaner: FakeCleaner(.hang), injector: injector, mode: "email", deadline: 0.2)
        await dictate(c)
        XCTAssertEqual(injector.last, "Hello world")
        XCTAssertEqual(c.phase, .idle)  // controller resets to idle after a successful insert
    }

    func testSecureFieldRefusalDoesNotInject() async {
        let injector = FakeInjector(.secure, failTimes: .max)
        let c = make(injector: injector, mode: "clean")
        await dictate(c)
        XCTAssertNil(injector.last)
        XCTAssertEqual(injector.count, 0)
        if case .failed = c.phase {} else { XCTFail("expected .failed, got \(c.phase)") }
        XCTAssertNotNil(c.lastError)
    }

    func testEmptyTranscriptInjectsNothing() async {
        let injector = FakeInjector()
        let c = make(stt: FakeSTTEngine(finalText: ""), injector: injector, mode: "clean")
        await dictate(c)
        XCTAssertEqual(injector.count, 0)
        XCTAssertEqual(c.phase, .idle) // reset
    }

    func testRestartAfterFailureSucceeds() async {
        // First injection fails (secure); the next must still work — proves the
        // failed-state reset path (ADV-005 / Codex).
        let injector = FakeInjector(.secure, failTimes: 1)
        let c = make(stt: FakeSTTEngine(finalText: "hello world"), injector: injector, mode: "clean")
        await dictate(c) // fails
        if case .failed = c.phase {} else { XCTFail("expected first run to fail") }
        await dictate(c) // restart
        XCTAssertEqual(injector.last, "Hello world")
        XCTAssertEqual(c.phase, .idle)  // controller resets to idle after a successful insert
    }
}
