import XCTest
@testable import BarkCore

final class DiscussionSessionTests: XCTestCase {
    private func advanceToAwaitingUser() -> DiscussionSession {
        var s = DiscussionSession()
        s.handle(.begin)
        s.handle(.captureSucceeded(hasContext: true))
        s.handle(.replyArrived(DialogueReply(text: "What's the goal?", isReadyToSynthesize: false)))
        s.handle(.presentationFinished)
        return s
    }

    func testHappyPathToAwaitingUser() {
        var s = DiscussionSession()
        XCTAssertEqual(s.state, .idle)
        s.handle(.begin)
        XCTAssertEqual(s.state, .capturing)
        s.handle(.captureSucceeded(hasContext: true))
        XCTAssertEqual(s.state, .thinking)
        XCTAssertTrue(s.hasContext)
        s.handle(.replyArrived(DialogueReply(text: "What's the goal?", isReadyToSynthesize: false)))
        XCTAssertEqual(s.state, .presenting)
        XCTAssertEqual(s.transcript, [DialogueTurn(role: .assistant, text: "What's the goal?")])
        s.handle(.presentationFinished)
        XCTAssertEqual(s.state, .awaitingUser)
    }

    func testUserTurnRoundTrip() {
        var s = advanceToAwaitingUser()
        s.handle(.userTurnBegan)
        XCTAssertEqual(s.state, .listening)
        s.handle(.userTurnEnded)
        XCTAssertEqual(s.state, .transcribing)
        s.handle(.transcriptFinal("a launch email"))
        XCTAssertEqual(s.state, .thinking)
        XCTAssertEqual(s.transcript.last, DialogueTurn(role: .user, text: "a launch email"))
    }

    func testEmptyTranscriptReturnsToAwaitingUserWithoutTurn() {
        var s = advanceToAwaitingUser()
        let turnsBefore = s.transcript.count
        s.handle(.userTurnBegan)
        s.handle(.userTurnEnded)
        s.handle(.transcriptFinal("   \n"))
        XCTAssertEqual(s.state, .awaitingUser)
        XCTAssertEqual(s.transcript.count, turnsBefore)
    }

    func testSynthesisTriggerSkipsPresentingAndAppendsNoTurn() {
        var s = advanceToAwaitingUser()
        s.handle(.userTurnBegan)
        s.handle(.userTurnEnded)
        s.handle(.transcriptFinal("yes draft it"))
        let turnsBefore = s.transcript.count
        s.handle(.replyArrived(DialogueReply(text: "", isReadyToSynthesize: true)))
        XCTAssertEqual(s.state, .synthesizing)
        XCTAssertEqual(s.transcript.count, turnsBefore)   // empty trigger reply is not a turn
    }

    func testReadyQuestionSetsSignalAndKeepsPresenting() {
        var s = advanceToAwaitingUser()
        s.handle(.userTurnBegan)
        s.handle(.userTurnEnded)
        s.handle(.transcriptFinal("that's everything"))
        s.handle(.replyArrived(DialogueReply(text: "Ready for me to draft it?", isReadyToSynthesize: true)))
        XCTAssertEqual(s.state, .presenting)
        XCTAssertTrue(s.readySignaled)
    }

    func testDoneRequestedFromAllowedStates() {
        for warmup in [
            { (s: inout DiscussionSession) in },                                   // awaitingUser
            { (s: inout DiscussionSession) in s.handle(.userTurnBegan); s.handle(.userTurnEnded)
              s.handle(.transcriptFinal("x")); s.handle(.engineFailed) },          // turnFailed
        ] {
            var s = advanceToAwaitingUser()
            warmup(&s)
            s.handle(.doneRequested)
            XCTAssertEqual(s.state, .synthesizing)
        }
        // presenting
        var p = DiscussionSession()
        p.handle(.begin)
        p.handle(.captureSucceeded(hasContext: false))
        p.handle(.replyArrived(DialogueReply(text: "q", isReadyToSynthesize: false)))
        p.handle(.doneRequested)
        XCTAssertEqual(p.state, .synthesizing)
    }

    func testSynthesisSuccessAndPreviewFlow() {
        var s = advanceToAwaitingUser()
        s.handle(.doneRequested)
        s.handle(.synthesisSucceeded("Final prompt."))
        XCTAssertEqual(s.state, .previewing)
        XCTAssertEqual(s.synthesizedPrompt, "Final prompt.")
        s.handle(.confirmRequested)
        XCTAssertEqual(s.state, .injecting)
        s.handle(.injectionSucceeded)
        XCTAssertEqual(s.state, .finished)
    }

