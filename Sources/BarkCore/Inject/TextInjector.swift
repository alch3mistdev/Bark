import Foundation

/// Types out / pastes final text into the focused app. Concrete impls
/// (`PasteboardInjector`, `KeystrokeInjector`) live in `BarkEngines`.
public protocol TextInjector: Sendable {
    /// Inject `text` according to `plan`. Implementations MUST:
    ///  - re-verify focus (`FocusGuard`) and refuse on mismatch,
    ///  - never synthesize Return/Enter,
    ///  - restore the clipboard if they use it.
    func inject(_ text: String, plan: InjectionPlan) async throws
}

public enum InjectionError: Error, Sendable, Equatable {
    case focusChanged
    case secureFieldBlocked
    case accessibilityDenied
    case pasteFailed
    case emptyText
}
