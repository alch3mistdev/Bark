import Foundation
import BarkCore

#if MLXCleanup
import MLX
import MLXLLM
import MLXLMCommon

/// 017: the discussion dialogue rides the SAME loaded `ModelContainer` as
/// cleanup and suggestions — one residency serves all three. A fresh,
/// stateless `ChatSession` is rebuilt from the fenced transcript on every
/// call (research R2): deterministic, cancellable, and a mid-session
/// Recapture regrounds the next call for free. Prompts arrive pre-fenced
/// from `DialoguePromptBuilder`; raw output goes back through
/// `DialogueReplyParser`, so nothing here is injectable text.
extension MLXTextCleaner: DialogueEngine {
    static let dialogueReplyMaxTokens = 256
    static let dialogueSynthesisMaxTokens = 512
    /// Past these the parser/controller would truncate anyway — stop generating.
    static let dialogueReplyCharBound = 1600
    static let dialogueSynthesisCharBound = 4000

    public func reply(system: String, turns: [DialogueTurn]) async throws -> String {
        try await respond(system: system, turns: turns,
                          kickoff: "Start the discussion with your opening question.",
                          maxTokens: Self.dialogueReplyMaxTokens,
                          charBound: Self.dialogueReplyCharBound)
    }

    public func synthesize(system: String, turns: [DialogueTurn]) async throws -> String {
        try await respond(system: system, turns: turns,
                          kickoff: "Now write the final text.",
                          maxTokens: Self.dialogueSynthesisMaxTokens,
                          charBound: Self.dialogueSynthesisCharBound,
                          forceKickoff: true)
    }

    /// Shared generation: `turns` minus a trailing user turn become the
    /// rehydrated history; that trailing user turn (or the fixed `kickoff`
    /// literal when there is none, or always for synthesis) is the message
    /// responded to. `kickoff` is a fixed string, never user content.
    private func respond(system: String, turns: [DialogueTurn], kickoff: String,
                         maxTokens: Int, charBound: Int,
                         forceKickoff: Bool = false) async throws -> String {
        guard let container else { throw DialogueError.engineUnavailable }
        var history = turns.map { turn -> Chat.Message in
            switch turn.role {
            case .user: return .user(turn.text)
            case .assistant: return .assistant(turn.text)
            }
        }
        let prompt: String
        if !forceKickoff, history.last?.role == .user {
            prompt = history.removeLast().content
        } else {
            prompt = kickoff
        }
        let session = ChatSession(
            container,
            instructions: system,
            history: history,
            generateParameters: GenerateParameters(maxTokens: maxTokens, temperature: 0)
        )
        var output = ""
        for try await item in session.streamDetails(to: prompt, images: [], videos: []) {
            try Task.checkCancellation()
            switch item {
            case .chunk(let piece):
                output += piece
                if output.count > charBound { return output }
            case .info(let info):
                BarkLog.cleanup.info("llm dialogue: prompt \(info.promptTime, format: .fixed(precision: 3), privacy: .public)s, generate \(info.generateTime, format: .fixed(precision: 3), privacy: .public)s, \(info.tokensPerSecond, format: .fixed(precision: 1), privacy: .public) tok/s")
            default:
                break
            }
        }
        return output
    }
}

#else

/// Lean build: no local dialogue engine — the feature is disabled unless the
/// user configures the external backend (017 spec: "lean build disables").
extension MLXTextCleaner: DialogueEngine {
    public func reply(system: String, turns: [DialogueTurn]) async throws -> String {
        throw DialogueError.engineUnavailable
    }

    public func synthesize(system: String, turns: [DialogueTurn]) async throws -> String {
        throw DialogueError.engineUnavailable
    }
}

#endif
