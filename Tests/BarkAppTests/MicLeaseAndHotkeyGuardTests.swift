import XCTest
@testable import BarkCore
@testable import BarkEngines
@testable import Bark

/// 017 T011: the discussion mic lease is a hard interlock, and the hotkey
/// collision guard is 4-way in every direction.
@MainActor
final class MicLeaseAndHotkeyGuardTests: XCTestCase {
    private let target = InjectionTarget(pid: 4242, bundleID: "com.example.TextEdit")

    private func make() -> DictationController {
        let defaults = UserDefaults(suiteName: "bark-lease-test-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults, key: "k")
        settings.update { $0.selectedModeID = "raw" }
        let perms = PermissionsCoordinator()
        perms.overrideForTesting(microphone: .granted)
        return DictationController(
            settings: settings, permissions: perms, hotkey: HotkeyManager(),
            stt: FakeSTTEngine(finalText: "hi"), llmCleaner: FakeCleaner(.ok("hi")),
            history: nil, audioFactory: { FakeAudioCapture() },
            pasteInjector: FakeInjector(), keystrokeInjector: FakeInjector(),
            clipboardInjector: FakeInjector(),
            cleanupDeadline: 0.3, targetProvider: { [target] in target }
        )
    }

    func testMicLeaseBlocksDictationStart() async {
        let c = make()
        await c.warmModel()
        c.micLeaseHeld = true
        c.startDictation()
        XCTAssertEqual(c.phase, .idle)   // refused: no session started
        c.micLeaseHeld = false
        c.startDictation()
        XCTAssertNotEqual(c.phase, .idle)   // now it runs
        c.cancelDictation()
    }

    func testMicLeaseBlocksHandsFreeStart() async {
        let c = make()
        await c.warmModel()
        c.micLeaseHeld = true
        c.startHandsFree()
        XCTAssertFalse(c.handsFreeActive)
        c.micLeaseHeld = false
        c.startHandsFree()
        XCTAssertTrue(c.handsFreeActive)
        c.stopHandsFree()
    }

    func testDictationHotkeySettersRefuseDiscussionKey() {
        let c = make()
        let f7 = HotkeySetting(kind: .keyToggle, keyCode: 98, modifierFlags: 0)   // discussion default
        c.hotkeySetting = f7
        XCTAssertNotEqual(c.hotkeySetting, f7)
        XCTAssertEqual(c.lastError, "That key is already the discussion hotkey.")

        c.handsFreeHotkeySetting = f7
        XCTAssertNotEqual(c.handsFreeHotkeySetting, f7)
        XCTAssertEqual(c.lastError, "That key is already the discussion hotkey.")
    }

    func testSuggestionHotkeySetterRefusesDiscussionKey() {
        let defaults = UserDefaults(suiteName: "bark-lease-test-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults, key: "k")
        let dictation = make()
        let s = SuggestionController(
            settings: settings, dictation: dictation,
            capture: FakeContextCapture(.fail(.empty)), localEngine: nil,
            secretStore: InMemorySecretStore(),
            pasteInjector: FakeInjector(), keystrokeInjector: FakeInjector(),
            clipboardInjector: FakeInjector()
        )
        let f7 = HotkeySetting(kind: .keyToggle, keyCode: 98, modifierFlags: 0)
        s.hotkeySetting = f7
        XCTAssertNotEqual(s.hotkeySetting, f7)
        XCTAssertEqual(s.lastError, "That key is already the discussion hotkey.")
    }
}
