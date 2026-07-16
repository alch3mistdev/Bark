import XCTest
@testable import BarkCore

/// Pure state machine for one suggestion pass (015). Legal-transition table
/// mirrors DictationStateMachine's style: `dismiss`/`errored` are safety valves.
final class SuggestionSessionTests: XCTestCase {
    func testHappyPathToInjection() {
        var s = SuggestionSession()
        XCTAssertEqual(s.phase, .idle)
        XCTAssertTrue(s.handle(.hotkeyPressed))
        XCTAssertEqual(s.phase, .capturing)
        XCTAssertTrue(s.handle(.contextCaptured))
        XCTAssertEqual(s.phase, .generating)
        XCTAssertTrue(s.handle(.candidatesReady(["a", "b", "c"])))
        XCTAssertEqual(s.phase, .presenting)
        XCTAssertEqual(s.candidates, ["a", "b", "c"])
        XCTAssertEqual(s.highlightedIndex, 0)
        XCTAssertTrue(s.handle(.choose(1)))
        XCTAssertEqual(s.phase, .injecting)
        XCTAssertEqual(s.chosenIndex, 1)
        XCTAssertTrue(s.handle(.injected))
        XCTAssertEqual(s.phase, .idle)
        XCTAssertTrue(s.candidates.isEmpty)
    }

    func testOtherPathToDictation() {
        var s = SuggestionSession()
        s.handle(.hotkeyPressed)
        s.handle(.contextCaptured)
        s.handle(.candidatesReady(["a", "b"]))
        XCTAssertTrue(s.handle(.chooseOther))
        XCTAssertEqual(s.phase, .dictating)
        XCTAssertTrue(s.handle(.dictationFinished))
        XCTAssertEqual(s.phase, .idle)
    }

    func testIllegalTransitionsAreIgnored() {
        var s = SuggestionSession()
        XCTAssertFalse(s.handle(.contextCaptured))          // idle can't capture
        XCTAssertFalse(s.handle(.choose(0)))                // nothing to choose
        XCTAssertFalse(s.handle(.injected))
        XCTAssertEqual(s.phase, .idle)

        s.handle(.hotkeyPressed)
        XCTAssertFalse(s.handle(.hotkeyPressed))            // already running
        XCTAssertFalse(s.handle(.candidatesReady(["a"])))   // must capture first
        XCTAssertEqual(s.phase, .capturing)
    }

    func testEmptyCandidateListIsIllegal() {
        var s = SuggestionSession()
        s.handle(.hotkeyPressed)
        s.handle(.contextCaptured)
        XCTAssertFalse(s.handle(.candidatesReady([])))
        XCTAssertEqual(s.phase, .generating)   // caller must route to .errored instead
    }

    func testChooseOutOfRangeIsIgnored() {
        var s = SuggestionSession()
        s.handle(.hotkeyPressed)
        s.handle(.contextCaptured)
        s.handle(.candidatesReady(["a", "b"]))
        XCTAssertFalse(s.handle(.choose(2)))
        XCTAssertFalse(s.handle(.choose(-1)))
        XCTAssertEqual(s.phase, .presenting)
    }

    func testHighlightMovesAndClampsAcrossCandidatesPlusOther() {
        var s = SuggestionSession()
        s.handle(.hotkeyPressed)
        s.handle(.contextCaptured)
        s.handle(.candidatesReady(["a", "b", "c"]))
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
        var s = SuggestionSession()
        s.handle(.hotkeyPressed)
        s.handle(.contextCaptured)
        s.handle(.candidatesReady(["a", "b"]))
        s.handle(.moveHighlight(1))
        XCTAssertTrue(s.handle(.acceptHighlighted))
        XCTAssertEqual(s.phase, .injecting)
        XCTAssertEqual(s.chosenIndex, 1)

        var t = SuggestionSession()
        t.handle(.hotkeyPressed)
        t.handle(.contextCaptured)
        t.handle(.candidatesReady(["a", "b"]))
        t.handle(.moveHighlight(1)); t.handle(.moveHighlight(1))   // onto Other
        XCTAssertTrue(t.handle(.acceptHighlighted))
        XCTAssertEqual(t.phase, .dictating)
    }

    func testDismissFromAnyStateResetsToIdle() {
        for events in [
            [SuggestionEvent.hotkeyPressed],
            [.hotkeyPressed, .contextCaptured],
            [.hotkeyPressed, .contextCaptured, .candidatesReady(["a"])],
            [.hotkeyPressed, .contextCaptured, .candidatesReady(["a"]), .choose(0)],
        ] {
            var s = SuggestionSession()
            events.forEach { s.handle($0) }
            XCTAssertTrue(s.handle(.dismiss))
            XCTAssertEqual(s.phase, .idle)
            XCTAssertTrue(s.candidates.isEmpty)
            XCTAssertNil(s.chosenIndex)
        }
    }

    func testErroredFromAnyStateThenDismissRecovers() {
        var s = SuggestionSession()
        s.handle(.hotkeyPressed)
        XCTAssertTrue(s.handle(.errored("no context")))
        XCTAssertEqual(s.phase, .failed("no context"))
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
