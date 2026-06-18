import Foundation

/// User-facing hotkey choices. Maps to/from the persisted `HotkeySetting`.
///
/// Only two options are offered, both safe: holding **fn** (the one modifier
/// that doesn't collide with normal ⌘/⌥/⌃ shortcuts) for push-to-talk, or a
/// recorded **function key** (F1–F20) that toggles dictation. Plain ⌘/⌥/⌃ holds
/// are deliberately NOT offered — a flags-based tap can't tell left from right,
/// so they'd fire on every ordinary shortcut (Codex finding). Pure (unit-tested).
public enum HotkeyPreset: String, Sendable, CaseIterable, Identifiable {
    case fn        // hold the fn / Globe key (default, push-to-talk)
    case custom    // a recorded function-key toggle

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .fn: return "Hold fn (Globe)"
        case .custom: return "Custom function key (toggle)"
        }
    }

    /// The preset a given setting represents.
    public static func from(_ setting: HotkeySetting) -> HotkeyPreset {
        if setting.kind == .modifierHold && setting.modifierFlags == HotkeySetting.fnFlag { return .fn }
        return .custom
    }

    /// Build the setting for this preset. `.custom` keeps the existing recorded
    /// toggle key if there is one (the UI shows the recorder to capture a new one).
    public func setting(currentCustom: HotkeySetting) -> HotkeySetting {
        switch self {
        case .fn:
            return HotkeySetting(kind: .modifierHold, keyCode: 0, modifierFlags: HotkeySetting.fnFlag)
        case .custom:
            return currentCustom.kind == .keyToggle ? currentCustom : .default
        }
    }
}
