import Foundation

/// Turns raw model output into validated suggestion candidates (015 FR-007).
/// Two passes: strict JSON array, then a lenient bullet/numbered-line salvage
/// for small-model JSON flubs. Hard validation either way — a candidate is a
/// single line, 1–160 chars, deduplicated, at most `maxCandidates`. Zero valid
/// candidates → `[]`, and the caller shows an honest error state; malformed
/// output must never surface as injectable text.
public enum SuggestionResponseParser {
    public static let maxCandidates = 4
    public static let maxLength = 160

    public static func parse(_ raw: String, maxCandidates: Int = SuggestionResponseParser.maxCandidates) -> [String] {
        if let items = decodeJSONArray(raw) {
            return validate(items, cap: maxCandidates)
        }
        return validate(salvageMarkedLines(raw), cap: maxCandidates)
    }

    /// First `[` … last `]` (tolerates prose/markdown fences around the array).
    private static func decodeJSONArray(_ raw: String) -> [String]? {
        guard let open = raw.firstIndex(of: "["), let close = raw.lastIndex(of: "]"), open < close else {
            return nil
        }
        let slice = String(raw[open...close])
        guard let data = slice.data(using: .utf8),
              let items = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        return items
    }

    /// Salvage ONLY marker-prefixed lines (`-`, `*`, `•`, `–`, `1.`, `1)`) so
    /// surrounding prose is never mistaken for a candidate.
    private static func salvageMarkedLines(_ raw: String) -> [String] {
        raw.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let body = stripMarker(trimmed) else { return nil }
            return stripWrappingQuotes(body)
        }
    }

    private static func stripMarker(_ line: String) -> String? {
        for bullet in ["- ", "* ", "• ", "– "] where line.hasPrefix(bullet) {
            return String(line.dropFirst(bullet.count))
        }
        // Numbered: digits then '.' or ')' then a space.
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let rest = line.dropFirst(digits.count)
        for sep in [". ", ") "] where rest.hasPrefix(sep) {
            return String(rest.dropFirst(sep.count))
        }
        return nil
    }

    private static func stripWrappingQuotes(_ s: String) -> String {
        for quote in ["\"", "'"] where s.count >= 2 && s.hasPrefix(quote) && s.hasSuffix(quote) {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    /// Shared validation: trim, single-line, 1...160 chars (reject, never
    /// truncate), case-insensitive dedupe, cap.
    private static func validate(_ items: [String], cap: Int) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in items {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed.count <= maxLength,
                  !trimmed.contains(where: \.isNewline) else { continue }
            let key = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            guard seen.insert(key).inserted else { continue }
            result.append(trimmed)
            if result.count == cap { break }
        }
        return result
    }
}
