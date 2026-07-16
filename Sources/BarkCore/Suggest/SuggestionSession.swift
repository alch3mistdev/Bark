import Foundation

/// Observable phase of one suggestion pass (015).
public enum SuggestionPhase: Sendable, Equatable {
    case idle
    case capturing    // reading on-screen context
    case generating   // LLM producing candidates
    case presenting   // overlay up, awaiting a pick
    case injecting    // chosen text being delivered
    case dictating    // "Other…" — one-shot dictation in flight
    case failed(String)
}

public enum SuggestionEvent: Sendable, Equatable {
    case hotkeyPressed
    case contextCaptured
    case candidatesReady([String])
    case moveHighlight(Int)       // delta, clamped over candidates + the Other row
    case choose(Int)              // explicit candidate pick (0-based)
    case chooseOther
    case acceptHighlighted        // Return on the highlighted row
    case injected
    case dictationFinished
    case dismiss                  // safety valve: always legal, always → idle
    case errored(String)          // safety valve: always legal, always → failed
}

/// Pure state machine for the suggestion flow (015). Enforces legal transitions
/// so `SuggestionController` and the overlay can't drift into impossible states.
/// Modeled on `DictationStateMachine`; no I/O, fully unit-tested.
public struct SuggestionSession: Sendable, Equatable {
    public private(set) var phase: SuggestionPhase = .idle
    public private(set) var candidates: [String] = []
    public private(set) var highlightedIndex: Int = 0
    public private(set) var chosenIndex: Int?

    public init() {}

    /// Index of the "Other…" row — one past the last candidate.
    public var otherRowIndex: Int { candidates.count }

    public var isActive: Bool {
        switch phase {
        case .idle, .failed: return false
        default: return true
        }
    }

    /// Applies `event`; returns `true` if it caused a legal transition.
    @discardableResult
    public mutating func handle(_ event: SuggestionEvent) -> Bool {
        // Safety valves, legal from any state.
        switch event {
        case .errored(let message):
            phase = .failed(message)
            return true
        case .dismiss:
            self = SuggestionSession()
            return true
        default:
            break
        }

        switch (phase, event) {
        case (.idle, .hotkeyPressed):
            phase = .capturing; return true
        case (.capturing, .contextCaptured):
            phase = .generating; return true
        case (.generating, .candidatesReady(let list)):
            guard !list.isEmpty else { return false }   // caller routes empty to .errored
            candidates = list
            highlightedIndex = 0
            phase = .presenting
            return true
        case (.presenting, .moveHighlight(let delta)):
            highlightedIndex = min(max(highlightedIndex + delta, 0), otherRowIndex)
            return true
        case (.presenting, .choose(let index)):
            guard candidates.indices.contains(index) else { return false }
            chosenIndex = index
            phase = .injecting
            return true
        case (.presenting, .chooseOther):
            phase = .dictating; return true
        case (.presenting, .acceptHighlighted):
            return highlightedIndex == otherRowIndex
                ? handle(.chooseOther)
                : handle(.choose(highlightedIndex))
        case (.injecting, .injected), (.dictating, .dictationFinished):
            self = SuggestionSession()
            return true
        default:
            return false   // illegal transition — ignored
        }
    }
}
