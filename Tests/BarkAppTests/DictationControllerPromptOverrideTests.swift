import XCTest
@testable import BarkCore
@testable import BarkEngines
@testable import Bark

/// Built-in prompt override CRUD through the controller + SettingsStore (013 US2).
@MainActor
final class DictationControllerPromptOverrideTests: XCTestCase {
    private func make() -> DictationController {
        let defaults = UserDefaults(suiteName: "bark-override-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults, key: "k")
        let perms = PermissionsCoordinator()
        perms.overrideForTesting(microphone: .granted)
        return DictationController(
            settings: settings, permissions: perms, hotkey: HotkeyManager(),
            stt: FakeSTTEngine(), llmCleaner: nil, history: nil,
            audioFactory: { FakeAudioCapture() },
            pasteInjector: FakeInjector(), keystrokeInjector: FakeInjector(),
            clipboardInjector: FakeInjector(),
            cleanupDeadline: 0.3, targetProvider: { nil }
        )
    }

    func testSetGetResetRoundTrip() {
        let c = make()
        XCTAssertFalse(c.isBuiltInModified(id: "email"))

        c.setBuiltInOverride(id: "email", PromptOverride(systemPrompt: "Casual email."))
        XCTAssertTrue(c.isBuiltInModified(id: "email"))
        XCTAssertEqual(c.builtInOverride(id: "email")?.systemPrompt, "Casual email.")
        // The effective mode list the pipeline uses reflects the edit.
        XCTAssertEqual(c.modes.first { $0.id == "email" }?.systemPrompt, "Casual email.")
        XCTAssertEqual(c.modes.first { $0.id == "email" }?.name, Mode.email.name)

        c.setBuiltInOverride(id: "email", nil)   // reset
        XCTAssertFalse(c.isBuiltInModified(id: "email"))
        XCTAssertEqual(c.modes.first { $0.id == "email" }?.systemPrompt, Mode.email.systemPrompt)
    }

    func testOverridePersistsThroughStore() {
        let defaults = UserDefaults(suiteName: "bark-override-persist-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults, key: "k")
        settings.update { $0.builtInPromptOverrides["code"] = PromptOverride(revisionPrompt: "Terser.") }
        // A fresh store over the same defaults sees the override (relaunch survival).
        let reloaded = SettingsStore(defaults: defaults, key: "k")
        XCTAssertEqual(reloaded.settings.builtInPromptOverrides["code"]?.revisionPrompt, "Terser.")
        XCTAssertEqual(reloaded.settings.effectiveModes().first { $0.id == "code" }?.revisionPrompt, "Terser.")
    }

    func testNonBuiltInIdRejected() {
        let c = make()
        c.setBuiltInOverride(id: "custom-abc", PromptOverride(systemPrompt: "x"))
        XCTAssertNil(c.builtInOverride(id: "custom-abc"))
        XCTAssertFalse(c.isBuiltInModified(id: "custom-abc"))
    }

    func testOverLimitRejectedWithFeedback() {
        let c = make()
        let tooLong = String(repeating: "a", count: PromptOverride.maxFieldLength + 1)
        XCTAssertFalse(c.setBuiltInOverride(id: "email", PromptOverride(systemPrompt: tooLong)))
        XCTAssertFalse(c.isBuiltInModified(id: "email"))
        XCTAssertNotNil(c.lastError)   // rejection is surfaced, not silent (ADV-002)
    }

    func testDefaultEqualEditPrunesToUnmodified() {
        let c = make()
        c.setBuiltInOverride(id: "email", PromptOverride(systemPrompt: "Casual email."))
        XCTAssertTrue(c.isBuiltInModified(id: "email"))
        // Re-editing back to the shipped text removes the override entirely.
        c.setBuiltInOverride(id: "email", PromptOverride(systemPrompt: Mode.email.systemPrompt))
        XCTAssertFalse(c.isBuiltInModified(id: "email"))
        // An override carrying no fields is likewise never stored.
        c.setBuiltInOverride(id: "message", PromptOverride())
        XCTAssertFalse(c.isBuiltInModified(id: "message"))
    }

    func testUpsertModeRejectsOverLimitPromptsWithFeedback() {
        let c = make()
        let tooLong = String(repeating: "a", count: PromptOverride.maxFieldLength + 1)
        // Rejected even when the mode doesn't use the LLM (a toggle must not
        // smuggle an over-limit hidden field past validation — ADV-002).
        XCTAssertFalse(c.upsertMode(Mode(id: "custom-x", name: "X", usesLLM: false, systemPrompt: tooLong)))
        XCTAssertFalse(c.modes.contains { $0.id == "custom-x" })
        XCTAssertNotNil(c.lastError)
        XCTAssertFalse(c.upsertMode(Mode(id: "custom-y", name: "Y", usesLLM: true,
                                         systemPrompt: "ok", revisionPrompt: tooLong)))
        XCTAssertFalse(c.modes.contains { $0.id == "custom-y" })
        XCTAssertTrue(c.upsertMode(Mode(id: "custom-z", name: "Z", usesLLM: true, systemPrompt: "ok")))
        XCTAssertTrue(c.modes.contains { $0.id == "custom-z" })
    }
}
