# Contract: RefineSession (pure)

`BarkCore/Refine/RefineSession.swift` — pure, `Sendable`, `Equatable`, zero dependencies. The seam
between the controller's I/O (mic, STT, LLM) and the testable draft logic. No async, no actors.

## Shape

```swift
public enum RefineContext: Sendable, Equatable { case dictation, instruction }

public struct RefineSession: Sendable, Equatable {
    public private(set) var draft: String
    public private(set) var snapshots: [String]
    public private(set) var context: RefineContext

    public init()                                   // draft = "", snapshots = [], context = .dictation

    public mutating func appendDictation(_ cleaned: String)   // space-join + trim; no snapshot
    public mutating func beginInstruction()                   // context = .instruction
    public mutating func applyRefine(rewrite: String)         // push draft; draft = rewrite; context = .dictation
    public mutating func keepOnFailure()                      // context = .dictation; draft unchanged; no snapshot
    public mutating func undo()                               // pop snapshot if any; context = .dictation
    public var canUndo: Bool { get }                          // !snapshots.isEmpty
}
```

## Behavioral contract

| # | Given | When | Then |
|---|---|---|---|
| 1 | new session | `appendDictation("Hello my name is foo")` | `draft == "Hello my name is foo"`, `snapshots == []` |
| 2 | draft = base | `applyRefine(rewrite: "Hello my name is bar")` | `snapshots == [base]`, `draft == "Hello my name is bar"`, `context == .dictation` |
| 3 | after #2 | `applyRefine(rewrite: "Greetings…")` | `snapshots == [base, "Hello my name is bar"]`, `draft == "Greetings…"` |
| 4 | after #3 | `undo()` | `draft == "Hello my name is bar"`, `snapshots == [base]` |
| 5 | after #4 | `undo()` | `draft == base`, `snapshots == []` |
| 6 | `snapshots == []` | `undo()` | no-op; `draft` unchanged; `canUndo == false` |
| 7 | draft = X | `keepOnFailure()` | `draft == X`, no snapshot pushed, `context == .dictation` |
| 8 | draft = base | `appendDictation("second point")` | `draft == "base second point"` (space-joined, trimmed) |
| 9 | any | `beginInstruction()` | `context == .instruction`; `draft`/`snapshots` unchanged |

## Notes

- `applyRefine` is called by the controller **only after** the LLM rewrite is validated; a
  failed/timed-out rewrite calls `keepOnFailure()` instead — so `snapshots` maps 1:1 to *applied*
  refinements and undo can never step "into" a rejected rewrite (FR-010, SC-006).
- The struct never injects and never decides gating; the controller owns those.
- `appendDictation("")` is a no-op (empty/whitespace chunk).
