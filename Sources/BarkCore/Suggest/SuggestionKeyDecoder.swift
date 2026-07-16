import Foundation

/// What a keypress means while the suggestion overlay is up (015 FR-009).
public enum SuggestionKeyEvent: Sendable, Equatable {
    case choose(Int)   // number key → 0-based candidate index
    case moveUp
    case moveDown
    case accept        // Return / keypad Enter → act on the highlighted row
    case dismiss       // Escape
    case other         // 'o' → dictate a custom reply
}

/// Pure keycode → overlay-event table. Twin of `RefineKeyDecoder`: the OS
/// keycode constants live in one unit-tested place so the overlay panel's
/// keyDown handler stays thin. Unknown keys return nil (pass through).
public enum SuggestionKeyDecoder {
    public static func decode(keyCode: UInt16) -> SuggestionKeyEvent? {
        switch keyCode {
        case 18: return .choose(0)    // 1
        case 19: return .choose(1)    // 2
        case 20: return .choose(2)    // 3
        case 21: return .choose(3)    // 4
        case 126: return .moveUp
        case 125: return .moveDown
        case 36, 76: return .accept   // Return, keypad Enter
        case 53: return .dismiss      // Escape
        case 31: return .other        // 'o'
        default: return nil
        }
    }
}
