import XCTest
@testable import BarkCore

final class HotkeyPresetTests: XCTestCase {
    func testFnModifierMapsToFn() {
        XCTAssertEqual(HotkeyPreset.from(HotkeySetting(kind: .modifierHold, modifierFlags: HotkeySetting.fnFlag)), .fn)
    }

    func testToggleMapsToCustom() {
        XCTAssertEqual(HotkeyPreset.from(HotkeySetting(kind: .keyToggle, keyCode: 96)), .custom)
    }

    func testNonFnModifierMapsToCustom() {
        // Only fn is a safe modifier preset; any other modifier hold is "custom".
        XCTAssertEqual(HotkeyPreset.from(HotkeySetting(kind: .modifierHold, modifierFlags: 0x100000)), .custom)
    }

    func testFnPresetProducesFnSetting() {
        let s = HotkeyPreset.fn.setting(currentCustom: HotkeySetting(kind: .keyToggle, keyCode: 96))
        XCTAssertEqual(s, HotkeySetting(kind: .modifierHold, modifierFlags: HotkeySetting.fnFlag))
    }

    func testCustomPreservesRecordedKey() {
        let recorded = HotkeySetting(kind: .keyToggle, keyCode: 96, modifierFlags: 0)
        XCTAssertEqual(HotkeyPreset.custom.setting(currentCustom: recorded), recorded)
    }

    func testCustomFallsBackToDefaultWhenNoToggleKey() {
        let s = HotkeyPreset.custom.setting(currentCustom: HotkeySetting(kind: .modifierHold, modifierFlags: HotkeySetting.fnFlag))
        XCTAssertEqual(s, .default)
    }

    func testFnRoundTrips() {
        XCTAssertEqual(HotkeyPreset.from(HotkeyPreset.fn.setting(currentCustom: .default)), .fn)
    }

    func testOnlyTwoPresetsOffered() {
        XCTAssertEqual(HotkeyPreset.allCases, [.fn, .custom])
    }
}
