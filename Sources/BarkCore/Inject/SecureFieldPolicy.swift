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
/// Snapshot of macOS Secure Event Input: whether it is on, and which process
/// turned it on (from the IORegistry console-users record, when readable).
public struct SecureInputState: Sendable, Equatable {
    public var enabled: Bool
    public var holderPID: Int32?

    public init(enabled: Bool, holderPID: Int32?) {
        self.enabled = enabled
        self.holderPID = holderPID
    }
}

public enum SecureFieldPolicy {
    /// Whether system-wide Secure Event Input should count as "the target has
    /// a password field focused".
    ///
    /// The flag is global: `loginwindow` routinely keeps it on after an unlock
    /// (a long-standing macOS quirk), and terminals with Secure Keyboard Entry
    /// hold it while frontmost. Read naively it refused every dictation and
    /// discussion on such a machine. Only the *target* holding it says
    /// anything about the target's focused field. An unknown holder stays
    /// conservative (refuse) so the guard never silently weakens.
    public static func secureInputApplies(_ state: SecureInputState, toTargetPID pid: Int32) -> Bool {
        guard state.enabled else { return false }
        guard let holder = state.holderPID else { return true }
        return holder == pid
    }

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
