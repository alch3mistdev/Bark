import XCTest
@testable import BarkCore

/// 016 SC-002: streaming changes WHEN a candidate appears, never WHAT it says.
/// The chunked-parity corpus is the release gate — every batch-parser fixture,
/// split at every position (and multi-split), must produce byte-identical
/// candidates through the incremental path.
final class SuggestionStreamParserTests: XCTestCase {
    /// Every fixture the batch parser is tested against, plus streaming-shaped
    /// extras. Kept in sync by construction: parity is asserted against
    /// `SuggestionResponseParser.parse` itself, not against copied expectations.
    private static let corpus: [String] = [
        #"["Run the tests", "Commit and open a PR", "Refactor first"]"#,
        "Sure! Here are some options:\n```json\n[\"Run the tests\", \"Ship it\"]\n```\nHope that helps!",
        "Here's what you could do next:\n- Run the tests and fix failures\n* Commit this and open a PR\n1. Refactor before adding more\n2) Ask for a code review",
        "I think you should consider several things here.\nMaybe testing would be wise.",
        "- \"Run the tests\"\n- 'Ship it'",
        #"["Run the tests", "run the tests", "Ship it"]"#,
        "[\"ok\", \"\", \"  \", \"\(String(repeating: "x", count: 161))\", \"line one\\nline two\"]",
        "[\"\(String(repeating: "y", count: 160))\"]",
        #"["a1", "b2", "c3", "d4", "e5", "f6"]"#,
        "",
        "[]",
        "[1, 2, 3]",
        "no list here at all",
        #"["  padded  ", "ok"]"#,
        "<think>The user wants options like [run tests] or something. Let me list them.</think>\n[\"Run the tests\", \"Ship it\"]",
        "<think>still reasoning about [a, b, c] and more",
        #"[note] here are ideas: ["Run the tests", "Open a PR"] hope it helps"#,
        #"["Run tests [all]", "Ship it"]"#,
        // Streaming-shaped extras: escapes at boundaries, nested array prose,
        // whitespace-heavy arrays, trailing marker line without newline.
        #"["Quote \" inside", "Backslash \\ too"]"#,
        "[ [\"a\", \"b\"] ]",
        "[\n  \"First choice\" ,\n  \"Second choice\"\n]",
        "- only line no trailing newline",
    ]

    private func streamed(_ raw: String, splits: [Int]) -> [String] {
        var parser = SuggestionStreamParser()
        var collected: [String] = []
        var previous = raw.startIndex
        for offset in splits.sorted() where offset > 0 && offset < raw.count {
            let cut = raw.index(raw.startIndex, offsetBy: offset)
            guard cut > previous else { continue }
            collected += parser.consume(String(raw[previous..<cut]))
            previous = cut
        }
        collected += parser.consume(String(raw[previous...]))
        collected += parser.finish()
        return collected
    }

    // MARK: - SC-002 parity

    func testEverySplitPointMatchesBatchParser() {
        for raw in Self.corpus {
            let expected = SuggestionResponseParser.parse(raw)
            for split in 0...raw.count {
                let got = streamed(raw, splits: [split])
                XCTAssertEqual(got, expected,
                               "divergence for split \(split) of: \(raw.prefix(60))")
            }
        }
    }

    func testMultiSplitChunkingMatchesBatchParser() {
        for raw in Self.corpus {
            let expected = SuggestionResponseParser.parse(raw)
            for stride in [1, 2, 3, 5, 7] {
                let splits = Array(Swift.stride(from: stride, to: raw.count, by: stride))
                XCTAssertEqual(streamed(raw, splits: splits), expected,
                               "divergence for stride \(stride) of: \(raw.prefix(60))")
            }
        }
    }

    // MARK: - Streaming-specific behavior

    func testCandidatesEmergeBeforeStreamEnds() {
        var parser = SuggestionStreamParser()
        XCTAssertEqual(parser.consume(#"["Run the tests", "#), ["Run the tests"])
        XCTAssertEqual(parser.consume(#""Ship it""#), ["Ship it"])
        XCTAssertEqual(parser.consume("]"), [])
        XCTAssertEqual(parser.finish(), [])
        XCTAssertEqual(parser.candidates, ["Run the tests", "Ship it"])
    }

    func testUnclosedStringLiteralIsWithheld() {
        var parser = SuggestionStreamParser()
        XCTAssertEqual(parser.consume(#"["Partial candi"#), [])
        XCTAssertEqual(parser.consume(#"date one"]"#), ["Partial candidate one"])
    }

    func testUnclosedThinkSpanWithholdsEverything() {
        var parser = SuggestionStreamParser()
        XCTAssertEqual(parser.consume(#"<think>maybe ["A","B"] "#), [])
        XCTAssertEqual(parser.consume("</think>[\"Real one\"]"), ["Real one"])
    }

    func testMarkerLinesEmitOnNewlineOnly() {
        var parser = SuggestionStreamParser()
        XCTAssertEqual(parser.consume("- Run the te"), [])
        XCTAssertEqual(parser.consume("sts\n- Ship"), ["Run the tests"])
        XCTAssertEqual(parser.consume(" it\n"), ["Ship it"])
        XCTAssertEqual(parser.finish(), [])
    }

    func testDedupeAppliesAcrossArrivals() {
        var parser = SuggestionStreamParser()
        XCTAssertEqual(parser.consume(#"["Same", "#), ["Same"])
        XCTAssertEqual(parser.consume(#""same", "Other"]"#), ["Other"])
    }

    func testCapStopsEmissionAtFour() {
        var parser = SuggestionStreamParser()
        let got = parser.consume(#"["a1","b2","c3","d4","e5","#)
        XCTAssertEqual(got, ["a1", "b2", "c3", "d4"])
        XCTAssertEqual(parser.consume(#""f6"]"#), [])
        XCTAssertEqual(parser.finish(), [])
        XCTAssertEqual(parser.candidates.count, 4)
    }

    func testEmittedCandidatesAreNeverRetracted() {
        // Pathological: the model starts a valid string array, then breaks it.
        // Batch parse of the final buffer yields [] — but the shown row is
        // immutable by contract, so finish() adds nothing and retracts nothing.
        var parser = SuggestionStreamParser()
        XCTAssertEqual(parser.consume(#"["Shown early", "#), ["Shown early"])
        XCTAssertEqual(parser.consume("5]"), [])
        XCTAssertEqual(parser.finish(), [])
        XCTAssertEqual(parser.candidates, ["Shown early"])
    }

    func testFinishFlushesTrailingSalvageLine() {
        var parser = SuggestionStreamParser()
        XCTAssertEqual(parser.consume("- First\n- Second"), ["First"])
        XCTAssertEqual(parser.finish(), ["Second"])
    }
}
