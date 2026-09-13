import Foundation

/// Recovers a `DialogueReply` from raw engine output. The wire contract asks
/// for exactly `{"reply": "...", "ready": bool}`, but models wrap JSON in
/// prose, code fences, or think tags — so this parser scans for the first
/// object that decodes to the expected shape. Any failure degrades to
/// "the whole output is the reply, not ready": malformed output can never
/// force synthesis (017 FR-003 fail-safe direction).
public enum DialogueReplyParser {
    private struct Wire: Decodable {
        let reply: String
        let ready: Bool
    }

    public static func parse(_ raw: String) -> DialogueReply {
        let fallback = DialogueReply(
            text: raw.trimmingCharacters(in: .whitespacesAndNewlines),
            isReadyToSynthesize: false
        )
        guard let object = firstJSONObject(in: raw),
              let data = object.data(using: .utf8),
              let wire = try? JSONDecoder().decode(Wire.self, from: data) else {
            return fallback
        }
        return DialogueReply(text: wire.reply, isReadyToSynthesize: wire.ready)
    }

    /// The first balanced `{…}` span, brace-counted with string/escape
    /// awareness so braces inside the reply text don't unbalance the scan.
    static func firstJSONObject(in s: String) -> String? {
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
                case "\"": inString = true
                case "{":
                    if depth == 0 { start = i }
                    depth += 1
                case "}":
                    if depth > 0 {
                        depth -= 1
                        if depth == 0, let start {
                            return String(s[start...i])
                        }
                    }
                default: break
                }
            }
            i = s.index(after: i)
        }
        return nil
    }
}
