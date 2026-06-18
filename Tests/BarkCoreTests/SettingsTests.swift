import XCTest
@testable import BarkCore

final class SettingsTests: XCTestCase {
    func testCodableRoundTrip() throws {
        var s = Settings.default
        s.selectedModeID = "email"
        s.localeID = "fr-FR"
        s.launchAtLogin = true
        s.historyEnabled = true
        s.customModes = [Mode(id: "legal", name: "Legal", usesLLM: true, systemPrompt: "Formal.")]
        s.hotkey = HotkeySetting(kind: .keyToggle, keyCode: 96, modifierFlags: 0)

        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertEqual(decoded, s)
    }

    func testTolerantDecodeFillsDefaults() throws {
        // An empty/old payload decodes to defaults rather than failing.
        let decoded = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, .default)
        XCTAssertEqual(decoded.selectedModeID, Mode.clean.id)
        XCTAssertFalse(decoded.historyEnabled)
    }

    func testPartialDecodeKeepsKnownAndDefaultsRest() throws {
        let json = #"{"selectedModeID":"code","localeID":"de-DE"}"#
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.selectedModeID, "code")
        XCTAssertEqual(decoded.localeID, "de-DE")
        XCTAssertTrue(decoded.llmEnabled)          // default
        XCTAssertFalse(decoded.launchAtLogin)      // default
    }

    func testMakeModeRegistryMergesCustomAndSelection() {
        let custom = Mode(id: "legal", name: "Legal", usesLLM: true)
        let s = Settings(selectedModeID: "legal", customModes: [custom])
        let reg = s.makeModeRegistry()
        XCTAssertNotNil(reg.mode(id: "legal"))
        XCTAssertNotNil(reg.mode(id: "email"))     // built-ins present
        XCTAssertEqual(reg.selected.id, "legal")
    }

    func testHotkeyDisplayName() {
        XCTAssertEqual(HotkeySetting(kind: .modifierHold, modifierFlags: HotkeySetting.fnFlag).displayName, "Hold fn (Globe)")
        XCTAssertEqual(HotkeySetting(kind: .modifierHold, modifierFlags: 0x100000).displayName, "Hold ⌘")
    }
}

final class HistoryRetentionTests: XCTestCase {
    private func record(_ secondsAgo: Double, _ text: String) -> HistoryRecord {
        HistoryRecord(createdAt: Date(timeIntervalSinceNow: -secondsAgo),
                      transcript: text, output: text, modeID: "clean", appBundleID: nil)
    }

    func testTrimSortsNewestFirst() {
        let trimmed = RetentionPolicy.trim([record(30, "old"), record(1, "new"), record(10, "mid")])
        XCTAssertEqual(trimmed.map(\.output), ["new", "mid", "old"])
    }

    func testTrimCapsToLimit() {
        let many = (0..<10).map { record(Double($0), "r\($0)") }
        let trimmed = RetentionPolicy.trim(many, limit: 3)
        XCTAssertEqual(trimmed.count, 3)
        XCTAssertEqual(trimmed.first?.output, "r0") // most recent (0s ago)
    }
}
