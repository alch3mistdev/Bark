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
        // Strip reasoning-model scaffolding (Qwen3 <think>…</think>, etc.) so a
        // stray bracket inside it can't corrupt array detection.
        let cleaned = stripThinkBlocks(raw)
        if let items = decodeJSONArray(cleaned) {
            let validated = validate(items, cap: maxCandidates)
            if !validated.isEmpty { return validated }
        }
        return validate(salvageMarkedLines(cleaned), cap: maxCandidates)
    }

    /// Remove `<think>…</think>` / `<reasoning>…</reasoning>` spans (balanced or
    /// an unterminated leading one) that reasoning models emit before the answer.
    /// Internal: `SuggestionStreamParser` (016) applies the same scrub so held-back
    /// reasoning text can never leak a candidate.
    static func stripThinkBlocks(_ raw: String) -> String {
        var s = raw
        for (open, close) in [("<think>", "</think>"), ("<reasoning>", "</reasoning>")] {
            while let o = s.range(of: open) {
                if let c = s.range(of: close, range: o.upperBound..<s.endIndex) {
                    s.removeSubrange(o.lowerBound..<c.upperBound)
                } else {
                    s.removeSubrange(o.lowerBound..<s.endIndex)   // unterminated — drop to the end
                    break
                }
            }
        }
        return s
    }

    /// Find a decodable `[String]` by scanning every `[` and matching it to its
    /// balanced `]` (quote/escape aware). More robust than first-`[`…last-`]`,
    /// which fails when prose contains stray brackets around the real array.
    private static func decodeJSONArray(_ raw: String) -> [String]? {
        let chars = Array(raw)
        for start in chars.indices where chars[start] == "[" {
            var depth = 0, inString = false, escaped = false
            for i in start..<chars.count {
                let ch = chars[i]
                if escaped { escaped = false; continue }
                if inString {
                    if ch == "\\" { escaped = true }
                    else if ch == "\"" { inString = false }
                    continue
                }
                switch ch {
                case "\"": inString = true
                case "[": depth += 1
                case "]":
                    depth -= 1
                    if depth == 0 {
                        let slice = String(chars[start...i])
                        if let data = slice.data(using: .utf8),
                           let items = try? JSONDecoder().decode([String].self, from: data) {
                            return items
                        }
                    }
                default: break
                }
            }
        }
        return nil
    }

    /// Salvage ONLY marker-prefixed lines (`-`, `*`, `•`, `–`, `1.`, `1)`) so
    /// surrounding prose is never mistaken for a candidate. Internal for the
    /// stream parser (016) — one salvage rulebook.
    static func salvageMarkedLines(_ raw: String) -> [String] {
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
    /// truncate), case-insensitive dedupe, cap. Internal: the ONE rulebook —
    /// `SuggestionStreamParser` (016) validates through this same function so
    /// streaming can never show a candidate the batch parser would reject.
    static func validate(_ items: [String], cap: Int) -> [String] {
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
