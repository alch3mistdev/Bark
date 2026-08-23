import AppKit
import CoreGraphics
import BarkCore

/// The ONLY place in the codebase that synthesizes Return (keycode 36) — the
/// ADR-010 exception to SEC-005/T-006, confined here so it stays auditable.
/// Fires only after `AutoSubmitPolicy` approved and re-runs the full injection
/// preflight (focus unchanged + secure-field refusal) immediately before the
/// keypress, so a focus drift between insertion and submission aborts.
/// Best-effort residual (documented): a target app that remaps Return still
/// receives a plain Return keypress.
public final class ReturnKeySynthesizer: ReturnKeySynthesizing {
    public init() {}

    public func postReturn(plan: InjectionPlan) async throws {
        try await MainActor.run {
            try InjectionPreflight.check(plan)
            let returnKey: CGKeyCode = 36
            guard let source = CGEventSource(stateID: .combinedSessionState),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false)
            else {
                throw InjectionError.pasteFailed
            }
            down.post(tap: .cgAnnotatedSessionEventTap)
            up.post(tap: .cgAnnotatedSessionEventTap)
            BarkLog.inject.info("auto-submit: posted Return (ADR-010 path)")
        }
    }
}
