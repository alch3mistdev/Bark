import XCTest
@testable import BarkCore

final class TextSanitizerTests: XCTestCase {
    func testStripsAnsiEscapeSequences() {
        let input = "\u{1B}[31mred\u{1B}[0m text"
        XCTAssertEqual(TextSanitizer.sanitize(input), "red text")
    }

    func testStripsC0AndDelControls() {
        let input = "a\u{07}b\u{00}c\u{7F}d"
        XCTAssertEqual(TextSanitizer.sanitize(input), "abcd")
    }

    func testStripsC1Controls() {
        let input = "a\u{0085}b\u{009F}c"
        XCTAssertEqual(TextSanitizer.sanitize(input), "abc")
    }

    func testStripsZeroWidthAndBidi() {
        let input = "a\u{200B}b\u{202E}c\u{2069}d\u{FEFF}e"
        XCTAssertEqual(TextSanitizer.sanitize(input), "abcde")
    }

    func testKeepsNewlinesWhenAllowed() {
        XCTAssertEqual(TextSanitizer.sanitize("a\nb", options: .init(stripTrailingNewlines: false)), "a\nb")
    }

    func testDropsNewlinesWhenDisallowed() {
        let opts = TextSanitizer.Options(allowNewlines: false, stripTrailingNewlines: false)
        XCTAssertEqual(TextSanitizer.sanitize("a\nb", options: opts), "ab")
    }

    func testNormalizesCRLF() {
        XCTAssertEqual(TextSanitizer.sanitize("a\r\nb", options: .init(stripTrailingNewlines: false)), "a\nb")
    }

    func testStripsTrailingNewlinesByDefault() {
        // Terminal safety: no trailing newline can be carried into a shell.
        XCTAssertEqual(TextSanitizer.sanitize("run this\n\n"), "run this")
    }

    func testTabHandling() {
        XCTAssertEqual(TextSanitizer.sanitize("a\tb"), "a\tb")
        XCTAssertEqual(TextSanitizer.sanitize("a\tb", options: .init(allowTabs: false)), "ab")
    }
}
