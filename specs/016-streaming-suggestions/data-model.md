# Data Model: Streaming Suggested Responses (016)

All state is in-memory and ephemeral; nothing here is persisted.

## SuggestionSession (modified — BarkCore)

| Field | Type | Change | Rules |
|---|---|---|---|
| `phase` | `SuggestionPhase` | unchanged cases | `.presenting` is now reachable from the **first** candidate, not the full set |
| `candidates` | `[String]` | unchanged | append-only while active; elements immutable once appended; index = displayed number − 1 |
| `isStreaming` | `Bool` | **new** | `true` from `.contextCaptured` until `.generationFinished` / dismissal; drives the overlay footer |
| `highlightedIndex` | `Int` | unchanged | on candidate append: if it equaled the old Other-row index it tracks the Other row (moves to the new last index); otherwise unchanged |
| `chosenIndex` | `Int?` | unchanged | set only by `.choose`; injection reads `candidates[chosenIndex]` |

### Events (modified)

| Event | Replaces | Legal in | Effect |
|---|---|---|---|
| `.candidateArrived(String)` | `.candidatesReady([String])` | `.generating`, `.presenting` | append (already-validated) candidate; `.generating` → `.presenting` on first |
| `.generationFinished` | — (new) | `.presenting` only | clears `isStreaming`; the machine refuses it in `.generating` (zero candidates), which is the caller's cue to route to `.errored` |
| all others | unchanged | unchanged (+ `.chooseOther` now legal in `.generating`) | `.chooseOther` from `.generating` = early escape hatch (FR-012) |

### State transitions

```
idle ─hotkeyPressed→ capturing ─contextCaptured→ generating(isStreaming)
generating ─candidateArrived→ presenting(isStreaming)      # first candidate
presenting ─candidateArrived→ presenting                    # append, numbering stable
generating|presenting ─generationFinished→ presenting       # footer disappears (zero-candidate case → errored)
generating|presenting ─chooseOther→ dictating               # cancels generation (controller)
presenting ─choose(i)→ injecting                            # cancels generation (controller)
any ─dismiss→ idle · any ─errored→ failed                   # unchanged safety valves
```

## SuggestionStreamParser (new — BarkCore, pure)

| Member | Type | Rules |
|---|---|---|
| buffer | accumulated raw text | internal; never logged |
| emitted | `[String]` | dedupe set + cap source; equals what the caller has shown |
| `consume(_ chunk:) -> [String]` | mutating | returns only *newly completed, validated* candidates (possibly empty) |
| `finish() -> [String]` | mutating | flushes a cleanly-terminated tail (e.g. last salvage line without trailing newline); idempotent |

**Invariants** (tested):
1. Prefix-parity: at every point, `emitted` == a prefix of `SuggestionResponseParser.parse(buffer)` for the recognized formats; after `finish()`, equality is exact (SC-002).
2. Conservatism: text inside an unclosed think span or an unclosed string literal is never emitted.
3. Monotonicity: `consume`/`finish` never mutate or reorder previously returned candidates.
4. Validation: single shared rulebook with the batch parser (trim, ≤160 chars, non-empty, dedupe, ≤4 candidates).

## SuggestionEngine (contract change — see contracts/streaming-engine.md)

`suggestStream(_:) -> AsyncThrowingStream<String, Error>` with a batch-wrapping default. No stored data.

## Unchanged

`SuggestionRequest`, `SuggestionPrompt`, `CapturedContext` (ephemeral), `AutoSubmitPolicy`, `HistoryRecord` usage, settings schema.