    func testResumeDiscardsPromptKeepsTranscript() {
        var s = advanceToAwaitingUser()
        s.handle(.doneRequested)
        s.handle(.synthesisSucceeded("v1"))
        let transcript = s.transcript
        s.handle(.resumeRequested)
        XCTAssertEqual(s.state, .awaitingUser)
        XCTAssertNil(s.synthesizedPrompt)
        XCTAssertEqual(s.transcript, transcript)
    }

    func testSynthesisFailureCountsAndRetries() {
        var s = advanceToAwaitingUser()
        s.handle(.doneRequested)
        s.handle(.synthesisFailed)
        XCTAssertEqual(s.state, .synthesisFailed)
        XCTAssertEqual(s.synthesisFailures, 1)
        s.handle(.retrySynthesis)
        s.handle(.synthesisFailed)
        XCTAssertEqual(s.synthesisFailures, 2)
        s.handle(.retrySynthesis)
        s.handle(.synthesisSucceeded("ok"))
        XCTAssertEqual(s.synthesisFailures, 0)   // success resets
    }

    func testEngineFailureKeepsTranscriptAndRetries() {
        var s = advanceToAwaitingUser()
        s.handle(.userTurnBegan)
        s.handle(.userTurnEnded)
        s.handle(.transcriptFinal("my goal"))
        s.handle(.engineFailed)
        XCTAssertEqual(s.state, .turnFailed)
        XCTAssertEqual(s.transcript.last, DialogueTurn(role: .user, text: "my goal"))
        s.handle(.retryTurn)
        XCTAssertEqual(s.state, .thinking)
    }

    func testInjectionFailureReturnsToPreviewingWithPromptIntact() {
        var s = advanceToAwaitingUser()
        s.handle(.doneRequested)
        s.handle(.synthesisSucceeded("keep me"))
        s.handle(.confirmRequested)
        s.handle(.injectionFailed)
        XCTAssertEqual(s.state, .previewing)
        XCTAssertEqual(s.synthesizedPrompt, "keep me")
    }

    func testSecureFieldRefusalCancels() {
        var s = DiscussionSession()
        s.handle(.begin)
        s.handle(.captureRefusedSecure)
        XCTAssertEqual(s.state, .cancelled)
    }

    func testCancelFromEveryNonTerminalState() {
        let builders: [(String, (inout DiscussionSession) -> Void)] = [
            ("capturing", { $0.handle(.begin) }),
            ("thinking", { $0.handle(.begin); $0.handle(.captureSucceeded(hasContext: true)) }),
            ("presenting", { $0.handle(.begin); $0.handle(.captureSucceeded(hasContext: true))
                $0.handle(.replyArrived(DialogueReply(text: "q", isReadyToSynthesize: false))) }),
            ("awaitingUser", { $0.handle(.begin); $0.handle(.captureSucceeded(hasContext: true))
                $0.handle(.replyArrived(DialogueReply(text: "q", isReadyToSynthesize: false)))
                $0.handle(.presentationFinished) }),
            ("synthesizing", { $0.handle(.begin); $0.handle(.captureSucceeded(hasContext: true))
                $0.handle(.replyArrived(DialogueReply(text: "q", isReadyToSynthesize: false)))
                $0.handle(.presentationFinished); $0.handle(.doneRequested) }),
            ("previewing", { $0.handle(.begin); $0.handle(.captureSucceeded(hasContext: true))
                $0.handle(.replyArrived(DialogueReply(text: "q", isReadyToSynthesize: false)))
                $0.handle(.presentationFinished); $0.handle(.doneRequested)
                $0.handle(.synthesisSucceeded("p")) }),
        ]
        for (name, build) in builders {
            var s = DiscussionSession()
            build(&s)
            s.handle(.cancelRequested)
            XCTAssertEqual(s.state, .cancelled, "from \(name)")
        }
    }

    func testTerminalStatesIgnoreFurtherEvents() {
        var s = DiscussionSession()
        s.handle(.begin)
        s.handle(.cancelRequested)
        s.handle(.begin)
        s.handle(.doneRequested)
        XCTAssertEqual(s.state, .cancelled)
    }

    func testIllegalPairsAreNoOps() {
        var s = DiscussionSession()
        s.handle(.doneRequested)              // idle: ignored
        s.handle(.confirmRequested)
        XCTAssertEqual(s.state, .idle)
        s.handle(.begin)
        s.handle(.userTurnBegan)              // capturing: ignored
        XCTAssertEqual(s.state, .capturing)
    }

    func testMicAllowedExactlyInAwaitingAndListening() {
        XCTAssertTrue(DiscussionState.awaitingUser.allowsMic)
        XCTAssertTrue(DiscussionState.listening.allowsMic)
        for state: DiscussionState in [.idle, .capturing, .thinking, .presenting, .transcribing,
                                       .turnFailed, .synthesizing, .synthesisFailed, .previewing,
                                       .injecting, .finished, .cancelled] {
            XCTAssertFalse(state.allowsMic, "\(state)")
        }
    }
}
