import Foundation
import BarkCore

#if MLXCleanup
import MLX
import MLXLLM
import MLXLMCommon

/// 015: suggestion generation rides the SAME loaded `ModelContainer` as the
/// cleanup rewrite — one ~2.5 GB residency serves both, and the existing
/// warm/idle-unload lifecycle (DictationController) applies unchanged (R2).
/// Fresh, stateless `ChatSession` per call; the prompt arrives pre-fenced from
/// `SuggestionPrompt` and the RAW output goes back to the caller for
/// `SuggestionResponseParser` validation — nothing here is injectable text.
extension MLXTextCleaner: SuggestionEngine {
    /// 4 candidates × 160 chars + JSON punctuation, with headroom. Past this
    /// the parser would drop the tail anyway, so stop generating (same
    /// early-abort idea as `collect`'s growth bound).
    static let suggestOutputCharBound = 1600
    static let suggestMaxTokens = 256

    public func suggest(_ request: SuggestionRequest) async throws -> String {
        var output = ""
        for try await chunk in suggestStream(request) { output += chunk }
        return output
    }

    /// Native streaming (016): the model already produces chunks — hand each
    /// one to the consumer instead of discarding the increments. `suggest`
    /// consumes this same stream, so concatenated chunks equal its return
    /// value by construction.
    public nonisolated func suggestStream(_ request: SuggestionRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.streamRaw(request, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamRaw(_ request: SuggestionRequest,
                           into continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        guard let container else { throw SuggestionError.engineUnavailable }
        let session = ChatSession(
            container,
            instructions: request.system,
            generateParameters: GenerateParameters(maxTokens: Self.suggestMaxTokens, temperature: 0)
        )
        var total = 0
        for try await item in session.streamDetails(to: request.user, images: [], videos: []) {
            try Task.checkCancellation()
            switch item {
            case .chunk(let piece):
                continuation.yield(piece)
                total += piece.count
                if total > Self.suggestOutputCharBound {
                    return   // enough for the parser; cancels generation via stream teardown
                }
            case .info(let info):
                BarkLog.cleanup.info("llm suggest: prompt \(info.promptTime, format: .fixed(precision: 3), privacy: .public)s, generate \(info.generateTime, format: .fixed(precision: 3), privacy: .public)s, \(info.tokensPerSecond, format: .fixed(precision: 1), privacy: .public) tok/s")
            default:
                break
            }
        }
    }
}

#else

/// Lean build: the local suggestion engine is absent; `SuggestionController`
/// degrades to the external backend or an honest unavailable state (SC-005).
/// `prepare`/`unload` are written out because BOTH protocols supply defaults —
/// without explicit witnesses the two extension defaults are ambiguous and
/// neither conformance can be satisfied.
extension MLXTextCleaner: SuggestionEngine {
    public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {}

    public func unload() async {}

    public func suggest(_ request: SuggestionRequest) async throws -> String {
        throw SuggestionError.engineUnavailable
    }
}

#endif
