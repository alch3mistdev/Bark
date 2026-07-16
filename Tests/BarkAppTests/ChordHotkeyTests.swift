import XCTest
import CoreGraphics
@testable import BarkCore
@testable import BarkEngines

/// Modifier-chord toggle hotkeys (015 usability fix): a chord like ⌃⌥S avoids
/// the function-key row entirely, so it never needs `fn` (which collides with
/// the fn-hold push-to-talk). Covers the pure setting↔config bridge + labels;
/// the CGEventTap match itself is runtime behavior (best-effort, QA matrix).
final class ChordHotkeyTests: XCTestCase {
    func testChordSettingRoundTripsThroughConfig() {
        let setting = HotkeySetting(kind: .keyToggle, keyCode: 1, modifierFlags: 0xC0000)  // ⌃⌥S
        let config = HotkeyConfig(setting)
        guard case .keyToggle(let key, let flags) = config.trigger else {
            return XCTFail("expected keyToggle")
        }
        XCTAssertEqual(key, 1)
        XCTAssertTrue(flags.contains(.maskControl))
        XCTAssertTrue(flags.contains(.maskAlternate))
        XCTAssertFalse(flags.contains(.maskCommand))
        // And back to a setting, unchanged.
        XCTAssertEqual(HotkeySetting(config), setting)
    }

    func testBareToggleRoundTripsWithNoModifiers() {
        let setting = HotkeySetting(kind: .keyToggle, keyCode: 96, modifierFlags: 0)  // F5
        let config = HotkeyConfig(setting)
        guard case .keyToggle(let key, let flags) = config.trigger else {
            return XCTFail("expected keyToggle")
        }
        XCTAssertEqual(key, 96)
        XCTAssertEqual(flags.intersection(HotkeyTrigger.chordMask), [])
        XCTAssertEqual(HotkeySetting(config), setting)
    }

    func testConfigDropsNonChordModifierBits() {
        // fn (0x800000) and caps must not survive into the persisted chord.
        let config = HotkeyConfig(trigger: .keyToggle(1, [.maskControl, .maskSecondaryFn]))
        let setting = HotkeySetting(config)
        XCTAssertEqual(setting.modifierFlags, 0x40000)   // only ⌃ kept
    }

    func testDisplayNameRendersChordAndKey() {
        XCTAssertEqual(HotkeySetting(kind: .keyToggle, keyCode: 1, modifierFlags: 0xC0000).displayName, "⌃⌥S")
        XCTAssertEqual(HotkeySetting(kind: .keyToggle, keyCode: 96, modifierFlags: 0).displayName, "F5")
        XCTAssertEqual(HotkeySetting(kind: .keyToggle, keyCode: 49, modifierFlags: 0x100000).displayName, "⌘Space")
        // Conventional modifier order ⌃⌥⇧⌘ regardless of bit order.
        XCTAssertEqual(HotkeySetting(kind: .keyToggle, keyCode: 46, modifierFlags: 0x1E0000).displayName, "⌃⌥⇧⌘M")
    }
}
