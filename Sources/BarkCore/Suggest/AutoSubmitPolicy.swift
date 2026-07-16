import Foundation

/// The single decision point for the SEC-005 exception (015 FR-012 / ADR-010):
/// whether to post Return after inserting a suggestion. Pure and exhaustively
/// tested — `ReturnKeySynthesizer` (the only Return-posting site) fires only
/// when this approves. Terminals are deliberately allowed: the user read and
/// chose the exact string, so the Return is per-use consent.
public enum AutoSubmitPolicy {
    public static func decide(
        enabled: Bool,                 // the opt-in setting (default OFF)
        selectionWasExplicit: Bool,    // a candidate the user picked — never the Other/dictation path
        strategy: InjectionStrategy,   // copyOnly never submits (nothing was typed)
        secureInputActive: Bool,       // re-checked AFTER insertion, before the keypress
        focusUnchanged: Bool           // ditto
    ) -> Bool {
        enabled
            && selectionWasExplicit
            && strategy != .copyOnly
            && !secureInputActive
            && focusUnchanged
    }
}
