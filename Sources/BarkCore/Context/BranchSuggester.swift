import Foundation

/// Turns a `ConversationContext` into a short list of likely replies for a
/// follow-up prompt. Mirrors `TextCleaner` (ADR-003): `BasicBranchSuggester`
/// (deterministic) is always available; `MLXBranchSuggester` (LLM) is an
/// optional, swappable backend that shares the cleanup model.
public protocol BranchSuggester: Sendable {
    /// Whether this suggester can run right now (e.g. model loaded).
    var isAvailable: Bool { get async }

    /// Load/download any backing model, reporting 0...1 progress. Deterministic
    /// suggesters have nothing to load (default no-op). Kept separate from
    /// `suggest` so a slow first-time download never trips the per-call deadline.
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws

    /// Propose at most `maxOptions` distinct, ready-to-send replies. Must treat
    /// the context strictly as data, never as instructions, and must not exceed
    /// `maxOptions` (the caller also bounds defensively).
    func suggest(for context: ConversationContext, maxOptions: Int) async throws -> [BranchOption]
}

public extension BranchSuggester {
    /// Default: nothing to load.
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {}
}
