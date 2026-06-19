import XCTest
@testable import BarkCore
@testable import BarkEngines
@testable import Bark

@MainActor
final class HandsFreeTests: XCTestCase {
    private func make(
        audio: @escaping @Sendable () -> AudioCapturing,
        injector: FakeInjector,
        stt: FakeSTTEngine = FakeSTTEngine(finalText: "hello world")
    ) -> DictationController {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "hf-\(UUID().uuidString)")!, key: "k")
        settings.update { $0.selectedModeID = "clean" }
        let perms = PermissionsCoordinator()
        perms.overrideForTesting(microphone: .granted)
        return DictationController(
            settings: settings, permissions: perms, hotkey: HotkeyManager(),
            stt: stt, handsFreeHotkey: HotkeyManager(),
            llmCleaner: nil, history: nil, audioFactory: audio,
            pasteInjector: injector, keystrokeInjector: injector,
            targetProvider: { InjectionTarget(pid: 1, bundleID: "com.example.app") }
        )
    }

    private func wait(_ predicate: @escaping () -> Bool) async -> Bool {
        for _ in 0..<200 { if predicate() { return true }; try? await Task.sleep(for: .milliseconds(20)) }
        return false
    }

    func testHandsFreeCapturesUtteranceAndInjects() async {
        let injector = FakeInjector()
        // 3 loud frames (onset) + 10 silent frames (end after hangover).
        let script = [Float](repeating: 0.3, count: 3) + [Float](repeating: 0, count: 10)
        let c = make(audio: { ScriptedAudioCapture(rmsLevels: script) }, injector: injector)
        await c.warmModel()

        c.toggleHandsFree()
        XCTAssertTrue(c.handsFreeActive)

        let injected = await wait { injector.count >= 1 }
        XCTAssertTrue(injected)
        XCTAssertEqual(injector.last, "Hello world")   // deterministic cleaner capitalised

        c.stopHandsFree()
        XCTAssertFalse(c.handsFreeActive)
    }

    func testSilenceOnlyNeverInjects() async {
        let injector = FakeInjector()
        let c = make(audio: { ScriptedAudioCapture(rmsLevels: [Float](repeating: 0, count: 40)) }, injector: injector)
        await c.warmModel()
        c.startHandsFree()
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(injector.count, 0)
        c.stopHandsFree()
        XCTAssertFalse(c.handsFreeActive)
    }

    func testToggleOff() async {
        let injector = FakeInjector()
        let c = make(audio: { ScriptedAudioCapture(rmsLevels: [Float](repeating: 0, count: 100)) }, injector: injector)
        await c.warmModel()
        c.toggleHandsFree(); XCTAssertTrue(c.handsFreeActive)
        c.toggleHandsFree(); XCTAssertFalse(c.handsFreeActive)
    }

    func testSTTStartFailureStopsHandsFree() async {
        // beginStream throws on the first utterance → must stop (release mic), not spin silently (Codex).
        let injector = FakeInjector()
        let script = [Float](repeating: 0.3, count: 4) + [Float](repeating: 0, count: 10)
        let stt = FakeSTTEngine(beginStreamError: STTError.engineFailure("boom"))
        let c = make(audio: { ScriptedAudioCapture(rmsLevels: script) }, injector: injector, stt: stt)
        await c.warmModel()
        c.startHandsFree()
        let stopped = await wait { !c.handsFreeActive }
        XCTAssertTrue(stopped)
        XCTAssertNotNil(c.lastError)
        XCTAssertEqual(injector.count, 0)
    }

    func testPushToTalkIgnoredWhileHandsFree() async {
        let injector = FakeInjector()
        let c = make(audio: { ScriptedAudioCapture(rmsLevels: [Float](repeating: 0, count: 100)) }, injector: injector)
        await c.warmModel()
        c.startHandsFree()
        c.startDictation()                  // must be ignored (one mic owner)
        XCTAssertTrue(c.handsFreeActive)
        XCTAssertFalse(c.phase.isActive)
        c.stopHandsFree()
    }
}
