import Foundation

/// Removes characters that are dangerous or meaningless to inject into another
/// app: terminal escape sequences, C0/C1 control codes, zero-width and
/// bidirectional-override characters. Applied to every transcript and to every
/// LLM cleanup result before injection (security findings SEC-005/SEC-011, T-006/T-014).
public enum TextSanitizer {
    public struct Options: Sendable {
        public var allowNewlines: Bool
        public var allowTabs: Bool
        /// Strip trailing newlines so we never submit a line to a shell/terminal
        /// (we also never synthesize Return — defense in depth, T-006/SEC-005).
        public var stripTrailingNewlines: Bool

        public init(allowNewlines: Bool = true, allowTabs: Bool = true, stripTrailingNewlines: Bool = true) {
            self.allowNewlines = allowNewlines
            self.allowTabs = allowTabs
            self.stripTrailingNewlines = stripTrailingNewlines
        }

        public static let `default` = Options()
    }

    private static let zeroWidthAndBidi: Set<Unicode.Scalar> = [
        "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}", // zero-width
        "\u{200E}", "\u{200F}",                                       // LRM / RLM
        "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",   // bidi embeddings/overrides
        "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",               // bidi isolates
    ]

    public static func sanitize(_ input: String, options: Options = .default) -> String {
        // 1. Strip terminal/ANSI escape sequences first; normalize CRLF → LF.
        // ESC [ ... <final byte> (CSI) and a couple of other escape introducers.
        var s = input.replacing(#/\x1B(?:\[[0-?]*[ -/]*[@-~]|[PX^_].*?\x1B\\|.)/#, with: "")
        s = s.replacingOccurrences(of: "\r\n", with: "\n")

        // 2. Filter control + zero-width + bidi scalars.
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(s.unicodeScalars.count)
        for u in s.unicodeScalars {
            if zeroWidthAndBidi.contains(u) { continue }
            switch u.value {
            case 0x09: // tab
                if options.allowTabs { scalars.append(u) }
            case 0x0A, 0x0D: // LF / CR
                if options.allowNewlines { scalars.append("\n") } // normalize CR -> LF
            case 0x00...0x1F, 0x7F:        // other C0 + DEL
                continue
            case 0x80...0x9F:              // C1 controls
                continue
            default:
                scalars.append(u)
            }
        }
        s = String(scalars)

        // 3. Optionally strip trailing newlines (terminal safety).
        if options.stripTrailingNewlines {
            while s.hasSuffix("\n") { s.removeLast() }
        }
        return s
    }
}
