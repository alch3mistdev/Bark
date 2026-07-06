import Foundation

/// A user's stored edit to one built-in mode's prompt fields (013).
///
/// `nil` field = "not overridden — use the shipped default"; an empty string is
/// a meaningful override ("cleared" → the engine's generic fallback applies).
/// Built-in `Mode` constants are never mutated: overrides are applied on top
/// when the effective mode list is built, so reset-to-default is simply
/// removing the override — including defaults changed by future app updates.
public struct PromptOverride: Codable, Sendable, Equatable {
    public var systemPrompt: String?
    public var revisionPrompt: String?

    /// Hard bound per instruction field. Saving longer text is rejected,
    /// never truncated (FR-009).
    public static let maxFieldLength = 4_000

    public init(systemPrompt: String? = nil, revisionPrompt: String? = nil) {
        self.systemPrompt = systemPrompt
        self.revisionPrompt = revisionPrompt
    }

    /// Carries no information; must not be persisted.
    public var isEmpty: Bool { systemPrompt == nil && revisionPrompt == nil }

    /// Both fields within `maxFieldLength` (nil fields are always valid).
    public var isValid: Bool {
        (systemPrompt?.count ?? 0) <= Self.maxFieldLength
            && (revisionPrompt?.count ?? 0) <= Self.maxFieldLength
    }

    /// True when applying this override to `mode` would change nothing —
    /// such overrides are pruned so "Modified" is never shown spuriously.
    /// An empty revision on a mode that ships none is a no-op too: both
    /// resolve to the generic refine instruction.
    public func isNoOp(for mode: Mode) -> Bool {
        let revisionMatches = revisionPrompt == nil
            || revisionPrompt == mode.revisionPrompt
            || (revisionPrompt == "" && mode.revisionPrompt == nil)
        return (systemPrompt == nil || systemPrompt == mode.systemPrompt) && revisionMatches
    }
}

public extension Mode {
    /// Copy with prompt fields replaced where the override defines them.
    /// Identity, name, symbol, `usesLLM`, and deterministic toggles are never
    /// overridden — only prompt text of built-ins is user-editable (013).
    func applyingOverride(_ override: PromptOverride?) -> Mode {
        guard let override else { return self }
        var mode = self
        if let system = override.systemPrompt { mode.systemPrompt = system }
        if let revision = override.revisionPrompt { mode.revisionPrompt = revision }
        return mode
    }
}
