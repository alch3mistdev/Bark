import Foundation

/// Deterministic, always-available reply suggestions — the instant first tier,
/// analogous to `BasicTextCleaner`. No model, no network, fully testable.
///
/// Yes/no questions get exactly `Yes`/`No`. Everything else gets a small, safe
/// generic set (we can't infer specifics offline; the LLM tier does that).
public enum BasicBranchSuggester {
    public static func suggestions(for context: ConversationContext) -> [BranchOption] {
        if QuestionClassifier.isYesNoQuestion(context.lastMessage) {
            return [BranchOption("Yes"), BranchOption("No")]
        }
        return genericReplies
    }

    /// Mode-agnostic fallbacks: an affirmative, a soft decline, and an ask-for-more.
    public static let genericReplies: [BranchOption] = [
        BranchOption(label: "Yes, go ahead", payload: "Yes, go ahead."),
        BranchOption(label: "No, let's adjust", payload: "No, let's adjust."),
        BranchOption(label: "Tell me more", payload: "Can you tell me more?"),
    ]
}

/// `BasicBranchSuggester` exposed through the `BranchSuggester` protocol, for
/// call sites that want a uniform async interface. Always available.
public struct DeterministicBranchSuggester: BranchSuggester {
    public init() {}
    public var isAvailable: Bool { get async { true } }
    public func suggest(for context: ConversationContext, maxOptions: Int) async throws -> [BranchOption] {
        Array(BasicBranchSuggester.suggestions(for: context).prefix(max(0, maxOptions)))
    }
}
