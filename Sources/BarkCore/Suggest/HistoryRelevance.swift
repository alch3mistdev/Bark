import Foundation

/// Picks history snippets relevant to the captured context (015 FR-015) so
/// suggestions can reflect the user's own past dictations (e.g. an address for
/// an "Address" field). Pure: records in, clipped snippet strings out. Only
/// record OUTPUTS are surfaced — captured screen context never enters history.
public enum HistoryRelevance {
    public static let maxSnippets = 3
    public static let snippetLength = 120
    public static let maxKeywords = 6

    static let stopwords: Set<String> = [
        "the", "and", "for", "you", "your", "please", "enter", "this", "that",
        "with", "from", "what", "should", "would", "could", "here", "there",
        "have", "has", "are", "was", "were", "will", "can", "not", "now",
        "next", "into", "about", "them", "then", "their", "our", "its",
    ]

    /// Keywords from the focused field's label (highest signal, kept first)
    /// plus the context tail: lowercased, alphanumeric-tokenized, stopwords and
    /// short tokens dropped, deduplicated, capped.
    public static func keywords(fieldLabel: String?, contextTail: String, max: Int = maxKeywords) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for token in tokenize(fieldLabel ?? "") + tokenize(contextTail) {
            guard token.count >= 3, !stopwords.contains(token), seen.insert(token).inserted else { continue }
            result.append(token)
            if result.count == max { break }
        }
        return result
    }

    /// Score each record's output by keyword overlap (case-insensitive),
    /// tie-break by recency; only overlapping records qualify. Top-N outputs,
    /// clipped from the head to `snippetLength`.
    public static func snippets(from records: [HistoryRecord], keywords: [String]) -> [String] {
        guard !keywords.isEmpty else { return [] }
        return records
            .map { record -> (score: Int, record: HistoryRecord) in
                let haystack = record.output.lowercased()
                let score = keywords.filter { haystack.contains($0) }.count
                return (score, record)
            }
            .filter { $0.score > 0 }
            .sorted { ($0.score, $0.record.createdAt) > ($1.score, $1.record.createdAt) }
            .prefix(maxSnippets)
            .map { String($0.record.output.prefix(snippetLength)) }
    }

    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
