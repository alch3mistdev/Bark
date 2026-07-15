import Foundation
import BarkCore

#if MLXCleanup
import MLX
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
        // Bound MLX's transient buffer cache (weights aside) so footprint doesn't
        // creep across generations. Generous for a bursty 4-bit 4B workload.
        Memory.cacheLimit = 256 * 1024 * 1024
        BarkLog.cleanup.info("mlx model loaded, active memory \(Memory.activeMemory, privacy: .public) bytes")
    }

    /// Release the model weights and MLX's buffer cache — multiple GB back to
    /// the OS. The next `prepare` reloads from the local HuggingFace cache.
    public func unload() {
        container = nil
        Memory.clearCache()
    }

    public func clean(_ text: String, mode: Mode) async throws -> String {
        // prepare() must have loaded the model; we never download under the deadline.
        guard let container else { throw CleanupError.modelUnavailable }
        // Fresh session per call → no conversation state bleeds between dictations.
        let session = ChatSession(
            container,
            instructions: PromptTemplate.system(for: mode),
            generateParameters: Self.generationParameters(inputLength: text.count)
        )
        return try await Self.collect(
            session.streamDetails(to: PromptTemplate.user(transcript: text), images: [], videos: []),
            inputLength: text.count, stage: "clean"
        )
    }

    /// In-session refine (012): apply a spoken instruction to the running draft.
    /// Fresh, stateless turn; both draft and instruction are fenced as untrusted
    /// data (`PromptTemplate.refine*`). The caller bounds output length
    /// (`OutputValidator`) and wraps this in the per-turn deadline.
    public func refine(_ text: String, instruction: String, mode: Mode) async throws -> String {
        guard let container else { throw CleanupError.modelUnavailable }
        let session = ChatSession(
            container,
            instructions: PromptTemplate.refineSystem(for: mode),
            generateParameters: Self.generationParameters(inputLength: text.count)
        )
        return try await Self.collect(
            session.streamDetails(to: PromptTemplate.refineUser(draft: text, instruction: instruction), images: [], videos: []),
            inputLength: text.count, stage: "refine"
        )
    }

    /// Cap output tokens to what a faithful rewrite of `chars` input could need
    /// (~4 chars/token English, ~1.5× headroom). Temperature 0 selects the
    /// deterministic argmax sampler — right for a cleanup function. A
    /// cap-truncated output exceeds `OutputValidator`'s char bound and lands on
    /// the deterministic fallback: the same outcome as exhausting the 8s
    /// deadline, reached in a fraction of the time.
    private static func generationParameters(inputLength chars: Int) -> GenerateParameters {
        GenerateParameters(maxTokens: max(64, min(2048, chars * 6 / 5 + 20)), temperature: 0)
    }

    /// Accumulate the streamed generation, aborting the moment output exceeds
    /// the growth bound `OutputValidator` would reject anyway — breaking out of
    /// the stream cancels the generation task within ~one token instead of
    /// burning the remaining wall-clock deadline. Logs timing telemetry only
    /// (never content — T-008).
    private static func collect(
        _ stream: AsyncThrowingStream<Generation, Error>,
        inputLength: Int,
        stage: String
    ) async throws -> String {
        let maxChars = OutputValidator.maxChars(forInputLength: inputLength)
        var output = ""
        for try await item in stream {
            switch item {
            case .chunk(let piece):
                output += piece
                guard output.count <= maxChars else {
                    throw CleanupError.outputRejected(
                        reason: "\(stage) exceeded growth bound mid-stream (\(output.count) > \(maxChars))")
                }
            case .info(let info):
                BarkLog.cleanup.info("llm \(stage, privacy: .public): prompt \(info.promptTime, format: .fixed(precision: 3), privacy: .public)s, generate \(info.generateTime, format: .fixed(precision: 3), privacy: .public)s, \(info.tokensPerSecond, format: .fixed(precision: 1), privacy: .public) tok/s")
            default:
                break
            }
        }
        return output
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
