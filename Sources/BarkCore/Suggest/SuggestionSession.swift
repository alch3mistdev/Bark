import Foundation

/// Observable phase of one suggestion pass (015).
public enum SuggestionPhase: Sendable, Equatable {
    case idle
    case capturing    // reading on-screen context
    case generating   // LLM producing candidates, none shown yet
    case presenting   // overlay up, awaiting a pick (candidates may still stream in)
    case injecting    // chosen text being delivered
    case dictating    // "Other…" — one-shot dictation in flight
    case failed(String)
}

public enum SuggestionEvent: Sendable, Equatable {
    case hotkeyPressed
    case contextCaptured
    case candidateArrived(String) // one validated candidate completed (016) — appends
    case generationFinished       // stream ended/deadline with ≥1 shown — footer clears (016)
    case moveHighlight(Int)       // delta, clamped over candidates + the Other row
    case choose(Int)              // explicit candidate pick (0-based)
    case chooseOther
    case acceptHighlighted        // Return on the highlighted row
    case injected
    case dictationFinished
    case dismiss                  // safety valve: always legal, always → idle
    case errored(String)          // safety valve: always legal, always → failed
}

/// Pure state machine for the suggestion flow (015, streaming in 016). Enforces
/// legal transitions so `SuggestionController` and the overlay can't drift into
/// impossible states. Modeled on `DictationStateMachine`; no I/O, fully
/// unit-tested.
///
/// 016 invariants: candidates are append-only and immutable once added
/// (numbering = index at arrival, never recomputed); a highlight resting on the
/// "Other…" row tracks it as candidates arrive; `isStreaming` drives the
/// overlay's "more coming…" footer.
public struct SuggestionSession: Sendable, Equatable {
    public private(set) var phase: SuggestionPhase = .idle
    public private(set) var candidates: [String] = []
    public private(set) var highlightedIndex: Int = 0
    public private(set) var chosenIndex: Int?
    public private(set) var isStreaming = false

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
            isStreaming = false
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
            phase = .generating
            isStreaming = true
            return true
        case (.generating, .candidateArrived(let candidate)):
            guard !candidate.isEmpty else { return false }
            candidates = [candidate]
            highlightedIndex = 0
            phase = .presenting
            return true
        case (.presenting, .candidateArrived(let candidate)):
            guard !candidate.isEmpty else { return false }
            // A highlight on "Other…" keeps meaning Other… after the append.
            let highlightWasOnOther = highlightedIndex == otherRowIndex
            candidates.append(candidate)
            if highlightWasOnOther { highlightedIndex = otherRowIndex }
            return true
        case (.presenting, .generationFinished):
            isStreaming = false
            return true
            // (.generating, .generationFinished) stays illegal: zero candidates
            // is the caller's cue to route to .errored instead.
        case (.presenting, .moveHighlight(let delta)):
            highlightedIndex = min(max(highlightedIndex + delta, 0), otherRowIndex)
            return true
        case (.presenting, .choose(let index)):
            guard candidates.indices.contains(index) else { return false }
            chosenIndex = index
            phase = .injecting
            isStreaming = false
            return true
        case (.generating, .chooseOther), (.presenting, .chooseOther):
            // Legal before the first candidate (016 FR-012): the Other… row is
            // actionable from the moment the overlay can take keys.
            phase = .dictating
            isStreaming = false
            return true
        case (.generating, .acceptHighlighted):
            // The only row while generating is Other….
            return handle(.chooseOther)
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
