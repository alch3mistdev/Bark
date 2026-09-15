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

    /// A session that has a real user turn in it, so `doneRequested` is legal.
    /// Synthesis is refused without one (drafting from the AI's own opening
    /// question alone invents content), so any test that reaches `previewing`
    /// must go through here rather than shortcutting.
    private func advanceToSynthesizable() -> DiscussionSession {
        var s = advanceToAwaitingUser()
        s.handle(.userTurnBegan)
        s.handle(.userTurnEnded)
        s.handle(.transcriptFinal("a launch email"))
        s.handle(.replyArrived(DialogueReply(text: "Which audience?", isReadyToSynthesize: false)))
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

    func testDoneIsRefusedUntilTheUserHasSaidSomething() {
        // Drafting from a transcript holding only the AI's opening question
        // invents content the user never asked for.
        var s = advanceToAwaitingUser()
        XCTAssertFalse(s.canSynthesize)
        s.handle(.doneRequested)
        XCTAssertEqual(s.state, .awaitingUser)   // refused, session unchanged

        s.handle(.userTurnBegan)
        s.handle(.userTurnEnded)
        s.handle(.transcriptFinal("a launch email"))
        XCTAssertTrue(s.canSynthesize)
        s.handle(.replyArrived(DialogueReply(text: "Which audience?", isReadyToSynthesize: false)))
        s.handle(.presentationFinished)
        s.handle(.doneRequested)
        XCTAssertEqual(s.state, .synthesizing)   // now allowed
    }

    func testContextRefreshUpdatesFlagWithoutMovingState() {
        // Recapture must be observable (its first version changed nothing on
        // screen, which read as a dead button) but must not disturb the turn.
        var s = advanceToAwaitingUser()
        XCTAssertEqual(s.contextVersion, 0)

        s.handle(.contextRefreshed(hasContext: true))
        XCTAssertEqual(s.state, .awaitingUser)
        XCTAssertEqual(s.contextVersion, 1)
        XCTAssertTrue(s.hasContext)

        // A failed refresh reports no context and does not claim a version.
        s.handle(.contextRefreshed(hasContext: false))
        XCTAssertFalse(s.hasContext)
        XCTAssertEqual(s.contextVersion, 1)

        // Legal mid-turn, ignored once terminal.
        s.handle(.cancelRequested)
        s.handle(.contextRefreshed(hasContext: true))
        XCTAssertEqual(s.contextVersion, 1)
        XCTAssertEqual(s.state, .cancelled)
    }

    func testDoneRequestedFromAllowedStates() {
        // Each case needs a user turn on record — see canSynthesize.
        // awaitingUser:
        var a = advanceToSynthesizable()
        a.handle(.doneRequested)
        XCTAssertEqual(a.state, .synthesizing)

        // presenting (Done pressed while the reply is still being shown/spoken):
        var p = advanceToAwaitingUser()
        p.handle(.userTurnBegan); p.handle(.userTurnEnded)
        p.handle(.transcriptFinal("a launch email"))
        p.handle(.replyArrived(DialogueReply(text: "Which audience?", isReadyToSynthesize: false)))
        XCTAssertEqual(p.state, .presenting)
        p.handle(.doneRequested)
        XCTAssertEqual(p.state, .synthesizing)

        // turnFailed (draft from what we have after an engine failure):
        var f = advanceToAwaitingUser()
        f.handle(.userTurnBegan); f.handle(.userTurnEnded)
        f.handle(.transcriptFinal("a launch email"))
        f.handle(.engineFailed)
        XCTAssertEqual(f.state, .turnFailed)
        f.handle(.doneRequested)
        XCTAssertEqual(f.state, .synthesizing)
    }

    func testSynthesisSuccessAndPreviewFlow() {
        var s = advanceToSynthesizable()
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
        var s = advanceToSynthesizable()
        s.handle(.doneRequested)
        s.handle(.synthesisSucceeded("v1"))
        let transcript = s.transcript
        s.handle(.resumeRequested)
        XCTAssertEqual(s.state, .awaitingUser)
        XCTAssertNil(s.synthesizedPrompt)
        XCTAssertEqual(s.transcript, transcript)
    }

    func testSynthesisFailureCountsAndRetries() {
        var s = advanceToSynthesizable()
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
        var s = advanceToSynthesizable()
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
                $0.handle(.presentationFinished)
                $0.handle(.userTurnBegan); $0.handle(.userTurnEnded)
                $0.handle(.transcriptFinal("said something"))
                $0.handle(.replyArrived(DialogueReply(text: "q2", isReadyToSynthesize: false)))
                $0.handle(.presentationFinished); $0.handle(.doneRequested) }),
            ("previewing", { $0.handle(.begin); $0.handle(.captureSucceeded(hasContext: true))
                $0.handle(.replyArrived(DialogueReply(text: "q", isReadyToSynthesize: false)))
                $0.handle(.presentationFinished)
                $0.handle(.userTurnBegan); $0.handle(.userTurnEnded)
                $0.handle(.transcriptFinal("said something"))
                $0.handle(.replyArrived(DialogueReply(text: "q2", isReadyToSynthesize: false)))
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
