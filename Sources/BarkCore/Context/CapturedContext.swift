import Foundation

/// How the on-screen context was read.
public enum ContextSource: String, Sendable, Equatable {
    case accessibility   // AX tree walk
    case ocr             // window screenshot + on-device text recognition
}

/// Ephemeral snapshot of the frontmost app's visible context (015).
///
/// PRIVACY CONTRACT (FR-005 / constitution v2.0.0 Principle I): instances live
/// in memory only — never persisted, never logged (sizes only), never written
/// to history — and are discarded when the overlay dismisses. Everything in
/// here is untrusted input and enters prompts only via `SuggestionPrompt`'s
/// fenced builders.
public struct CapturedContext: Sendable, Equatable {
    public var source: ContextSource
    public var appBundleID: String?
    public var windowTitle: String?
    public var fieldLabel: String?
    public var fieldValue: String?
    public var fieldPlaceholder: String?
    public var fieldRole: String?
    public var windowText: String

    public init(
        source: ContextSource,
        appBundleID: String?,
        windowTitle: String?,
        fieldLabel: String?,
        fieldValue: String?,
        fieldPlaceholder: String?,
        fieldRole: String?,
        windowText: String
    ) {
        self.source = source
        self.appBundleID = appBundleID
        self.windowTitle = windowTitle
        self.fieldLabel = fieldLabel
        self.fieldValue = fieldValue
        self.fieldPlaceholder = fieldPlaceholder
        self.fieldRole = fieldRole
        self.windowText = windowText
    }

    /// Below this much useful text, AX capture is considered too thin to prompt
    /// on and the caller falls back to OCR (FR-003).
    public var isThin: Bool {
        usefulCharCount < ContextBudget.thinThreshold
    }

    /// Non-whitespace characters across window text + field metadata.
    private var usefulCharCount: Int {
        [windowText, fieldValue, fieldLabel, fieldPlaceholder]
            .compactMap { $0 }
            .map { $0.filter { !$0.isWhitespace }.count }
            .reduce(0, +)
    }
}

/// Char budget + clip strategy for captured context (FR-006). A constant, not
/// a setting: 4000 chars comfortably fits the local model's context alongside
/// the prompt scaffold.
public enum ContextBudget {
    public static let maxChars = 4000
    public static let thinThreshold = 80

    public enum ClipStrategy: Sendable, Equatable {
        case head   // keep the opening text (forms, documents)
        case tail   // keep the most recent text (terminal scrollback)
    }

    /// Terminal-like targets clip from the tail — the agent's question is at
    /// the bottom of the scrollback; everything else keeps the head.
    public static func strategy(isTerminal: Bool) -> ClipStrategy {
        isTerminal ? .tail : .head
    }

    public static func clip(_ text: String, strategy: ClipStrategy, maxChars: Int = ContextBudget.maxChars) -> String {
        guard text.count > maxChars else { return text }
        switch strategy {
        case .head: return String(text.prefix(maxChars))
        case .tail: return String(text.suffix(maxChars))
        }
    }
}
