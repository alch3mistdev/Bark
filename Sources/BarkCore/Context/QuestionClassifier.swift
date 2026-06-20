import Foundation

/// Pure heuristics over read context. Deliberately conservative: we'd rather
/// miss a yes/no question (and fall back to generic replies) than offer Yes/No
/// for something that isn't a yes/no question.
public enum QuestionClassifier {
    /// Auxiliary/modal verbs that begin a yes/no (polar) question in English.
    private static let leadingAuxiliaries: Set<String> = [
        "is", "are", "was", "were", "am",
        "do", "does", "did",
        "have", "has", "had",
        "can", "could", "should", "would", "will", "shall", "may", "might", "must",
    ]

    /// Phrasings that signal an explicit yes/no choice even without a leading aux.
    private static let yesNoMarkers: [String] = [
        "yes or no", "y/n", "yes/no", "should i", "shall i", "do you want",
        "would you like", "are you sure", "ok to", "okay to", "confirm",
        "want me",
    ]

    /// True when `text`'s last sentence reads like a yes/no question.
    public static func isYesNoQuestion(_ text: String) -> Bool {
        let sentence = lastSentence(in: text)
        guard !sentence.isEmpty else { return false }
        let lower = sentence.lowercased()

        // Must look like a question: end with "?" or contain an explicit marker.
        let endsWithQuestion = sentence.hasSuffix("?")
        let hasMarker = yesNoMarkers.contains { lower.contains($0) }
        guard endsWithQuestion || hasMarker else { return false }
        if hasMarker { return true }

        // A "?"-terminated sentence is yes/no only if it opens with an auxiliary.
        // "What time is it?" opens with "what" → not yes/no.
        guard let first = firstWord(of: lower) else { return false }
        return leadingAuxiliaries.contains(first)
    }

    /// The last non-empty sentence (split on . ! ? and newlines), trimmed.
    static func lastSentence(in text: String) -> String {
        let separators = CharacterSet(charactersIn: ".!\n\r") // keep '?' so suffix check works
        // Replace separators (except '?') with a marker, then split.
        var working = ""
        for scalar in text.unicodeScalars {
            working.unicodeScalars.append(separators.contains(scalar) ? "\u{1}" : scalar)
        }
        let parts = working.split(separator: "\u{1}", omittingEmptySubsequences: true)
        guard let last = parts.last else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return last.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstWord(of lower: String) -> String? {
        lower.split(whereSeparator: { !$0.isLetter && $0 != "'" }).first.map(String.init)
    }
}
