import Foundation

/// A refine-turn boundary derived from a modifier-key change.
public enum RefineKeyEvent: Sendable, Equatable {
    case refineStart   // left-option pressed while push-to-talk is held
    case refineEnd     // left-option released
}

/// Pure decision for the left-option (hold-to-refine) gesture (012). Keeps the
/// OS keycode constant and the left/right discrimination in one unit-tested place
/// so `HotkeyManager` (an untestable CGEventTap) stays thin. See
/// `contracts/refine-key-decoder.md`.
///
/// Left option is keycode 58 (`kVK_Option`); right option is 61
/// (`kVK_RightOption`) and is intentionally ignored (FR-001 / SC-004). The
/// `.flagsChanged` event carries the changed key's keycode, so left/right *are*
/// distinguishable here — unlike the device-independent `CGEventFlags` used for
/// the primary hotkey.
public enum RefineKeyDecoder {
    public static let leftOptionKeycode: Int64 = 58

    /// - Parameters:
    ///   - alternateOn: does the event's flags now contain the alternate (option) mask?
    ///   - keycode: the `.flagsChanged` event's `keyboardEventKeycode` field
    ///   - fnHeld: is the push-to-talk modifier currently held?
    ///   - auxHeld: is a refine turn already open?
    public static func decide(
        alternateOn: Bool, keycode: Int64, fnHeld: Bool, auxHeld: Bool
    ) -> RefineKeyEvent? {
        guard keycode == leftOptionKeycode, fnHeld else { return nil }
        if alternateOn && !auxHeld { return .refineStart }
        if !alternateOn && auxHeld { return .refineEnd }
        return nil   // no edge, or a re-trigger
    }
}
