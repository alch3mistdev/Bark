# ADR-007 — Voice-driven revision of the last injection

**Status:** Accepted (subject to spec review — see `specs/009-voice-driven-revision/spec.md`)
**Date:** 2026-06-19
**Context:** `specs/009-voice-driven-revision/spec.md`

## Context

After Bark injects cleaned text into the focused field, the user often wants to revise what was
just written — *"more formal"*, *"shorter"*, *"fix the grammar"*, *"actually scratch that, say X
instead"*. Today the only options are (a) leave the field, type the correction manually, or (b)
re-dictate the whole thing. Both are friction-heavy.

The 2026-06-19 competitive gap analysis ranked this the **single highest-leverage move** in the
category: every dictation app (Superwhisper, Wispr Flow, VoiceInk, Aqua Voice, Willow Voice)
competes on the speech→text leg; **nobody operates on already-injected text via voice.** This
transforms Bark from "dictation app" into "voice-controlled text editor," a category nobody
currently occupies.

The 2026-06-19 spec (`specs/009-voice-driven-revision/spec.md`) lays out six user stories; this
ADR records the architectural decisions behind the design.

## Decision

### 1. Second hotkey, separate from push-to-talk

The revision hotkey is a **separate `HotkeyManager` instance** (mirroring the hands-free hotkey
pattern). It defaults to `⌥⌘R` and is configurable via the same `HotkeyRecorder` UI used for
push-to-talk. The two hotkeys never share a binding (mirrors ADV-002 in `DictationController`).

Why a separate hotkey and not a mode of push-to-talk: the user explicitly *chooses* to revise;
that's a different intent from dictating new text. Conflating them with a single hotkey + voice
command ("revise that", "new text") makes the failure mode ambiguous and harder to debug. A
separate keypress is unambiguous and trivially discoverable.

### 2. Deterministic dictionary works without the LLM

The lean build (no `MLXCleanup`) ships a **deterministic command dictionary** in `BarkCore`
that covers the common cases — *"delete that"*, *"undo"*, *"select all"*, *"copy"*,
*"scratch that"* — as AX actions, not text rewrites. This means the feature works in **every
build**, not just the MLX build, with no model download, no latency, no failure mode beyond AX
automation brittleness.

The dictionary is a hard-coded table today; the spec calls it out as "P2" precisely because it's
the no-LLM fast path. A future iteration could let users add phrases.

### 3. `RevisionEngine` protocol with two implementations

```swift
public protocol RevisionEngine: Sendable {
    func revise(previous: String, instruction: String, mode: Mode) async throws -> RevisionOutcome
}
```

- `DeterministicRevisionEngine` (in `BarkCore`, always available) — dictionary lookup.
- `LLMRevisionEngine` (in `BarkCleanupMLX`, gated by `#if MLXCleanup`) — calls
  `MLXTextCleaner.clean(...)` with a revision prompt.

The protocol returns `RevisionOutcome { text(String), action(RevisionAction), miss(String) }` so
the controller can dispatch on outcome without leaking engine details. `text` is a rewrite;
`action` is an AX action; `miss` means "no rule matched; ask the user" (or, in the MLX build,
escalate to the LLM engine).

### 4. Per-mode revision prompts (US4)

`Mode` gains an optional `revisionPrompt: String?`. Built-in modes have `defaultRevisionPrompt`
defined as a static table in `BarkCore` — `Email` keeps register, `Code` preserves identifiers,
`Commit` becomes a single-line subject, etc. Custom modes without an explicit `revisionPrompt`
fall back to the Clean default. This is one of the spec's high-leverage moves because it means
revision is *useful* per context, not generic.

### 5. History linkage via `parentID: UUID?`

`HistoryRecord` extends with an optional `parentID`. The encrypted store tolerantly decodes old
records (no migration step). Every revision produces a record with `parentID` set; the History
pane surfaces a *child of previous* badge. The re-insert path is unchanged — users can re-insert
any record, parent or child, into the focused field.

The link is one-deep in v1; multi-step chains are visible (each step has a parent reference) but
the History pane doesn't render a tree view yet. That's a UI follow-up, not a data-model follow-up.

### 6. Security: re-run every existing control + new length-drift rule

Revisions re-run:

