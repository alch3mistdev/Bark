import Foundation

/// Incremental companion to `SuggestionResponseParser` (016): feed raw model
/// output chunks as they stream, get back candidates the moment they are
/// individually complete and validated. Emissions are monotonic — a candidate,
/// once returned, is never retracted, reordered, or edited — and always pass
/// through the batch parser's own `validate` rulebook, so streaming can change
/// WHEN a candidate appears but never WHAT it says (016 SC-002).
///
/// Strategy: on every `consume` the full buffer is re-derived from scratch
/// (bounded by the engine's output cap, so quadratic cost is noise):
///   1. scrub think/reasoning spans exactly like the batch parser — an
///      unterminated span holds everything after it back;
///   2. find the earliest `[` that is a *prefix-valid* JSON string array and
///      take its completed string elements (decoded with `JSONDecoder`, the
///      same decoder the batch parser trusts);
///   3. only when no array start is viable anywhere, salvage marker lines that
///      are already newline-terminated;
///   4. validate, then emit the tail beyond what was already emitted — and only
///      if the fresh result still extends the emitted prefix. A divergence
///      (the model "un-writing" its format mid-stream) freezes emission until
///      `finish()`, where the batch parser has the final word.
public struct SuggestionStreamParser: Sendable {
    private var buffer = ""
    private var emitted: [String] = []
    private let cap: Int

    public init(maxCandidates: Int = SuggestionResponseParser.maxCandidates) {
        self.cap = maxCandidates
    }

    /// Candidates emitted so far (== what the caller has shown).
    public var candidates: [String] { emitted }

    /// Feed one chunk; returns only newly completed, validated candidates.
    public mutating func consume(_ chunk: String) -> [String] {
        buffer += chunk
        return emitTail(from: currentView())
    }

    /// Flush at end-of-stream. The batch parser's result for the complete
    /// buffer is authoritative: normally it extends the emitted prefix and the
    /// missing tail is returned; if a pathological stream made them diverge,
    /// shown rows stay (immutable by contract) and only batch candidates not
    /// already shown are appended, up to the cap.
    public mutating func finish() -> [String] {
        let final = SuggestionResponseParser.parse(buffer, maxCandidates: cap)
        if final.starts(with: emitted) {
            let tail = Array(final.dropFirst(emitted.count))
            emitted = final
            return tail
        }
        let seen = Set(emitted.map(Self.dedupeKey))
        var extras: [String] = []
        for item in final where !seen.contains(Self.dedupeKey(item)) {
            guard emitted.count + extras.count < cap else { break }
            extras.append(item)
        }
        emitted += extras
        return extras
    }

    // MARK: - Snapshot derivation

    private func currentView() -> [String] {
        let cleaned = SuggestionResponseParser.stripThinkBlocks(buffer)
        switch Self.viableStringArray(in: cleaned) {
        case .closed(let items):
            let validated = SuggestionResponseParser.validate(items, cap: cap)
            // Batch semantics: a decodable array that validates to nothing
            // falls through to salvage.
            if !validated.isEmpty { return validated }
            return salvageCompletedLines(cleaned)
        case .open(let items):
            return SuggestionResponseParser.validate(items, cap: cap)
        case .none:
            return salvageCompletedLines(cleaned)
        }
    }

    /// Marker-line salvage over fully newline-terminated lines only — the line
    /// still being generated must not leak as a candidate.
    private func salvageCompletedLines(_ cleaned: String) -> [String] {
        guard let lastNewline = cleaned.lastIndex(where: \.isNewline) else { return [] }
        let completed = String(cleaned[..<lastNewline])
        return SuggestionResponseParser.validate(
            SuggestionResponseParser.salvageMarkedLines(completed), cap: cap)
    }

    private mutating func emitTail(from fresh: [String]) -> [String] {
        guard fresh.starts(with: emitted) else { return [] }   // freeze on divergence
        let tail = Array(fresh.dropFirst(emitted.count))
        emitted = fresh
        return tail
    }

    /// Same key as `SuggestionResponseParser.validate`'s dedupe.
    private static func dedupeKey(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    // MARK: - Prefix-valid JSON string-array scan

    private enum ArrayScan {
        case closed([String])   // balanced `]` reached and the slice decodes as [String]
        case open([String])     // valid prefix runs to the end of the buffer; items = completed elements
        case none               // no `[` anywhere is a viable string-array start
    }

    /// Earliest `[` whose content is (so far) exclusively JSON string elements.
    /// Mirrors the batch parser's every-`[`-in-order search; grammar breaks
    /// (non-string element, bad escape) skip to the next `[` just like a failed
    /// decode does in the batch scan.
    private static func viableStringArray(in cleaned: String) -> ArrayScan {
        let chars = Array(cleaned)
        for start in chars.indices where chars[start] == "[" {
            switch scanStringArray(chars, from: start) {
            case .invalid: continue
            case .closed(let items): return .closed(items)
            case .open(let items): return .open(items)
            }
        }
        return .none
    }

    private enum ScanResult {
        case closed([String])
        case open([String])
        case invalid
    }

    private static func scanStringArray(_ chars: [Character], from start: Int) -> ScanResult {
        enum State { case expectElementOrEnd, expectElement, inString, expectCommaOrEnd }
        var state = State.expectElementOrEnd
        var escaped = false
        var elementStart = start   // index of the opening quote of the current string
        var items: [String] = []

        var i = chars.index(after: start)
        while i < chars.endIndex {
            let ch = chars[i]
            switch state {
            case .inString:
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" {
                    // Decode the finished literal with JSONDecoder itself so
                    // escape handling can't drift from the batch parser.
                    let literal = String(chars[elementStart...i])
                    guard let data = "[\(literal)]".data(using: .utf8),
                          let decoded = try? JSONDecoder().decode([String].self, from: data),
                          decoded.count == 1 else { return .invalid }
                    items.append(decoded[0])
                    state = .expectCommaOrEnd
                }
            case .expectElementOrEnd, .expectElement:
                if ch.isWhitespace { break }
                if ch == "\"" { elementStart = i; state = .inString; break }
                if ch == "]", case .expectElementOrEnd = state {
                    return closeArray(chars, start: start, end: i, fallback: items)
                }
                return .invalid
            case .expectCommaOrEnd:
                if ch.isWhitespace { break }
                if ch == "," { state = .expectElement; break }
                if ch == "]" { return closeArray(chars, start: start, end: i, fallback: items) }
                return .invalid
            }
            i = chars.index(after: i)
        }
        // Ran out of buffer while still grammatically valid: an element mid-
        // string is withheld; completed elements are safe to show.
        return .open(items)
    }

    /// Balanced close reached — let the real decoder rule on the full slice.
    private static func closeArray(_ chars: [Character], start: Int, end: Int, fallback: [String]) -> ScanResult {
        let slice = String(chars[start...end])
        guard let data = slice.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return .invalid }
        return .closed(decoded)
    }
}
