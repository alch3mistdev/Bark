import Foundation
import BarkCore

#if MLXCleanup

/// LLM rewrite backend (Qwen3-4B-Instruct, 4-bit) via MLX-Swift — runs on the
/// Apple GPU, fully offline once the model is cached (ef-ai-ml pick, ADR-003).
///
/// Each `clean` is a fresh, stateless turn: the dictated text is fenced as
/// untrusted data inside an injection-safe prompt (`PromptTemplate`) so speech
/// can never act as an instruction (AIML-002 / SEC-010). The caller bounds the
/// output length (`OutputValidator`) and always has the deterministic fallback.
///
/// The model is owned by a shared `MLXModelHost` so cleanup and reply suggestions
/// (009) share one download and one in-memory container.
public struct MLXTextCleaner: TextCleaner {
    private let host: MLXModelHost

    public init(host: MLXModelHost) {
        self.host = host
    }

    /// Ready only once the model is loaded — so the caller never invokes `clean`
    /// (and the per-utterance deadline) while a multi-GB download is in flight.
    public var isAvailable: Bool {
        get async { await host.isLoaded }
    }

    /// Download (first run, ~2.5 GB) + load the model, reporting progress.
    public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await host.prepare(progress: progress)
    }

    public func clean(_ text: String, mode: Mode) async throws -> String {
        try await host.respond(
            instructions: PromptTemplate.system(for: mode),
            to: PromptTemplate.user(transcript: text)
        )
    }
}

#else

/// Stub compiled when the MLX engine is disabled (the default). Always reports
/// unavailable so the pipeline uses the deterministic `BasicTextCleaner`.
/// Enable the real engine via the README → "Enable LLM rewrite (MLX)".
public struct MLXTextCleaner: TextCleaner {
    public init(host: MLXModelHost = MLXModelHost()) {}
    public var isAvailable: Bool { get async { false } }
    public func clean(_ text: String, mode: Mode) async throws -> String {
        throw CleanupError.modelUnavailable
    }
}

#endif
