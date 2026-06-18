import Foundation
import BarkCore

#if MLXCleanup
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// LLM rewrite backend (Qwen3-4B-Instruct, 4-bit) via MLX-Swift — runs on the
/// Apple GPU, fully offline once the model is cached (ef-ai-ml pick, ADR-003).
///
/// Each `clean` is a fresh, stateless turn: the dictated text is fenced as
/// untrusted data inside an injection-safe prompt (`PromptTemplate`) so speech
/// can never act as an instruction (AIML-002 / SEC-010). The caller bounds the
/// output length (`OutputValidator`) and always has the deterministic fallback.
public actor MLXTextCleaner: TextCleaner {
    private let modelID: String
    private var container: ModelContainer?

    public init(modelID: String = "mlx-community/Qwen3-4B-Instruct-2507-4bit") {
        self.modelID = modelID
    }

    /// Ready only once the model is loaded — so the caller never invokes `clean`
    /// (and the per-utterance deadline) while a multi-GB download is in flight.
    public var isAvailable: Bool {
        get async { container != nil }
    }

    /// Download (first run, ~2.5 GB) + load the model, reporting progress. Safe to
    /// call repeatedly; a loaded container is reused.
    public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        if container != nil { return }
        // Let the real error propagate (no-network / disk-full / 403) so the UI
        // can show a useful message rather than a generic one.
        let model = try await #huggingFaceLoadModelContainer(
            configuration: ModelConfiguration(id: modelID),
            progressHandler: { p in progress(p.fractionCompleted) }
        )
        container = model
    }

    public func clean(_ text: String, mode: Mode) async throws -> String {
        // prepare() must have loaded the model; we never download under the deadline.
        guard let container else { throw CleanupError.modelUnavailable }
        // Fresh session per call → no conversation state bleeds between dictations.
        let session = ChatSession(container, instructions: PromptTemplate.system(for: mode))
        return try await session.respond(to: PromptTemplate.user(transcript: text))
    }
}

#else

/// Stub compiled when the MLX engine is disabled (the default). Always reports
/// unavailable so the pipeline uses the deterministic `BasicTextCleaner`.
/// Enable the real engine via the README → "Enable LLM rewrite (MLX)".
public struct MLXTextCleaner: TextCleaner {
    public init(modelID: String = "") {}
    public var isAvailable: Bool { get async { false } }
    public func clean(_ text: String, mode: Mode) async throws -> String {
        throw CleanupError.modelUnavailable
    }
}

#endif
