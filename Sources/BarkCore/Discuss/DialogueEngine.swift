import Foundation

/// One side of a discussion turn. The system prompt is never a turn — it is
/// rebuilt per call by `DialoguePromptBuilder` so a mid-session Recapture
/// changes the grounding without mutating history (017 research R2).
public enum DialogueRole: String, Sendable, Equatable {
    case user
    case assistant
}

public struct DialogueTurn: Sendable, Equatable {
    public var role: DialogueRole
    public var text: String

    public init(role: DialogueRole, text: String) {
        self.role = role
        self.text = text
    }
}

/// A parsed engine reply. `isReadyToSynthesize` is the machine-readable
/// readiness channel (017 FR-003): free text never drives control flow.
public struct DialogueReply: Sendable, Equatable {
    public var text: String
    public var isReadyToSynthesize: Bool

    public init(text: String, isReadyToSynthesize: Bool) {
        self.text = text
        self.isReadyToSynthesize = isReadyToSynthesize
    }

    /// `ready` with an empty reply is the engine's "the user just confirmed —
    /// draft now" signal (contracts/dialogue-engine.md). A non-empty ready
    /// reply is a question ("Ready for me to draft it?") and only highlights
    /// Done in the UI.
    public var isSynthesisTrigger: Bool {
        isReadyToSynthesize && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum DialogueError: Error, Sendable, Equatable {
    case engineUnavailable
    case deadlineExceeded
    case badResponse(String)
    case transport(String)
}

/// Multi-turn Socratic dialogue engine (017). Deliberately a sibling of
/// `SuggestionEngine`, not an extension of it: that seam is a shipped flat
/// `{system, user}` pair, while a discussion needs the whole conversation.
/// `system`/`turns` content is built exclusively by `DialoguePromptBuilder`
/// (fenced); the raw `reply` output goes back through `DialogueReplyParser`
/// so malformed output can never trigger synthesis. Deadlines are the
/// caller's job; conformers just honor cancellation.
public protocol DialogueEngine: Sendable {
    var isAvailable: Bool { get async }

    /// One conversational reply (raw engine text, ≤ 256 tokens, temp 0).
    func reply(system: String, turns: [DialogueTurn]) async throws -> String

    /// Final-prompt synthesis over the whole conversation (plain text,
    /// ≤ 512 tokens); the caller bounds and sanitizes it.
    func synthesize(system: String, turns: [DialogueTurn]) async throws -> String
}
