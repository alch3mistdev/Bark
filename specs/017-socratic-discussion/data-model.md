# Data Model: Socratic Discussion (017)

## Entities (all pure, `BarkCore`, `Sendable`)

### DialogueTurn

| Field | Type | Notes |
|---|---|---|
| `role` | `DialogueRole` (`.user` \| `.assistant`) | system prompt is never a turn — it is built per call by `DialoguePromptBuilder` |
| `text` | `String` | user turns are raw STT finals (fenced later at prompt-build time, not here) |

### DialogueReply

| Field | Type | Notes |
|---|---|---|
| `text` | `String` | the AI's question/statement, shown + optionally spoken |
| `isReadyToSynthesize` | `Bool` | machine-readable readiness (FR-003) |
| `isSynthesisTrigger` | computed `Bool` | `isReadyToSynthesize && text.trimmed.isEmpty` — the engine's "user confirmed, draft now" signal (see contract) |

Parse failure of the wire JSON degrades to `DialogueReply(text: rawOutput, isReadyToSynthesize: false)` — fail-safe: malformed output can never force synthesis.

### DialogueError

`engineUnavailable`, `deadlineExceeded`, `badResponse(String)`, `transport(String)` — maps from `SuggestionError`/URLError inside conformers; the controller only branches on retryability (all four are retryable in-session).

### DiscussionSession (state machine)

Pure struct; `private(set) var state`, `private(set) var transcript: [DialogueTurn]`,
`private(set) var synthesizedPrompt: String?`, `private(set) var synthesisFailures: Int`,
`private(set) var hasContext: Bool`. One mutating entry point: `handle(_ event: DiscussionEvent)`.
Illegal (state, event) pairs are ignored (no-ops), matching the repo's state-machine style.

## States

| State | Meaning | Mic may be armed? |
|---|---|---|
| `idle` | no session | n/a |
| `capturing` | focus snapshot + context capture running; overlay visible, not key | no |
| `thinking` | engine generating (opening question, a reply, or a retry) | **no** |
| `presenting` | reply visible; TTS may be playing | **no** |
| `awaitingUser` | user's turn: VAD armed, or waiting for PTT hold | yes |
| `listening` | user speaking (PTT held / VAD speech started) | yes |
| `transcribing` | STT finalizing the turn | no |
| `turnFailed` | engine reply failed; overlay offers Retry / Done / Cancel | no |
| `synthesizing` | final-prompt generation | **no** |
| `synthesisFailed` | synthesis failed (`synthesisFailures` ≥ 1); ≥ 2 → clipboard offer | no |
| `previewing` | final prompt shown; Confirm / Resume / Cancel | no |
| `injecting` | Confirm accepted; injector running | no |
| `finished` | terminal: injected | n/a |
| `cancelled` | terminal: user cancel, secure-field refusal, or close | n/a |

## Events → Transitions

| Event | From | To | Side data |
|---|---|---|---|
| `begin` | `idle` | `capturing` | |
| `captureSucceeded(hasContext:)` | `capturing` | `thinking` | sets `hasContext`; opening question call starts |
| `captureRefusedSecure` | `capturing` | `cancelled` | FR-013 |
| `replyArrived(DialogueReply)` | `thinking` | `presenting` — or `synthesizing` when `isSynthesisTrigger` | appends assistant turn (non-trigger only) |
| `engineFailed` | `thinking` | `turnFailed` | pending user turn retained in transcript |
| `retryTurn` | `turnFailed` | `thinking` | re-sends same transcript |
| `presentationFinished` | `presenting` | `awaitingUser` | TTS done (or no TTS) |
| `userTurnBegan` | `awaitingUser` | `listening` | |
| `userTurnEnded` | `listening` | `transcribing` | |
| `transcriptFinal(text)` | `transcribing` | `thinking` (non-empty) / `awaitingUser` (empty) | appends user turn when non-empty |
| `doneRequested` | `awaitingUser`, `presenting`, `turnFailed`, `synthesisFailed` | `synthesizing` | human override, both directions |
| `synthesisSucceeded(prompt)` | `synthesizing` | `previewing` | stores `synthesizedPrompt`; resets `synthesisFailures` |
| `synthesisFailed` | `synthesizing` | `synthesisFailed` | increments counter |
| `retrySynthesis` | `synthesisFailed` | `synthesizing` | |
| `resumeRequested` | `previewing` | `awaitingUser` | transcript unchanged; synthesized prompt discarded |
| `confirmRequested` | `previewing` | `injecting` | |
| `injectionSucceeded` | `injecting` | `finished` | |
| `injectionFailed` | `injecting` | `previewing` | overlay shows reason + clipboard offer |
| `cancelRequested` | any non-terminal | `cancelled` | transcript wiped by controller on teardown |

Opening question = the `capturing → thinking` engine call with an empty transcript; no special state.

Recapture is **not** a state change: allowed while `awaitingUser`/`presenting`/`turnFailed`, it swaps the controller-held `CapturedContext` used to build subsequent prompts (stateless rebuild per turn, research R2). `hasContext` updates via a controller re-dispatch of `captureSucceeded` only when the machine is in `capturing` — mid-session swaps touch data, not state.

## Invariants (asserted by tests)

1. **Half-duplex**: mic-armed states are exactly `awaitingUser` and `listening`; the controller arms audio only in those states, and `speak()` completing is the only path from `presenting` to `awaitingUser` when TTS is on (SC-002).
2. **No free-text control flow**: only `DialogueReply.isSynthesisTrigger` (parsed, fail-safe) or explicit user events (`doneRequested`) reach `synthesizing` (FR-003).
3. **Transcript never lost while non-terminal**: every failure state (`turnFailed`, `synthesisFailed`, `previewing` after `injectionFailed`) retains `transcript` and offers a user path forward (SC-004).
4. **Terminal wipe**: `finished`/`cancelled` → controller clears transcript, context, synthesized prompt (FR-010).
5. Candidate prompt immutable in `previewing`; `resumeRequested` discards it (a later synthesis regenerates).

## Settings additions (`Settings` struct, tolerant decoder)

| Field | Type | Default |
|---|---|---|
| `discussionEnabled` | `Bool` | `false` |
| `discussionHotkey` | `HotkeySetting` | F7 (keyCode 98) toggle |
| `discussionMicMode` | `DiscussionMicMode` (`.ptt` \| `.handsFree`) | `.ptt` |
| `discussionTTSEnabled` | `Bool` | `false` |

Backend/endpoint/model/key: reused 015 fields (research R8). No history writes (FR-010).
