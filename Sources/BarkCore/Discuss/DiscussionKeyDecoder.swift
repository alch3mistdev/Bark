import Foundation

/// Keys the discussion overlay understands (017). Pure table so it's testable;
/// the controller's state guards decide whether an event is meaningful (e.g.
/// `.confirm` acts only in the preview).
public enum DiscussionKeyEvent: Sendable, Equatable {
    case cancel    // Esc
    case confirm   // Return — preview only (the machine ignores it elsewhere)
    case done      // D — force synthesis
    case resume    // R — back to the discussion from the preview
    case copy      // C — copy the previewed prompt / failed-session transcript
}

public enum DiscussionKeyDecoder {
    public static func decode(keyCode: UInt16) -> DiscussionKeyEvent? {
        switch keyCode {
        case 53: return .cancel
        case 36: return .confirm
        case 2:  return .done
        case 15: return .resume
        case 8:  return .copy
        default: return nil
        }
    }
}
