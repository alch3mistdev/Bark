import XCTest
@testable import BarkCore

/// Pure state machine for one suggestion pass (015, streaming events in 016).
/// Legal-transition table mirrors DictationStateMachine's style:
/// `dismiss`/`errored` are safety valves.
final class SuggestionSessionTests: XCTestCase {
    /// Drive a fresh session to `.presenting` with the given candidates.
    private func presenting(_ candidates: [String]) -> SuggestionSession {
        var s = SuggestionSession()
        s.handle(.hotkeyPressed)
        s.handle(.contextCaptured)
        candidates.forEach { s.handle(.candidateArrived($0)) }
        return s
    }

    func testHappyPathToInjection() {
        var s = SuggestionSession()
        XCTAssertEqual(s.phase, .idle)
        XCTAssertTrue(s.handle(.hotkeyPressed))
        XCTAssertEqual(s.phase, .capturing)
        XCTAssertTrue(s.handle(.contextCaptured))
        XCTAssertEqual(s.phase, .generating)
        XCTAssertTrue(s.isStreaming)
        XCTAssertTrue(s.handle(.candidateArrived("a")))
        XCTAssertEqual(s.phase, .presenting)     // first candidate presents immediately (016)
        XCTAssertTrue(s.handle(.candidateArrived("b")))
        XCTAssertTrue(s.handle(.candidateArrived("c")))
        XCTAssertEqual(s.candidates, ["a", "b", "c"])
        XCTAssertEqual(s.highlightedIndex, 0)
        XCTAssertTrue(s.isStreaming)
        XCTAssertTrue(s.handle(.generationFinished))
        XCTAssertFalse(s.isStreaming)
        XCTAssertTrue(s.handle(.choose(1)))
        XCTAssertEqual(s.phase, .injecting)
        XCTAssertEqual(s.chosenIndex, 1)
        XCTAssertTrue(s.handle(.injected))
        XCTAssertEqual(s.phase, .idle)
        XCTAssertTrue(s.candidates.isEmpty)
    }

    func testCandidatesAppendInArrivalOrderAndNeverReorder() {
        var s = presenting(["first"])
        XCTAssertEqual(s.candidates, ["first"])
        s.handle(.candidateArrived("second"))
        s.handle(.candidateArrived("third"))
        XCTAssertEqual(s.candidates, ["first", "second", "third"])   // stable numbering
    }

    func testOtherPathToDictation() {
        var s = presenting(["a", "b"])
        XCTAssertTrue(s.handle(.chooseOther))
        XCTAssertEqual(s.phase, .dictating)
        XCTAssertFalse(s.isStreaming)
        XCTAssertTrue(s.handle(.dictationFinished))
        XCTAssertEqual(s.phase, .idle)
    }

    func testChooseOtherLegalWhileGeneratingBeforeFirstCandidate() {
        // 016 FR-012: the Other… escape hatch works before any candidate exists.
        var s = SuggestionSession()
        s.handle(.hotkeyPressed)
        s.handle(.contextCaptured)
        XCTAssertEqual(s.phase, .generating)
        XCTAssertTrue(s.handle(.chooseOther))
        XCTAssertEqual(s.phase, .dictating)

        var t = SuggestionSession()
        t.handle(.hotkeyPressed)
        t.handle(.contextCaptured)
        XCTAssertTrue(t.handle(.acceptHighlighted))   // Return: only row is Other…
        XCTAssertEqual(t.phase, .dictating)
    }

    func testHighlightOnOtherTracksOtherAcrossAppends() {
        var s = presenting(["a"])
        s.handle(.moveHighlight(1))                       // onto Other (index 1)
        XCTAssertEqual(s.highlightedIndex, s.otherRowIndex)
        s.handle(.candidateArrived("b"))
        XCTAssertEqual(s.highlightedIndex, s.otherRowIndex)   // still Other (now 2)
        XCTAssertEqual(s.highlightedIndex, 2)

        var t = presenting(["a", "b"])
        t.handle(.moveHighlight(1))                       // onto candidate "b"
        t.handle(.candidateArrived("c"))
        XCTAssertEqual(t.highlightedIndex, 1)             // candidate highlight untouched
    }

