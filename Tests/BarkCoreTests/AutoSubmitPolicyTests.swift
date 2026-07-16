import XCTest
@testable import BarkCore

/// Exhaustive decision table for the SEC-005 exception (015 FR-012 / ADR-009):
/// Return fires ONLY when every guard passes — enabled, an explicitly selected
/// suggestion, a typing strategy (not copyOnly), no secure input, focus intact.
final class AutoSubmitPolicyTests: XCTestCase {
    func testFiresOnlyInTheSingleApprovedRow() {
        for enabled in [false, true] {
            for explicit in [false, true] {
                for strategy in [InjectionStrategy.paste, .keystroke, .copyOnly] {
                    for secure in [false, true] {
                        for focusUnchanged in [false, true] {
                            let decision = AutoSubmitPolicy.decide(
                                enabled: enabled,
                                selectionWasExplicit: explicit,
                                strategy: strategy,
                                secureInputActive: secure,
                                focusUnchanged: focusUnchanged
                            )
                            let approved = enabled && explicit && strategy != .copyOnly
                                && !secure && focusUnchanged
                            XCTAssertEqual(decision, approved,
                                "enabled:\(enabled) explicit:\(explicit) strategy:\(strategy) secure:\(secure) focus:\(focusUnchanged)")
                        }
                    }
                }
            }
        }
    }

    func testDefaultOffNeverFires() {
        XCTAssertFalse(AutoSubmitPolicy.decide(
            enabled: false, selectionWasExplicit: true, strategy: .keystroke,
            secureInputActive: false, focusUnchanged: true))
    }

    func testDictationPathNeverFires() {
        // "Other" / dictated replies are not explicit selections (v1 scope).
        XCTAssertFalse(AutoSubmitPolicy.decide(
            enabled: true, selectionWasExplicit: false, strategy: .keystroke,
            secureInputActive: false, focusUnchanged: true))
    }

    func testClipboardRoutingNeverFires() {
        XCTAssertFalse(AutoSubmitPolicy.decide(
            enabled: true, selectionWasExplicit: true, strategy: .copyOnly,
            secureInputActive: false, focusUnchanged: true))
    }

    func testTerminalsAreDeliberatelyAllowed() {
        // keystroke strategy == terminal target: allowed by design (ADR-009) —
        // the user read and chose the exact string (per-use consent).
        XCTAssertTrue(AutoSubmitPolicy.decide(
            enabled: true, selectionWasExplicit: true, strategy: .keystroke,
            secureInputActive: false, focusUnchanged: true))
    }
}
