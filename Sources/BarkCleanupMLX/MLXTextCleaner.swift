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
    private var loadFailed = false

    public init(modelID: String = "mlx-community/Qwen3-4B-Instruct-2507-4bit") {
        self.modelID = modelID
    }

    public var isAvailable: Bool {
        get async { !loadFailed }
    }

    public func clean(_ text: String, mode: Mode) async throws -> String {
        let model = try await load()
        // Fresh session per call → no conversation state bleeds between dictations.
        let session = ChatSession(model, instructions: PromptTemplate.system(for: mode))
        let response = try await session.respond(to: PromptTemplate.user(transcript: text))
        return response
    }

    private func load() async throws -> ModelContainer {
        if let container { return container }
        do {
            // Default Hugging Face hub client + tokenizer loader, LLM factory.
            let model = try await #huggingFaceLoadModelContainer(
                configuration: ModelConfiguration(id: modelID)
            )
            container = model
            return model
        } catch {
            loadFailed = true
            throw CleanupError.modelUnavailable
        }
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
