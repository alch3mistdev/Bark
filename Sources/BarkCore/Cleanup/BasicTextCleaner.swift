import Foundation

/// Deterministic, instant transcript cleanup — no model, no network.
///
/// This is the always-available default (`Mode.clean`) and also runs as the
/// first pass before any LLM rewrite. Everything here is pure and unit-tested.
public struct BasicTextCleaner: TextCleaner {
    public init() {}

    public var isAvailable: Bool { get async { true } }

    public func clean(_ text: String, mode: Mode) async throws -> String {
        Self.process(text, mode: mode)
    }

    /// Pure entry point (also used directly by tests and the pre-LLM pass).
    public static func process(_ text: String, mode: Mode) -> String {
        var s = text

        if mode.applySpokenPunctuation {
            s = applySpokenPunctuation(s)
        }
        if mode.stripFillers {
            s = stripFillers(s)
        }
        if mode.fixSpacing {
            s = fixSpacing(s)
        }
        if mode.smartCapitalize {
            s = smartCapitalize(s)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Spoken punctuation

    /// Standalone spoken commands → symbols. Conservative: only whole tokens.
    private static let spokenPunctuation: [String: String] = [
        "period": ".", "comma": ",", "question mark": "?",
        "exclamation point": "!", "exclamation mark": "!",
        "colon": ":", "semicolon": ";", "ellipsis": "…",
        "open paren": "(", "close paren": ")",
        "open parenthesis": "(", "close parenthesis": ")",
        "hyphen": "-", "dash": "—",
    ]
    private static let spokenBreaks: [String: String] = [
        "new line": "\n", "newline": "\n",
        "new paragraph": "\n\n",
    ]

    static func applySpokenPunctuation(_ text: String) -> String {
        var s = text
        // Multi-word phrases first so "exclamation point" wins over "point".
        let ordered = (spokenBreaks.map { ($0.key, $0.value) }
            + spokenPunctuation.map { ($0.key, $0.value) })
            .sorted { $0.0.count > $1.0.count }
        for (phrase, symbol) in ordered {
            // \b<phrase>\b, case-insensitive, whole word(s).
            let pattern = "(?i)(?<![\\p{L}])" + NSRegularExpression.escapedPattern(for: phrase) + "(?![\\p{L}])"
            if let re = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(s.startIndex..., in: s)
                s = re.stringByReplacingMatches(in: s, range: range, withTemplate: symbol)
            }
        }
        return s
    }

    // MARK: - Filler removal

    /// Conservative filler set. Multi-word phrases removed only as whole tokens.
    private static let fillers: [String] = [
        "um", "uh", "erm", "uhh", "umm", "hmm", "mm", "mhm",
        "you know", "i mean", "sort of", "kind of", "like i said",
    ]

    static func stripFillers(_ text: String) -> String {
        var s = text
        for filler in fillers.sorted(by: { $0.count > $1.count }) {
            // Remove the filler plus a trailing comma/space if present.
            let pattern = "(?i)(?<![\\p{L}])" + NSRegularExpression.escapedPattern(for: filler) + "[,]?(?![\\p{L}])"
            if let re = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(s.startIndex..., in: s)
                s = re.stringByReplacingMatches(in: s, range: range, withTemplate: "")
            }
        }
        return s
    }

    // MARK: - Spacing & punctuation hygiene

    static func fixSpacing(_ text: String) -> String {
        var s = text
        // Collapse runs of spaces/tabs (but keep newlines).
        s = s.replacing(#/[ \t]+/#, with: " ")
        // No space before , . ! ? ; : % (spaces/tabs only — keep newlines).
        s = s.replacing(#/[ \t]+([,.!?;:%])/#) { match in String(match.output.1) }
        // Exactly one space after , ; : when followed by a word char.
        s = s.replacing(#/([,;:])(?=\S)/#) { match in String(match.output.1) + " " }
        // Collapse 3+ newlines to a paragraph break.
        s = s.replacing(#/\n{3,}/#, with: "\n\n")
        // Trim spaces around newlines.
        s = s.replacing(#/[ \t]*\n[ \t]*/#, with: "\n")
        return s
    }

    // MARK: - Capitalization

    static func smartCapitalize(_ text: String) -> String {
        var chars = Array(text)
        var atSentenceStart = true
        for i in chars.indices {
            let c = chars[i]
            if atSentenceStart, c.isLetter {
                let upper = String(c).uppercased()
                chars[i] = Character(upper)
                atSentenceStart = false
            } else if c == "." || c == "!" || c == "?" || c == "\n" {
                atSentenceStart = true
            } else if !c.isWhitespace {
                atSentenceStart = false
            }
        }
        var s = String(chars)
        // Standalone "i" → "I" (also fixes i'm, i'll, i've). We treat the
        // apostrophe as a boundary explicitly — Swift's Unicode `\b` would not.
        s = s.replacing(#/(^|[^\p{L}])i(?=$|[^\p{L}])/#) { match in
            String(match.output.1) + "I"
        }
        return s
    }
}
