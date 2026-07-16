import Foundation

/// Posts a single Return keypress after a selected suggestion was inserted —
/// the ONE sanctioned exception to the never-synthesize-Return rule
/// (constitution v2.0.0 Principle IV / ADR-009 / 015 FR-012). Gated by
/// `AutoSubmitPolicy` at the call site; the concrete impl
/// (`ReturnKeySynthesizer`, BarkEngines) re-runs injection preflight
/// immediately before the keypress. `TextInjector` implementations remain
/// forbidden from posting Return.
public protocol ReturnKeySynthesizing: Sendable {
    func postReturn(plan: InjectionPlan) async throws
}
