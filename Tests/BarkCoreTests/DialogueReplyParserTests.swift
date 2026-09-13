import XCTest
@testable import BarkCore

final class DialogueReplyParserTests: XCTestCase {
    func testPlainJSONParses() {
        let r = DialogueReplyParser.parse(#"{"reply": "What outcome do you want?", "ready": false}"#)
        XCTAssertEqual(r.text, "What outcome do you want?")
        XCTAssertFalse(r.isReadyToSynthesize)
        XCTAssertFalse(r.isSynthesisTrigger)
    }

    func testReadyQuestionIsNotATrigger() {
        let r = DialogueReplyParser.parse(#"{"reply": "Ready for me to draft it?", "ready": true}"#)
        XCTAssertTrue(r.isReadyToSynthesize)
        XCTAssertFalse(r.isSynthesisTrigger)   // non-empty reply only highlights Done
    }

    func testEmptyReplyWithReadyIsTheSynthesisTrigger() {
        let r = DialogueReplyParser.parse(#"{"reply": "", "ready": true}"#)
        XCTAssertTrue(r.isSynthesisTrigger)
        // Whitespace-only counts as empty too.
        XCTAssertTrue(DialogueReplyParser.parse(#"{"reply": "  \n", "ready": true}"#).isSynthesisTrigger)
    }

    func testFencedAndProseWrappedJSONParses() {
        let fenced = """
        Sure, here you go:
        ```json
        {"reply": "Which audience?", "ready": false}
        ```
        """
        XCTAssertEqual(DialogueReplyParser.parse(fenced).text, "Which audience?")

        let prose = #"I think {"reply": "Any deadline?", "ready": false} covers it."#
        XCTAssertEqual(DialogueReplyParser.parse(prose).text, "Any deadline?")
    }

    func testBracesInsideReplyStringDoNotBreakScan() {
        let raw = #"{"reply": "Use {curly} braces, or a } stray one?", "ready": false}"#
        XCTAssertEqual(DialogueReplyParser.parse(raw).text, "Use {curly} braces, or a } stray one?")
    }

    func testGarbageFallsBackToFullTextNotReady() {
        let r = DialogueReplyParser.parse("  just plain prose, no JSON at all  ")
        XCTAssertEqual(r.text, "just plain prose, no JSON at all")
        XCTAssertFalse(r.isReadyToSynthesize)
    }

    func testWrongShapeJSONFallsBack() {
        // First JSON object decodes but lacks the contract keys → fallback.
        let r = DialogueReplyParser.parse(#"{"question": "hm?"} trailing"#)
        XCTAssertFalse(r.isReadyToSynthesize)
        XCTAssertTrue(r.text.contains("question"))
    }

    func testMalformedOutputCanNeverTriggerSynthesis() {
        // FR-003 fail-safe: even output that *claims* readiness in prose or in
        // broken JSON must not become a trigger.
        for raw in [
            "READY. Drafting now.",
            #"{"reply": "", "ready": "yes"}"#,     // wrong type
            #"{"reply": "", "ready": true"#,       // unbalanced → no object found
            "",
        ] {
            XCTAssertFalse(DialogueReplyParser.parse(raw).isSynthesisTrigger, "raw: \(raw)")
        }
    }
}
