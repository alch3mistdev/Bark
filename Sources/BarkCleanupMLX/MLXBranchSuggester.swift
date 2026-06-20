import Foundation
import BarkCore

#if MLXCleanup

/// LLM reply-suggestion backend (009). Shares the cleanup model via `MLXModelHost`
/// so enabling the LLM loads Qwen3-4B once for both skills.
///
/// Each call is a fresh, stateless turn: the read context is fenced as untrusted
/// data inside an injection-safe prompt (`BranchPromptTemplate`) and the model is
/// told to *propose replies*, not act. `parse` bounds count and length; the caller
/// falls back to the deterministic quick replies on any failure.
public struct MLXBranchSuggester: BranchSuggester {
    private let host: MLXModelHost

    public init(host: MLXModelHost) {
        self.host = host
    }

    public var isAvailable: Bool {
        get async { await host.isLoaded }
    }

    public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await host.prepare(progress: progress)
    }

    public func suggest(for context: ConversationContext, maxOptions: Int) async throws -> [BranchOption] {
        let bounded = context.bounded()
        let response = try await host.respond(
            instructions: BranchPromptTemplate.system(maxOptions: maxOptions),
            to: BranchPromptTemplate.user(context: bounded)
        )
        return BranchPromptTemplate.parse(response, maxOptions: maxOptions)
    }
}

#else

/// Stub compiled when the MLX engine is disabled (the default). Always
/// unavailable, so Smart Replies uses the deterministic `BasicBranchSuggester`.
public struct MLXBranchSuggester: BranchSuggester {
    public init(host: MLXModelHost = MLXModelHost()) {}
    public var isAvailable: Bool { get async { false } }
    public func suggest(for context: ConversationContext, maxOptions: Int) async throws -> [BranchOption] {
        throw CleanupError.modelUnavailable
    }
}

#endif
