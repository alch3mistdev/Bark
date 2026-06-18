import XCTest
@testable import BarkCore

final class DictationStateMachineTests: XCTestCase {
    func testRawHappyPath() {
        var m = DictationStateMachine()
        XCTAssertEqual(m.phase, .idle)
        XCTAssertTrue(m.handle(.startPressed));        XCTAssertEqual(m.phase, .listening)
        XCTAssertTrue(m.handle(.audioStarted));        XCTAssertEqual(m.phase, .listening)
        XCTAssertTrue(m.handle(.stopPressed));         XCTAssertEqual(m.phase, .transcribing)
        XCTAssertTrue(m.handle(.transcriptFinalized)); XCTAssertEqual(m.phase, .injecting)
        XCTAssertTrue(m.handle(.injected));            XCTAssertEqual(m.phase, .completed)
    }

    func testCleanupPath() {
        var m = DictationStateMachine()
        m.handle(.startPressed)
        m.handle(.stopPressed)
        m.handle(.transcriptFinalized)               // -> injecting
        XCTAssertTrue(m.handle(.cleanupStarted));     XCTAssertEqual(m.phase, .cleaning)
        XCTAssertTrue(m.handle(.cleanupFinished));    XCTAssertEqual(m.phase, .injecting)
        XCTAssertTrue(m.handle(.injected));           XCTAssertEqual(m.phase, .completed)
    }

    func testIllegalTransitionIgnored() {
        var m = DictationStateMachine()
        XCTAssertFalse(m.handle(.stopPressed))        // can't stop from idle
        XCTAssertEqual(m.phase, .idle)
        XCTAssertFalse(m.handle(.injected))
        XCTAssertEqual(m.phase, .idle)
    }

    func testErrorFromAnyPhase() {
        var m = DictationStateMachine()
        m.handle(.startPressed)
        XCTAssertTrue(m.handle(.errored("mic denied")))
        XCTAssertEqual(m.phase, .failed("mic denied"))
        XCTAssertFalse(m.isActive)
    }

    func testResetReturnsToIdle() {
        var m = DictationStateMachine()
        m.handle(.startPressed)
        m.handle(.stopPressed)
        XCTAssertTrue(m.handle(.reset))
        XCTAssertEqual(m.phase, .idle)
    }

    func testIsActive() {
        var m = DictationStateMachine()
        XCTAssertFalse(m.isActive)
        m.handle(.startPressed)
        XCTAssertTrue(m.isActive)
        m.handle(.stopPressed)
        XCTAssertTrue(m.isActive)
        m.handle(.transcriptFinalized)
        m.handle(.injected)
        XCTAssertFalse(m.isActive) // completed
    }

    // Regression (ADV-005 / Codex): a failed run must be reset before it can
    // restart — the controller does this so the hotkey never dies after an error.
    func testStartFromFailedRequiresReset() {
        var m = DictationStateMachine()
        m.handle(.startPressed)
        m.handle(.errored("mic denied"))
        XCTAssertEqual(m.phase, .failed("mic denied"))
        XCTAssertFalse(m.handle(.startPressed))   // illegal directly from .failed
        XCTAssertEqual(m.phase, .failed("mic denied"))
        XCTAssertTrue(m.handle(.reset))
        XCTAssertTrue(m.handle(.startPressed))
        XCTAssertEqual(m.phase, .listening)
    }

    // Regression (ADV-010): the LLM path runs cleanup *after* transcriptFinalized
    // (phase == .injecting) and must return to .injecting, all via the machine.
    func testCleanupRunsFromInjecting() {
        var m = DictationStateMachine()
        m.handle(.startPressed); m.handle(.stopPressed)
        m.handle(.transcriptFinalized)
        XCTAssertEqual(m.phase, .injecting)
        XCTAssertTrue(m.handle(.cleanupStarted));  XCTAssertEqual(m.phase, .cleaning)
        XCTAssertTrue(m.handle(.cleanupFinished)); XCTAssertEqual(m.phase, .injecting)
        XCTAssertTrue(m.handle(.injected));        XCTAssertEqual(m.phase, .completed)
    }

    func testRestartFromCompleted() {
        var m = DictationStateMachine()
        m.handle(.startPressed); m.handle(.stopPressed)
        m.handle(.transcriptFinalized); m.handle(.injected)
        XCTAssertEqual(m.phase, .completed)
        XCTAssertTrue(m.handle(.startPressed))
        XCTAssertEqual(m.phase, .listening)
    }
}
