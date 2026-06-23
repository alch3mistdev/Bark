import Foundation

/// What speech captured right now *means* within a hold-to-refine session.
public enum RefineContext: Sendable, Equatable {
    case dictation     // speech appends to the draft
    case instruction   // speech is a transform directive for the LLM
}

/// UI-facing activity of a hold-to-refine session, observed by the HUD (012,
/// FR-012). Kept separate from `DictationPhase` so the pure dictation state
/// machine is untouched.
public enum RefineActivity: Sendable, Equatable {
    case none                  // not in a refine-capable state / idle
    case dictating             // capturing dictation (appends to the draft)
    case capturingInstruction  // left-option held; capturing an instruction
    case refining              // applying a rewrite to the draft
}

/// Pure state for one in-session refinement (012). Spans a single push-to-talk
/// hold: the running `draft`, an undo `snapshots` stack (one entry pushed before
/// each *successful* refinement), and the current capture `context`.
///
/// No I/O, no async — the controller owns the mic/STT/LLM and feeds this pure
/// model. Fully unit-tested (see `contracts/refine-session.md`).
public struct RefineSession: Sendable, Equatable {
    public private(set) var draft: String
    public private(set) var snapshots: [String]
    public private(set) var context: RefineContext

    public init() {
        draft = ""
        snapshots = []
        context = .dictation
    }

    /// Append a mode-cleaned dictation chunk to the draft (space-joined, trimmed).
    /// The first non-empty append seeds the base draft (FR-004); later ones are
    /// inter-refinement dictation (FR-005). Empty/whitespace chunks are no-ops.
    public mutating func appendDictation(_ cleaned: String) {
        let chunk = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chunk.isEmpty else { return }
        draft = draft.isEmpty ? chunk : draft + " " + chunk
    }

    /// Start capturing an instruction (left-option held).
    public mutating func beginInstruction() {
        context = .instruction
    }

    /// Adopt a validated rewrite: push the prior draft for undo, swap in the
    /// rewrite, return to dictation context (FR-002/FR-003).
    public mutating func applyRefine(rewrite: String) {
        snapshots.append(draft)
        draft = rewrite
        context = .dictation
    }

    /// A refinement that errored/timed out/failed validation: keep the prior
    /// draft, push no snapshot, return to dictation context (FR-010).
    public mutating func keepOnFailure() {
        context = .dictation
    }

    /// One-step undo for an empty instruction turn: pop the last snapshot if any
    /// (else no-op), return to dictation context (FR-007). Never injects.
    public mutating func undo() {
        if !snapshots.isEmpty { draft = snapshots.removeLast() }
        context = .dictation
    }

    public var canUndo: Bool { !snapshots.isEmpty }
}
