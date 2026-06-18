import Foundation

/// Observable phase of one dictation pass.
public enum DictationPhase: Sendable, Equatable {
    case idle
    case listening      // mic open, capturing + streaming STT
    case transcribing   // hotkey released, finalizing transcript
    case cleaning       // optional LLM rewrite running
    case injecting      // writing text to the target app
    case completed
    case failed(String)
}

public enum DictationEvent: Sendable, Equatable {
    case startPressed
    case audioStarted
    case stopPressed
    case transcriptFinalized
    case cleanupStarted
    case cleanupFinished
    case injected
    case errored(String)
    case reset
}

/// Pure state machine for the capture→STT→cleanup→inject pipeline. Enforces
/// legal transitions so the orchestrator (`DictationController`) and UI can't
/// drift into impossible states. Fully unit-tested; no I/O.
public struct DictationStateMachine: Sendable, Equatable {
    public private(set) var phase: DictationPhase

    public init() { self.phase = .idle }

    /// Applies `event`; returns `true` if it caused a legal transition.
    @discardableResult
    public mutating func handle(_ event: DictationEvent) -> Bool {
        // `errored` and `reset` are always legal (safety valves).
        switch event {
        case .errored(let msg):
            phase = .failed(msg)
            return true
        case .reset:
            phase = .idle
            return true
        default:
            break
        }

        switch (phase, event) {
        case (.idle, .startPressed):
            phase = .listening; return true
        case (.listening, .audioStarted):
            return true // no phase change; capture confirmed
        case (.listening, .stopPressed):
            phase = .transcribing; return true
        case (.transcribing, .transcriptFinalized):
            phase = .injecting; return true     // default: straight to inject (raw-first)
        case (.transcribing, .cleanupStarted), (.injecting, .cleanupStarted):
            phase = .cleaning; return true
        case (.cleaning, .cleanupFinished):
            phase = .injecting; return true
        case (.injecting, .injected), (.cleaning, .injected):
            phase = .completed; return true
        case (.completed, .startPressed):
            phase = .listening; return true
        default:
            return false // illegal transition — ignored
        }
    }

    public var isActive: Bool { phase.isActive }
}

public extension DictationPhase {
    /// True while a dictation pass is in flight (UI disables mode changes, etc.).
    var isActive: Bool {
        switch self {
        case .idle, .completed, .failed: return false
        default: return true
        }
    }
}
