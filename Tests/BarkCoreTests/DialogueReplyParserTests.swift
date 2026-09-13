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

    // ADV-009 regressions: reasoning spans + object choice + trigger finality.

    func testThinkSpanQuotingTheTriggerLiteralDoesNotFire() {
        // The system prompt teaches the trigger literal; a reasoning model
        // restating it while deliberating must not end the discussion.
        let raw = #"<think>rules say emit {"reply": "", "ready": true} when confirmed — not yet</think>{"reply": "Which audience?", "ready": false}"#
        let r = DialogueReplyParser.parse(raw)
        XCTAssertEqual(r.text, "Which audience?")
        XCTAssertFalse(r.isSynthesisTrigger)
    }

    func testLastDecodableObjectWinsOverEarlierOnes() {
        let raw = #"{"reply": "draft A", "ready": false} …reconsidering… {"reply": "Which tone?", "ready": false}"#
        XCTAssertEqual(DialogueReplyParser.parse(raw).text, "Which tone?")
    }

    func testTriggerObjectMustBeFinalContent() {
        // A trigger-shaped object followed by more prose is the model talking,
        // not answering — demote to not-ready.
        let raw = #"{"reply": "", "ready": true} …but actually let me ask one more thing."#
        let r = DialogueReplyParser.parse(raw)
        XCTAssertFalse(r.isReadyToSynthesize)
        // The trigger as the actual final content still fires.
        XCTAssertTrue(DialogueReplyParser.parse(#"Okay. {"reply": "", "ready": true}"#).isSynthesisTrigger)
    }

    func testUnterminatedThinkBlockFallsBackSafely() {
        let r = DialogueReplyParser.parse(#"<think>endless deliberation {"reply": "", "ready": true}"#)
        XCTAssertFalse(r.isReadyToSynthesize)
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
