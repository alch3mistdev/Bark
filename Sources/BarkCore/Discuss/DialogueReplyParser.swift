import Foundation

/// Recovers a `DialogueReply` from raw engine output. The wire contract asks
/// for exactly `{"reply": "...", "ready": bool}`, but models wrap JSON in
/// prose, code fences, or think tags — so this parser scrubs reasoning spans,
/// then scans for the LAST object that decodes to the expected shape (the
/// system prompt itself quotes the trigger literal, so an earlier object may
/// be the model *talking about* the contract, not honoring it — ADV-009).
/// Any failure degrades to "the whole output is the reply, not ready":
/// malformed output can never force synthesis (017 FR-003 fail-safe), and the
/// synthesis trigger is honored only when the trigger object is the final
/// non-whitespace content of the (scrubbed) output.
public enum DialogueReplyParser {
    private struct Wire: Decodable {
        let reply: String
        let ready: Bool
    }

    public static func parse(_ raw: String) -> DialogueReply {
        let scrubbed = stripThinkBlocks(raw)
        let fallback = DialogueReply(
            text: scrubbed.trimmingCharacters(in: .whitespacesAndNewlines),
            isReadyToSynthesize: false
        )
        guard let (object, range) = lastDecodableObject(in: scrubbed),
              let data = object.data(using: .utf8),
              let wire = try? JSONDecoder().decode(Wire.self, from: data) else {
            return fallback
        }
        var reply = DialogueReply(text: wire.reply, isReadyToSynthesize: wire.ready)
        if reply.isSynthesisTrigger {
            // The trigger must BE the answer, not appear inside one: anything
            // after the object (beyond whitespace) demotes it to not-ready.
            let tail = scrubbed[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty {
                reply = DialogueReply(text: fallback.text, isReadyToSynthesize: false)
            }
        }
        return reply
    }

    /// Remove `<think>…</think>` / `<reasoning>…</reasoning>` spans (balanced
    /// or an unterminated leading one) — same scrub as the 015/016 parsers.
    static func stripThinkBlocks(_ raw: String) -> String {
        var s = raw
        for (open, close) in [("<think>", "</think>"), ("<reasoning>", "</reasoning>")] {
            while let o = s.range(of: open) {
                if let c = s.range(of: close, range: o.upperBound..<s.endIndex) {
                    s.removeSubrange(o.lowerBound..<c.upperBound)
                } else {
                    s.removeSubrange(o.lowerBound..<s.endIndex)
                    break
                }
            }
        }
        return s
    }

    /// The last balanced `{…}` span that decodes to the wire shape.
    static func lastDecodableObject(in s: String) -> (object: String, range: Range<String.Index>)? {
        var best: (String, Range<String.Index>)?
        for candidate in balancedObjects(in: s) {
            if let data = candidate.0.data(using: .utf8),
               (try? JSONDecoder().decode(Wire.self, from: data)) != nil {
                best = candidate
            }
        }
        return best
    }

    /// Every top-level balanced `{…}` span, brace-counted with string/escape
    /// awareness so braces inside reply text don't unbalance the scan.
    static func balancedObjects(in s: String) -> [(String, Range<String.Index>)] {
        var results: [(String, Range<String.Index>)] = []
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else {
                switch ch {
                case "\"": if depth > 0 { inString = true }
                case "{":
                    if depth == 0 { start = i }
                    depth += 1
                case "}":
                    if depth > 0 {
                        depth -= 1
                        if depth == 0, let s0 = start {
                            let range = s0..<s.index(after: i)
                            results.append((String(s[range]), range))
                            start = nil
                        }
                    }
                default: break
                }
            }
            i = s.index(after: i)
        }
        return results
    }
}
