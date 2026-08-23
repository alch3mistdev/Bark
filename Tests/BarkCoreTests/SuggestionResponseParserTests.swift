import XCTest
@testable import BarkCore

/// Parser contract (015 FR-007): 1–4 validated candidates — single-line,
/// 1–160 chars, deduplicated — or [] so the caller shows an honest error.
/// Malformed model output must never surface as an injectable candidate.
final class SuggestionResponseParserTests: XCTestCase {
    func testCleanJSONArray() {
        let raw = #"["Run the tests", "Commit and open a PR", "Refactor first"]"#
        XCTAssertEqual(SuggestionResponseParser.parse(raw),
                       ["Run the tests", "Commit and open a PR", "Refactor first"])
    }

    func testProseWrappedAndFencedJSON() {
        let raw = """
        Sure! Here are some options:
        ```json
        ["Run the tests", "Ship it"]
        ```
        Hope that helps!
        """
        XCTAssertEqual(SuggestionResponseParser.parse(raw), ["Run the tests", "Ship it"])
    }

    func testBulletSalvageWhenJSONFails() {
        let raw = """
        Here's what you could do next:
        - Run the tests and fix failures
        * Commit this and open a PR
        1. Refactor before adding more
        2) Ask for a code review
        """
        XCTAssertEqual(SuggestionResponseParser.parse(raw), [
            "Run the tests and fix failures",
            "Commit this and open a PR",
            "Refactor before adding more",
            "Ask for a code review",
        ])
    }

    func testSalvageIgnoresUnmarkedProse() {
        let raw = """
        I think you should consider several things here.
        Maybe testing would be wise.
        """
        XCTAssertEqual(SuggestionResponseParser.parse(raw), [])
    }

    func testSalvageStripsWrappingQuotes() {
        let raw = """
        - "Run the tests"
        - 'Ship it'
        """
        XCTAssertEqual(SuggestionResponseParser.parse(raw), ["Run the tests", "Ship it"])
    }

    func testDeduplicationIsCaseInsensitive() {
        let raw = #"["Run the tests", "run the tests", "Ship it"]"#
        XCTAssertEqual(SuggestionResponseParser.parse(raw), ["Run the tests", "Ship it"])
    }

    func testOverlongAndEmptyAndMultilineItemsAreDropped() {
        let long = String(repeating: "x", count: 161)
        let raw = "[\"ok\", \"\", \"  \", \"\(long)\", \"line one\\nline two\"]"
        XCTAssertEqual(SuggestionResponseParser.parse(raw), ["ok"])
    }

    func testBoundaryLengthAccepted() {
        let exact = String(repeating: "y", count: 160)
        let raw = "[\"\(exact)\"]"
        XCTAssertEqual(SuggestionResponseParser.parse(raw), [exact])
    }

    func testCapAtFourCandidates() {
        let raw = #"["a1", "b2", "c3", "d4", "e5", "f6"]"#
        XCTAssertEqual(SuggestionResponseParser.parse(raw), ["a1", "b2", "c3", "d4"])
    }

    func testZeroValidYieldsEmpty() {
        XCTAssertEqual(SuggestionResponseParser.parse(""), [])
        XCTAssertEqual(SuggestionResponseParser.parse("[]"), [])
        XCTAssertEqual(SuggestionResponseParser.parse("[1, 2, 3]"), [])   // non-strings, no salvage markers
        XCTAssertEqual(SuggestionResponseParser.parse("no list here at all"), [])
    }

    func testItemsAreTrimmed() {
        let raw = #"["  padded  ", "ok"]"#
        XCTAssertEqual(SuggestionResponseParser.parse(raw), ["padded", "ok"])
    }

    func testStripsThinkBlockBeforeArray() {
        let raw = """
        <think>The user wants options like [run tests] or something. Let me list them.</think>
        ["Run the tests", "Ship it"]
        """
        XCTAssertEqual(SuggestionResponseParser.parse(raw), ["Run the tests", "Ship it"])
    }

    func testUnterminatedThinkBlockDropsToEnd() {
        // If the array itself is inside an unterminated think span, there's
        // nothing to salvage — better empty than reasoning text as candidates.
        let raw = "<think>still reasoning about [a, b, c] and more"
        XCTAssertEqual(SuggestionResponseParser.parse(raw), [])
    }

    func testStrayBracketsAroundArrayDontBreakDecoding() {
        // Prose with an unrelated "[note]" before the real array — first-[…last-]
        // would span both and fail; balanced scan finds the real one.
        let raw = #"[note] here are ideas: ["Run the tests", "Open a PR"] hope it helps"#
        XCTAssertEqual(SuggestionResponseParser.parse(raw), ["Run the tests", "Open a PR"])
    }

    func testArrayWithBracketInsideAStringItem() {
        let raw = #"["Run tests [all]", "Ship it"]"#
        XCTAssertEqual(SuggestionResponseParser.parse(raw), ["Run tests [all]", "Ship it"])
    }
}
