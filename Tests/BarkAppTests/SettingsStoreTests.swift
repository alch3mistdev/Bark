import XCTest
@testable import BarkCore
@testable import Bark

@MainActor
final class SettingsStoreTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "settings-store-\(UUID().uuidString)")!
    }

    func testValidBlobLoads() {
        let defaults = freshDefaults()
        var s = Settings.default
        s.selectedModeID = "email"
        defaults.set(try! JSONEncoder().encode(s), forKey: "k")

        let store = SettingsStore(defaults: defaults, key: "k")
        XCTAssertEqual(store.settings.selectedModeID, "email")
        XCTAssertFalse(store.didResetSettings)
    }

    func testMissingBlobUsesDefaultWithoutResetFlag() {
        let store = SettingsStore(defaults: freshDefaults(), key: "k")
        XCTAssertEqual(store.settings, .default)
        XCTAssertFalse(store.didResetSettings)
    }

    func testCorruptBlobResetsBacksUpAndFlags() {
        // A corrupt/incompatible blob must never be silently discarded: reset to
        // defaults, keep the raw payload under <key>.backup, and flag the reset
        // so the menu can tell the user once.
        let defaults = freshDefaults()
        let garbage = Data("not json at all".utf8)
        defaults.set(garbage, forKey: "k")

        let store = SettingsStore(defaults: defaults, key: "k")
        XCTAssertEqual(store.settings, .default)
        XCTAssertTrue(store.didResetSettings)
        XCTAssertEqual(defaults.data(forKey: "k.backup"), garbage)

        store.acknowledgeReset()
        XCTAssertFalse(store.didResetSettings)
    }
}
