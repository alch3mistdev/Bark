import XCTest
@testable import BarkCore

/// Pure draft/undo/append logic for hold-to-refine (012).
/// Mirrors the behavior table in contracts/refine-session.md.
final class RefineSessionTests: XCTestCase {
    func testAppendSeedsBaseDraft() {
        var s = RefineSession()
        s.appendDictation("Hello my name is foo")
        XCTAssertEqual(s.draft, "Hello my name is foo")
        XCTAssertTrue(s.snapshots.isEmpty)
        XCTAssertFalse(s.canUndo)
    }

    func testApplyRefinePushesSnapshotAndSwaps() {
        var s = RefineSession()
        s.appendDictation("Hello my name is foo")
        s.applyRefine(rewrite: "Hello my name is bar")
        XCTAssertEqual(s.snapshots, ["Hello my name is foo"])
        XCTAssertEqual(s.draft, "Hello my name is bar")
        XCTAssertEqual(s.context, .dictation)
    }

    func testChainedRefineAndRepeatableUndo() {
        var s = RefineSession()
        s.appendDictation("Hello my name is foo")
        s.applyRefine(rewrite: "Hello my name is bar")
        s.applyRefine(rewrite: "Greetings, I am bar")
        XCTAssertEqual(s.snapshots, ["Hello my name is foo", "Hello my name is bar"])
        XCTAssertEqual(s.draft, "Greetings, I am bar")

        s.undo()
        XCTAssertEqual(s.draft, "Hello my name is bar")
        XCTAssertEqual(s.snapshots, ["Hello my name is foo"])

        s.undo()
        XCTAssertEqual(s.draft, "Hello my name is foo")
        XCTAssertTrue(s.snapshots.isEmpty)
    }

    func testUndoAtBaseIsNoOp() {
        var s = RefineSession()
        s.appendDictation("base")
        s.undo()   // nothing to undo
        XCTAssertEqual(s.draft, "base")
        XCTAssertFalse(s.canUndo)
        XCTAssertEqual(s.context, .dictation)
    }

    func testKeepOnFailurePreservesDraftNoSnapshot() {
        var s = RefineSession()
        s.appendDictation("X")
        s.beginInstruction()
        s.keepOnFailure()
        XCTAssertEqual(s.draft, "X")
        XCTAssertTrue(s.snapshots.isEmpty)
        XCTAssertEqual(s.context, .dictation)
    }

    func testAppendSpaceJoinsAndTrims() {
        var s = RefineSession()
        s.appendDictation("base")
        s.appendDictation("  second point  ")
        XCTAssertEqual(s.draft, "base second point")
    }

    func testEmptyAppendIsNoOp() {
        var s = RefineSession()
        s.appendDictation("base")
        s.appendDictation("   ")
        XCTAssertEqual(s.draft, "base")
    }

    func testBeginInstructionOnlyChangesContext() {
        var s = RefineSession()
        s.appendDictation("base")
        s.beginInstruction()
        XCTAssertEqual(s.context, .instruction)
        XCTAssertEqual(s.draft, "base")
        XCTAssertTrue(s.snapshots.isEmpty)
    }
}