    func testGenerationFinishedIllegalWithZeroCandidates() {
        var s = SuggestionSession()
        s.handle(.hotkeyPressed)
        s.handle(.contextCaptured)
        XCTAssertFalse(s.handle(.generationFinished))
        XCTAssertEqual(s.phase, .generating)   // caller must route to .errored instead
    }

    func testEmptyCandidateIsIllegal() {
        var s = SuggestionSession()
        s.handle(.hotkeyPressed)
        s.handle(.contextCaptured)
        XCTAssertFalse(s.handle(.candidateArrived("")))
        XCTAssertEqual(s.phase, .generating)
    }

    func testIllegalTransitionsAreIgnored() {
        var s = SuggestionSession()
        XCTAssertFalse(s.handle(.contextCaptured))          // idle can't capture
        XCTAssertFalse(s.handle(.choose(0)))                // nothing to choose
        XCTAssertFalse(s.handle(.injected))
        XCTAssertEqual(s.phase, .idle)

        s.handle(.hotkeyPressed)
        XCTAssertFalse(s.handle(.hotkeyPressed))            // already running
        XCTAssertFalse(s.handle(.candidateArrived("a")))    // must capture first
        XCTAssertEqual(s.phase, .capturing)
    }

    func testChooseOutOfRangeIsIgnored() {
        var s = presenting(["a", "b"])
        XCTAssertFalse(s.handle(.choose(2)))
        XCTAssertFalse(s.handle(.choose(-1)))
        XCTAssertEqual(s.phase, .presenting)
    }

    func testHighlightMovesAndClampsAcrossCandidatesPlusOther() {
        var s = presenting(["a", "b", "c"])
        // Highlight domain is 0...count (last index = the Other row).
        XCTAssertTrue(s.handle(.moveHighlight(-1)))
        XCTAssertEqual(s.highlightedIndex, 0)               // clamped at top
        s.handle(.moveHighlight(1)); s.handle(.moveHighlight(1)); s.handle(.moveHighlight(1))
        XCTAssertEqual(s.highlightedIndex, 3)               // the Other row
        XCTAssertTrue(s.handle(.moveHighlight(1)))
        XCTAssertEqual(s.highlightedIndex, 3)               // clamped at Other
        XCTAssertEqual(s.otherRowIndex, 3)
    }

    func testAcceptHighlightedResolvesToChooseOrOther() {
        var s = presenting(["a", "b"])
        s.handle(.moveHighlight(1))
        XCTAssertTrue(s.handle(.acceptHighlighted))
        XCTAssertEqual(s.phase, .injecting)
        XCTAssertEqual(s.chosenIndex, 1)

        var t = presenting(["a", "b"])
        t.handle(.moveHighlight(1)); t.handle(.moveHighlight(1))   // onto Other
        XCTAssertTrue(t.handle(.acceptHighlighted))
        XCTAssertEqual(t.phase, .dictating)
    }

    func testDismissFromAnyStateResetsToIdle() {
        for events in [
            [SuggestionEvent.hotkeyPressed],
            [.hotkeyPressed, .contextCaptured],
            [.hotkeyPressed, .contextCaptured, .candidateArrived("a")],
            [.hotkeyPressed, .contextCaptured, .candidateArrived("a"), .choose(0)],
        ] {
            var s = SuggestionSession()
            events.forEach { s.handle($0) }
            XCTAssertTrue(s.handle(.dismiss))
            XCTAssertEqual(s.phase, .idle)
            XCTAssertTrue(s.candidates.isEmpty)
            XCTAssertNil(s.chosenIndex)
            XCTAssertFalse(s.isStreaming)
        }
    }

    func testErroredFromAnyStateThenDismissRecovers() {
        var s = SuggestionSession()
        s.handle(.hotkeyPressed)
        XCTAssertTrue(s.handle(.errored("no context")))
        XCTAssertEqual(s.phase, .failed("no context"))
        XCTAssertFalse(s.isStreaming)
        XCTAssertTrue(s.handle(.dismiss))
        XCTAssertEqual(s.phase, .idle)
    }

    func testIsActive() {
        var s = SuggestionSession()
        XCTAssertFalse(s.isActive)
        s.handle(.hotkeyPressed)
        XCTAssertTrue(s.isActive)
        s.handle(.errored("x"))
        XCTAssertFalse(s.isActive)
    }
}
