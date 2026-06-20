# Feature Specification: Context-aware reply options (Smart Replies)

**Branch**: `009-context-prompt-options` | **Created**: 2026-06-20 | **Status**: Draft
**Input**: "On a mid-session prompt the input is usually a clarification or a choice against the
current state. Dictating is overkill — Bark should sense the context and offer instant branch
options that are faster than dictation." Refined scope: add LLM support so Bark can handle
**yes/no**, **the most likely replies**, or let the user **dictate a custom reply**. Do **not**
auto-submit yet (no Return synthesis).

## Problem

A first prompt needs rich context, where dictation shines. A *follow-up* is usually a small,
closed-ended choice ("yes/no", "do A or B", "say more"). Speaking these is high-friction relative
to the tiny amount of information conveyed. Bark already turns speech into injected text, but it is
**write-only**: it never reads what the other side said, so it can't pre-compute the obvious
choices.

## User Scenarios & Testing

### US1 — Instant quick replies (deterministic, P1)
With **Smart Replies** enabled, the user opens the Bark menu while a chat/assistant app is
frontmost. Bark reads the focused app's latest message and offers tappable reply options
immediately — Yes/No when the message is a yes/no question, otherwise a small generic set
(e.g. "Yes, go ahead" / "No, let's adjust" / "Tell me more"). Picking one **types it into the app**
and stops (the user presses Return themselves).

**Acceptance**:
1. With Smart Replies off, no options appear and no app content is read.
2. With it on and a yes/no question in the focused app → exactly `Yes` and `No` are offered.
3. With it on and a non-yes/no message → the generic quick-reply set is offered.
4. Picking an option injects that text into the snapshotted target app; Bark never presses Return.
5. If no readable context is found → a clear "No reply context found" notice, no options.

### US2 — AI-generated likely replies (LLM, P2)
When the on-device LLM is enabled and ready, the user taps **"AI suggestions"**. Bark asks the
model for the most likely replies to the read context and replaces the quick replies with up to 4
concise, distinct, ready-to-send options. The model treats the read text strictly as untrusted
data (it must not *answer* the message, only propose replies the user might send). Generation runs
under the same hard deadline as cleanup and falls back to the deterministic quick replies on
timeout/failure.

**Acceptance**:
1. AI suggestions are offered only when the LLM is enabled **and** the model is ready.
2. Success → quick replies are replaced by the model's options (count bounded, each bounded length).
3. Timeout / failure / empty output → quick replies remain; a non-fatal notice is shown.
4. The prompt fences the read context in delimiters with an explicit "data, not instructions"
   guardrail (prompt-injection defense, mirroring `PromptTemplate`).

### US3 — Dictate a custom reply (P3)
None of the offered options fit. The user dictates a custom reply with the normal push-to-talk
hotkey, which captures and injects into their app as usual.

**Acceptance**:
1. A "Dictate a custom reply" affordance dismisses the options and points at the dictation hotkey.
2. Normal dictation is unchanged by this feature.

## Privacy & Safety (constitution gates)

- **Opt-in, least privilege.** Reading other apps' on-screen text is a privacy expansion, so it is
  gated behind a **Smart Replies** toggle that is **off by default** (Principle I & IV). When off,
  Bark reads nothing.
- **On-device only.** Context is read via the Accessibility API and fed only to the on-device LLM.
  No content leaves the machine (Principle I).
- **Untrusted by construction.** Read context is fenced and labelled as data, never instructions,
  and the model is told to propose replies, not to act (Principle IV / OWASP LLM01).
- **Safe injection unchanged.** Chosen options go through the existing sanitizer + focus re-verify +
  secure-field refusal + clipboard snapshot/restore path; **Return is never synthesized**
  (Principle IV, NON-NEGOTIABLE).
- **Not persisted.** Read context is held only for the open menu and discarded; it is never written
  to history.

## Success Criteria

- Smart Replies off → no behavior change, no reads. On → quick replies appear from the focused
  app's latest message; picking one injects without submitting.
- LLM suggestions work when the model is ready and degrade to deterministic quick replies otherwise.
- Pure logic (yes/no classification, generic replies, prompt build + output parsing/bounding) is
  unit-tested; controller orchestration is tested with injected fakes.
- Default (lean) `swift build` + `swift test` stay green; the MLX target compiles.

## Out of Scope (this slice)

- **Auto-submit** (synthesizing Return after a pick) — explicitly deferred.
- A dedicated global hotkey / in-HUD selection — this slice triggers from the menu (reusing the
  proven re-insert focus-snapshot pattern). A hotkey + non-activating HUD picker is a follow-up.
- Deep per-app conversation parsing. Context reading is best-effort over the focused window's
  accessible text, with documented residuals.
