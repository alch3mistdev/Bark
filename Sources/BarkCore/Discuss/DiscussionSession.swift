import Foundation

/// Which mic model the user's discussion turns use (017 FR-005).
public enum DiscussionMicMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case ptt        // hold the dictation key per turn
    case handsFree  // continuous VAD: speak when ready, pause ends the turn
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .ptt: return "Push-to-talk"
        case .handsFree: return "Hands-free"
        }
    }
}

public enum DiscussionState: Sendable, Equatable {
    case idle
    case capturing
    case thinking
    case presenting
    case awaitingUser
    case listening
    case transcribing
    case turnFailed
    case synthesizing
    case synthesisFailed
    case previewing
    case injecting
    case finished
    case cancelled

    /// The half-duplex invariant's positive side: audio capture may run in
    /// exactly these states (data-model invariant 1, SC-002).
    public var allowsMic: Bool { self == .awaitingUser || self == .listening }

    public var isTerminal: Bool { self == .finished || self == .cancelled }
}

public enum DiscussionEvent: Sendable, Equatable {
    case begin
    case captureSucceeded(hasContext: Bool)
    case captureRefusedSecure
    case replyArrived(DialogueReply)
    case engineFailed
    case retryTurn
    case presentationFinished
    case userTurnBegan
    case userTurnEnded
    case transcriptFinal(String)
    case doneRequested
    case synthesisSucceeded(String)
    case synthesisFailed
    case retrySynthesis
    case resumeRequested
    case confirmRequested
    case injectionSucceeded
    case injectionFailed
    case cancelRequested
}

/// Pure discussion state machine (017, data-model.md). Owns the transcript
/// and the synthesized prompt; the controller owns everything OS-facing
/// (audio, engines, overlay, injection) and drives this by events. Illegal
/// (state, event) pairs are ignored — the repo's state-machine style.
public struct DiscussionSession: Sendable, Equatable {
    public private(set) var state: DiscussionState = .idle
    public private(set) var transcript: [DialogueTurn] = []
    public private(set) var synthesizedPrompt: String?
    public private(set) var synthesisFailures = 0
    public private(set) var hasContext = false
    /// Latest reply asked "ready to draft?" — the UI highlights Done.
    public private(set) var readySignaled = false

    public init() {}

    public mutating func handle(_ event: DiscussionEvent) {
        switch (state, event) {
        case (.idle, .begin):
            state = .capturing

        case (.capturing, .captureSucceeded(let hasContext)):
            self.hasContext = hasContext
            state = .thinking
        case (.capturing, .captureRefusedSecure):
            state = .cancelled

        case (.thinking, .replyArrived(let reply)):
            if reply.isSynthesisTrigger {
                state = .synthesizing
            } else {
                transcript.append(DialogueTurn(role: .assistant, text: reply.text))
                readySignaled = reply.isReadyToSynthesize
                state = .presenting
            }
        case (.thinking, .engineFailed):
            state = .turnFailed
        case (.turnFailed, .retryTurn):
            state = .thinking

        case (.presenting, .presentationFinished):
            state = .awaitingUser

        case (.awaitingUser, .userTurnBegan):
            state = .listening
        case (.listening, .userTurnEnded):
            state = .transcribing
        case (.transcribing, .transcriptFinal(let text)):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                state = .awaitingUser
            } else {
                transcript.append(DialogueTurn(role: .user, text: trimmed))
                state = .thinking
            }

        case (.awaitingUser, .doneRequested),
             (.presenting, .doneRequested),
             (.turnFailed, .doneRequested),
             (.synthesisFailed, .doneRequested):
            state = .synthesizing

        case (.synthesizing, .synthesisSucceeded(let prompt)):
            synthesizedPrompt = prompt
            synthesisFailures = 0
            state = .previewing
        case (.synthesizing, .synthesisFailed):
            synthesisFailures += 1
            state = .synthesisFailed
        case (.synthesisFailed, .retrySynthesis):
            state = .synthesizing

        case (.previewing, .resumeRequested):
            synthesizedPrompt = nil
            state = .awaitingUser
        case (.previewing, .confirmRequested):
            state = .injecting
        case (.injecting, .injectionSucceeded):
            state = .finished
        case (.injecting, .injectionFailed):
            state = .previewing

        case (_, .cancelRequested) where !state.isTerminal:
            state = .cancelled

        default:
            break   // illegal pair: no-op
        }
    }
}