- `SecureFieldPolicy` — refuse on `AXSecureTextField` / `IsSecureEventInputEnabled`.
- `FocusGuard.targetUnchanged` — re-verify focused app's PID immediately before application.
- `TextSanitizer` — strip C0/C1, ANSI escapes, bidi characters.
- `OutputValidator` — now gains a **length-drift rule**: the revised text must be ≤ 2× the
  previous text's length. This catches the "expand to include a phishing URL" prompt-injection
  pattern even if all other fences fail.
- `PromptTemplate.revisionSystem(for:)` — the spoken instruction is fenced as `<revision>` (user
  data, not instruction), the previous text as `<previous>` (also user data). Mirrors SEC-010.

The hard guarantee that holds everywhere: **Bark never synthesises Return/Enter, and revisions
are text-in / text-out, never keystroke automation on a selection.** (The dictionary actions that
touch the keyboard — ⌘Z, ⌘A, ⌘C — are intentional, listed as a separate security section in
`docs/SECURITY.md`.)

### 7. Latency: bounded by existing `cleanupDeadline`

A revision call uses the existing `withThrowingDeadline(seconds:)` wrapper around the
`LLMRevisionEngine.revise` call. On timeout or any error, the controller preserves the original
text and surfaces a clear refusal — *never* destroys the field. This mirrors the
"deterministic fallback" pattern in `DictationController.produceText`.

## Consequences

- **Lean build wins.** The feature ships in the lean build today; the MLX build adds
  free-form revisions on top. No new network events, no new dependencies.
- **Protocol contract holds.** `RevisionEngine` is a new protocol, but `STTEngine`,
  `TextCleaner`, `TextInjector`, `SecureFieldPolicy`, `FocusGuard`, `TextSanitizer` are all
  unchanged. The controller composition root grows by one dependency.
- **History migration is forward-compatible.** Old records decode with `parentID = nil`. The
  encrypted store re-encodes atomically on first write.
- **STRIDE update.** `docs/SECURITY.md` gains a "Revision surface" section with the controls
  above and an honest residual-risks list (AX automation brittleness in Electron apps; spoken
  instruction as a prompt-injection vector).
- **Test coverage grows by ~18 tests** (per `tasks.md`): dictionary commands, history linkage,
  secure-field refusal, focus-guard re-check, validation.

## Alternatives considered

- **Mode of push-to-talk hotkey, voice command ("revise that…").** Rejected: ambiguous intent;
  harder to debug; conflates two different user intentions. A separate keypress is cleaner.
- **Built-in LLM only, no dictionary.** Rejected: the feature would be gated on the MLX build,
  contradicting Bark's "lean build is the daily driver" philosophy. The dictionary is the
  no-LLM fast path; the LLM is the long tail.
- **Direct field-text read + replace via AX range manipulation.** Considered as primary; rejected
  as default because AX range support is inconsistent (Electron apps, web views). The plan falls
  back to "select-all + replace via the existing `PasteboardInjector`" — same proven path as
  every other Bark injection.
- **Multi-turn revision dialog.** Out of scope per spec. One utterance → one rewrite. If usage
  data shows demand for "re-revise", that's a follow-up spec.

## Verification

- `swift build` clean (lean + MLX). `swift test` green; ~18 new tests cover:
  - `DeterministicRevisionEngine` happy paths (each dictionary entry → expected outcome)
  - `LLMRevisionEngine` validation: length drift, control chars, banned tokens
  - `HistoryRecord` parent linkage round-trip
  - `DictationController.reviseLastInjection` end-to-end with fakes
  - Settings round-trip: `revisionHotkey` + `revisionEnabled` survive encode/decode
- Manual: dictate → revise → revise → revert via History pane (lean build uses dictionary
  commands; MLX build uses LLM). Documented as on-device-only per constitution L-5.
- SECURITY.md ☐ → ☑ for the revision surface (separate update in this PR).

## Related

- `specs/009-voice-driven-revision/spec.md` — the user stories, acceptance criteria, success
  criteria, and out-of-scope calls.
- `specs/009-voice-driven-revision/plan.md` — implementation approach, files, risks.
- `specs/009-voice-driven-revision/tasks.md` — 9 phases, ~32 tasks.
- `docs/SECURITY.md` — STRIDE addition for the revision surface.
- `docs/COMPETITIVE_ANALYSIS.md` — gap analysis that ranked this #1.