# Data Model: In-session voice refinement (hold-to-refine)

Entities are in-memory (session-scoped) except the one persisted `Settings` field. Pure types live in
`BarkCore`; nothing here is encoded to disk beyond the boolean toggle.

## RefineSession (pure, `BarkCore/Refine/RefineSession.swift`)

The session state spanning one fn hold. No I/O — all methods are pure mutations, unit-tested.

| Field | Type | Notes |
|---|---|---|
| `draft` | `String` | The running text; the only thing injected (at fn-release). Starts empty. |
| `snapshots` | `[String]` | Undo stack; the pre-refinement draft is pushed on each **successful** refinement. |
| `context` | `RefineContext` | Current capture meaning: `.dictation` or `.instruction`. Starts `.dictation`. |

**Methods (pure):**
- `appendDictation(_ cleaned: String)` — append a mode-cleaned dictation chunk to `draft` (space-join,
  trim). No snapshot. (FR-004 first chunk = base; FR-005 later chunks.)
- `beginInstruction()` — set `context = .instruction` (start capturing an instruction).
- `applyRefine(rewrite: String)` — push `draft` to `snapshots`, set `draft = rewrite`; set
  `context = .dictation`. Used when a refine succeeds (FR-002/FR-003).
- `keepOnFailure()` — set `context = .dictation`, draft unchanged, no snapshot (FR-010).
- `undo()` — if `snapshots` non-empty, `draft = snapshots.removeLast()`; else no-op. Set
  `context = .dictation`. (FR-007 empty-instruction = one-step undo.)
- `canUndo: Bool` — `!snapshots.isEmpty`.

**Invariants**: `draft` never reverts below the base; intermediate drafts are not exposed for
injection; `snapshots` only grows on successful refinements, so undo maps 1:1 to applied refinements.

## RefineContext (pure enum)

`.dictation` (speech appends to draft) | `.instruction` (speech is a transform directive). Set by the
left-option boundary handlers.

## RefineActivity (observable, `DictationController`)

UI-facing state for the HUD (FR-012). Separate from `DictationPhase` so the pure state machine is
untouched.

`.none` | `.dictating` | `.capturingInstruction` | `.refining`

- `currentDraft: String` — observable mirror of `RefineSession.draft` for the HUD.
- Bound by `RecordingHUDView` alongside existing `phase`, `liveText`, `inputLevel`.
- `refineHintShown: Bool` — **in-memory, session-scoped** (not persisted to `Settings`). Guards the
  "refinement needs the LLM" hint (FR-011/FR-017) so it shows once per app run; reset on relaunch.

## RefineKeyEvent (pure, `BarkCore/Refine/RefineKeyDecoder.swift`)

Output of the pure decoder: `.refineStart` | `.refineEnd` | `nil` (ignore). Inputs: alternate-flag
on/off, keycode, `fnHeld`, `auxHeld`. Only keycode **58** (left option) with `fnHeld == true` yields
start/end; right option (61) and option-without-fn yield `nil`.

## Mode (edit, `BarkCore/Cleanup/Mode.swift`)

Add one optional field (shared with feature 009):

| Field | Type | Notes |
|---|---|---|
| `revisionPrompt` | `String?` | Per-mode refine/revision instruction; `nil` → generic refine prompt. Codable, tolerant decode (defaults `nil`). |

Built-in seed values (refinement quality):
- `email.revisionPrompt` — "Apply the user's instruction while keeping an email register:
  professional, concise; no greetings or sign-offs."
- `code.revisionPrompt` — "Apply the user's instruction while preserving code identifiers and symbols
  exactly; imperative, terse."
- Others (`raw`, `clean`, `message`, `list`) — `nil` → generic.

## Settings (edit, `BarkCore/Settings/Settings.swift`)

Add one persisted field via the existing tolerant codec:

| Field | Type | Default | Notes |
|---|---|---|---|
| `holdToRefineEnabled` | `Bool` | `true` | FR-017. Decode-if-present → default `true`. Off ⇒ left-option ignored, base unchanged. |

The effective live state is `holdToRefineEnabled && llmAvailable && llmEnabled && llm.isAvailable`
(FR-011/FR-017).

## Refine prompt (edit, `BarkCore/Cleanup/PromptTemplate.swift`)

Not stored data; documented in [contracts/text-cleaner-refine.md](./contracts/text-cleaner-refine.md).
Fences `draft` in `<text>…</text>` and `instruction` in `<instruction>…</instruction>`, with the same
closing-tag neutralization and guardrail as the existing cleanup prompt.
