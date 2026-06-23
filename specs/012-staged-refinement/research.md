# Research: In-session voice refinement (hold-to-refine)

Phase 0 decisions. Each resolves an unknown surfaced by the Technical Context.

## D1 — How to segment base vs instruction speech without closing the mic

**Decision**: Drive the push-to-talk session through a single open-mic capture loop that cycles
`STTEngine.beginStream()` / `finishStream()` at each context boundary (left-option down/up), modeled
exactly on `runHandsFree` (`DictationController.swift:833`). The mic (`AudioCapturing`) stays open
for the whole fn hold; only STT streams restart per segment.

**Rationale**: `runHandsFree` already proves the pattern in this codebase — one audio stream, inline
`for await frames in stream { await stt.feed(frames) }`, with `beginStream`/`finishStream` cycled
per utterance and state re-armed between turns. Each cycle yields a clean, independently finalized
transcript, which is exactly what a segment (base chunk, instruction, appended dictation) needs.
Reusing a shipped mechanism beats inventing a parallel one (constitution III/V).

**Alternatives considered**:
- *Transcript-offset slicing over one uninterrupted stream*: keep today's single `beginStream` and
  record the `finalSegments` index at each boundary, slicing base vs instruction by index. Lower risk
  to the base path (no capture rework) but fragile: a word spoken just before option-down can finalize
  after the boundary, mis-attributing it. **Kept as the documented fallback** if the loop rework
  regresses SC-002/SC-003.
- *Two audio engines*: open a second mic for instructions. Rejected — violates "one mic owner"
  (`startDictation`/`startHandsFree` both guard on it) and wastes resources.

**Guardrail**: SC-002/SC-003 require the no-left-option output to stay byte-identical to today. The
loop must treat "fn held, never any left-option" as a single segment whose result flows through the
unchanged `produceText` → `performInjection`. Integration tests assert identical injected text.

## D2 — Distinguishing left option from right option

**Decision**: On a `.flagsChanged` event, read `event.getIntegerValueField(.keyboardEventKeycode)`;
left option is keycode **58** (`kVK_Option`), right option is **61** (`kVK_RightOption`). A refine
turn opens/closes only on keycode 58 with the alternate flag rising/falling, and only while the
push-to-talk modifier is already held. The pure `RefineKeyDecoder` makes this decision; `HotkeyManager`
just feeds it the event fields.

**Rationale**: `flagsChanged` events carry the changed key's keycode, so left/right *are*
distinguishable here — the `HotkeyPreset` "flags can't tell left from right" limitation refers to the
device-independent `CGEventFlags` used for the *primary* hotkey, not the per-event keycode. Putting
the logic in a pure decoder satisfies constitution II (the OS delivery is best-effort; the decode is
unit-tested) and keeps `HotkeyManager` thin.

**Alternatives considered**:
- *Device-dependent flag bits* (`NX_DEVICELALTKEYMASK 0x20` / `NX_DEVICERALTKEYMASK 0x40`): also
  encode left/right but are private/fragile across macOS versions. Keycode is the documented field.
- *Any option (left or right)*: rejected — the user explicitly chose left option (FR-001), and
  reserving right option avoids clobbering users who bind it elsewhere.

**Residual (named)**: exact keycode delivery on every hardware/layout is OS behavior we can't unit-test;
documented best-effort, with the pure decoder + an integration smoke test as the evidence (SC-004).

## D3 — Building the refine prompt (per-mode vs generic)

**Decision**: Add `TextCleaner.refine(_:instruction:mode:)`. `MLXTextCleaner` builds the prompt from
`PromptTemplate.refineSystem(for: mode)` using `mode.revisionPrompt ?? <generic refine instruction>`,
plus `PromptTemplate.refineUser(draft:instruction:)` which fences the draft in `<text>…</text>` and
the instruction in `<instruction>…</instruction>`, neutralizing literal closing tags (as
`PromptTemplate.user` already does). Output is bounded by `OutputValidator.validate(_:against:)`.
`Mode` gains `revisionPrompt: String?` — the **same field** feature 009 designed (009 is specced but
unimplemented), so the two features share it.

**Rationale**: Per-mode prompts preserve register (Email) and identifiers (Code), matching 009's
intent (the clarify session chose this). Reusing the existing fence pattern keeps the prompt-injection
defense consistent (constitution IV). A generic default means modes without a `revisionPrompt`
(Raw/Clean) still refine.

**Alternatives considered**:
- *Single generic prompt for all modes*: simpler but loses Email/Code register fidelity; rejected per
  the clarify answer (Q1 = A).
- *Overload `clean(_:mode:)` to carry the instruction*: rejected — pollutes the cleanup contract and
  conflates two operations; a distinct `refine` is clearer and lets deterministic cleaners decline.

**Build coupling**: `revisionPrompt` is introduced by whichever of 009/012 ships first; the other
reuses it. The generic fallback means 012 does **not** hard-depend on 009 (spec Assumption).

## D4 — Turn serialization and fn-release timing

**Decision**: Refine turns are serialized FIFO via a chained task in the controller (each turn awaits
the previous). fn-release awaits the single in-flight turn (bounded by `cleanupDeadline`) before
injecting `draft`. A turn that errors/times out keeps the prior draft (fail-open) and pushes no undo
snapshot.

**Rationale**: Matches FR-008/FR-009/FR-010 and reuses `withThrowingDeadline` (already in
`DictationController.swift:973`). Awaiting only the in-flight turn avoids injecting a stale draft
without unbounded blocking.

**Alternatives considered**: applying turns concurrently (rejected — order-dependent rewrites must be
sequential); injecting immediately on fn-release regardless of in-flight work (rejected — would drop
the last refinement, violating SC-005).

## D5 — Gating without the LLM

**Decision**: Refinement is active only when `holdToRefineEnabled && llmAvailable && llmEnabled &&
llm.isAvailable`. Otherwise the left-option callbacks are ignored and every segment is treated as
dictation; fn-release injects exactly as today.

**Rationale**: FR-011/FR-017 + constitution V (base dictation never blocked). The lean build
(`llmCleaner == nil`) and the toggle-off case collapse to today's behavior — verified by SC-003 and
the toggle-off test.
