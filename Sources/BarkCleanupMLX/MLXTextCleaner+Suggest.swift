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
        guard let container else { throw SuggestionError.engineUnavailable }
        let session = ChatSession(
            container,
            instructions: request.system,
            generateParameters: GenerateParameters(maxTokens: Self.suggestMaxTokens, temperature: 0)
        )
        var output = ""
        for try await item in session.streamDetails(to: request.user, images: [], videos: []) {
            switch item {
            case .chunk(let piece):
                output += piece
                if output.count > Self.suggestOutputCharBound {
                    return output   // enough for the parser; cancels generation via stream teardown
                }
            case .info(let info):
                BarkLog.cleanup.info("llm suggest: prompt \(info.promptTime, format: .fixed(precision: 3), privacy: .public)s, generate \(info.generateTime, format: .fixed(precision: 3), privacy: .public)s, \(info.tokensPerSecond, format: .fixed(precision: 1), privacy: .public) tok/s")
            default:
                break
            }
        }
        return output
    }
}

#else

/// Lean build: the local suggestion engine is absent; `SuggestionController`
/// degrades to the external backend or an honest unavailable state (SC-005).
extension MLXTextCleaner: SuggestionEngine {
    public func suggest(_ request: SuggestionRequest) async throws -> String {
        throw SuggestionError.engineUnavailable
    }
}

#endif
