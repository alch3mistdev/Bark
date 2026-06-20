import Foundation
import BarkCore

#if MLXCleanup
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// Owns the single Qwen3-4B `ModelContainer` shared by every LLM skill (cleanup
/// rewrite + reply suggestions). Sharing means the ~2.5 GB model is downloaded
/// and held in GPU memory **once**, not per skill.
///
/// Each `respond` is a fresh, stateless `ChatSession`, so no conversation state
/// bleeds between calls (matching the original `MLXTextCleaner` behavior).
public actor MLXModelHost {
    private let modelID: String
    private var container: ModelContainer?

    public init(modelID: String = "mlx-community/Qwen3-4B-Instruct-2507-4bit") {
        self.modelID = modelID
    }

    /// Loaded only once the model is in memory — callers gate generation on this
    /// so the per-call deadline never wraps a multi-GB download.
    public var isLoaded: Bool { container != nil }

    /// Download (first run) + load the model, reporting progress. Idempotent.
    public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        if container != nil { return }
        // Let the real error propagate (no-network / disk-full / 403) so the UI
        // can show a useful message.
        let model = try await #huggingFaceLoadModelContainer(
            configuration: ModelConfiguration(id: modelID),
            progressHandler: { p in progress(p.fractionCompleted) }
        )
        container = model
    }

    /// One stateless turn with the given system instructions. Throws
    /// `modelUnavailable` if the model hasn't been loaded yet.
    public func respond(instructions: String, to prompt: String) async throws -> String {
        guard let container else { throw CleanupError.modelUnavailable }
        let session = ChatSession(container, instructions: instructions)
        return try await session.respond(to: prompt)
    }
}

#else

/// Stub host for the lean (no-MLX) build. Never loads; `respond` is unavailable.
public actor MLXModelHost {
    public init(modelID: String = "") {}
    public var isLoaded: Bool { false }
    public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {}
    public func respond(instructions: String, to prompt: String) async throws -> String {
        throw CleanupError.modelUnavailable
    }
}

#endif
