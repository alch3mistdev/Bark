import Foundation

public enum InjectionDecision: Sendable, Equatable {
    case proceed
    case refuse(reason: String)
}

/// Decides whether it is safe to inject text into the focused field.
/// Pure logic so it can be exhaustively unit-tested; the OS probes
/// (`IsSecureEventInputEnabled`, AX role) live in `BarkEngines` and feed this.
///
/// Refuses when macOS Secure Event Input is active or the focused element is a
/// secure/password field, so dictated text can never land in a password box
/// (SEC-002 / T-005).
public enum SecureFieldPolicy {
    /// AX roles/subroles that denote a secure text entry.
    static let secureRoles: Set<String> = [
        "AXSecureTextField",
    ]

    public static func decide(
        secureInputEnabled: Bool,
        focusedElementRole: String?,
        allowIntoSecureField: Bool = false
    ) -> InjectionDecision {
        if secureInputEnabled {
            return .refuse(reason: "Secure input is active (a password field is focused).")
        }
        if let role = focusedElementRole, secureRoles.contains(role), !allowIntoSecureField {
            return .refuse(reason: "Focused field is a secure/password field.")
        }
        return .proceed
    }
}
