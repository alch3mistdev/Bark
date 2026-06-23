---
description: "Task list for In-session voice refinement (hold-to-refine)"
---

# Tasks: In-session voice refinement (hold-to-refine)

**Input**: Design documents from `/specs/012-staged-refinement/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: INCLUDED — SC-007 and constitution principle II ("Evidence or It Didn't Happen") require
unit + integration coverage. Pure-logic tests are written before their implementation.

**Organization**: Phases ordered by priority. P1 stories (US1, US2, US6) precede P2 stories (US3,
US4, US5). Each user-story phase is an independently testable increment.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on an incomplete task)
- **[Story]**: US1–US6 (story phases only)
- Paths follow the three-layer package: `Sources/BarkCore` (pure), `Sources/BarkEngines` (OS/ML),
  `Sources/BarkCleanupMLX` (MLX), `Sources/Bark` (app), `Tests/BarkCoreTests`, `Tests/BarkAppTests`.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Baseline + workspace for the new pure module.

- [X] T001 Capture a pre-change baseline: run `swift build` (lean) and the MLX config build green, and
  record the injected text of a no-left-option dictation as the SC-002/SC-003 reference (base path
  must stay byte-identical).
- [X] T002 [P] Confirm `Sources/BarkCore/Refine/` is picked up by SwiftPM (new source group; no new
  target — existing `BarkCore`/`BarkEngines`/`BarkCleanupMLX`/`Bark` targets are reused).

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Pure types, protocol/prompt, persistence, hotkey wiring, and test fakes that every story
depends on. **No story can begin until this phase is complete.**

**⚠️ CRITICAL**: Pure-logic tests (T003–T005) are written first and must FAIL before T006/T007/T011.

- [X] T003 [P] Write `Tests/BarkCoreTests/RefineSessionTests.swift` covering the 9-row behavior table
  in `contracts/refine-session.md` (append/applyRefine/undo/keepOnFailure/canUndo). Must fail first.
- [X] T004 [P] Write `Tests/BarkCoreTests/RefineKeyDecoderTests.swift` covering the decode table in
  `contracts/refine-key-decoder.md` (left 58 vs right 61, fn-gating, no double-fire). Must fail first.
- [X] T005 [P] Write `Tests/BarkCoreTests/PromptTemplateRefineTests.swift` covering the refine-prompt
  table in `contracts/text-cleaner-refine.md` (per-mode vs generic, closing-tag neutralization). Must fail first.
- [X] T006 [P] Implement `Sources/BarkCore/Refine/RefineSession.swift` (pure `struct`: `draft`,
  `snapshots`, `context`; `appendDictation`/`beginInstruction`/`applyRefine`/`keepOnFailure`/`undo`/
  `canUndo`) per `contracts/refine-session.md` → makes T003 pass.
- [X] T007 [P] Implement `Sources/BarkCore/Refine/RefineKeyDecoder.swift` (pure: `leftOptionKeycode =
  58`, `decide(alternateOn:keycode:fnHeld:auxHeld:) -> RefineKeyEvent?`) per
  `contracts/refine-key-decoder.md` → makes T004 pass.
- [X] T008 [P] Edit `Sources/BarkCore/Cleanup/Mode.swift`: add `revisionPrompt: String?` (Codable,
  tolerant decode → default `nil`), seed `email`/`code` revision prompts per `data-model.md`.
- [X] T009 [P] Edit `Sources/BarkCore/Settings/Settings.swift`: add `holdToRefineEnabled: Bool`
  (default `true`, `decodeIfPresent` fallback) per `data-model.md`.
- [X] T010 Edit `Sources/BarkCore/Cleanup/TextCleaner.swift`: add
  `refine(_:instruction:mode:) async throws -> String` with a default extension throwing
  `CleanupError.modelUnavailable` (deterministic cleaners decline) per `contracts/text-cleaner-refine.md`.
- [X] T011 Edit `Sources/BarkCore/Cleanup/PromptTemplate.swift`: add `refineSystem(for:)`
  (guardrail + `mode.revisionPrompt ?? generic`) and `refineUser(draft:instruction:)` (fenced
  `<text>`/`<instruction>`, closing-tag neutralized). Depends on T008 → makes T005 pass.
- [X] T012 Edit `Sources/BarkCleanupMLX/MLXTextCleaner.swift`: implement `refine(...)` using
  `PromptTemplate.refineSystem/refineUser` + `OutputValidator.validate(_:against:)` (MLX build).
  Depends on T010, T011.
- [X] T013 Edit `Sources/BarkEngines/Hotkey/HotkeyManager.swift`: add `onRefineStart`/`onRefineEnd`
  callbacks; in the `.flagsChanged` path, while `holding` (push-to-talk modifier held), feed
  (alternateOn, keycode, fnHeld, auxHeld) to `RefineKeyDecoder` and fire callbacks; track `auxHeld`;
  never consume (`return false`). Wire these callbacks only on the push-to-talk `hotkey` manager,
  **not** `handsFreeHotkey` — this structurally satisfies FR-015 (toggle/hands-free unaffected).
  Depends on T007.
- [X] T014 [P] Extend `Tests/BarkAppTests/Fakes.swift`: give `FakeCleaner` a canned `refine` (success
  string / `.fail` / `.hang`) mirroring its existing `clean` modes, for flow tests.

**Checkpoint**: Pure primitives green; protocol/prompt/persistence/hotkey ready; fakes ready.

---

## Phase 3: User Story 1 - Single refinement before injection (Priority: P1) 🎯 MVP

**Goal**: One left-option turn rewrites the draft via the LLM; fn-release injects the refined text.

**Independent Test**: Hold fn → "hello my name is foo"; hold left-option → "make it sound very
happy" → release option (HUD shows happy rephrase) → release fn → happy text injected, not the base.

- [X] T015 [P] [US1] Write the single-refinement flow test (spec example 2) in
  `Tests/BarkAppTests/RefineSessionFlowTests.swift` using `FakeSTTEngine`/`ScriptedAudioCapture`/
  `FakeCleaner`/`FakeInjector`: base captured, one instruction, injected text = canned refine result. Must fail first.
- [X] T016 [US1] Rework the push-to-talk capture in `Sources/Bark/DictationController.swift` into a
  single open-mic, multi-segment loop modeled on `runHandsFree` (begin/feed/`finishStream` per
  segment); with no left-option press the injected text is identical to the T001 baseline.
- [X] T017 [US1] In `DictationController`: hold a `RefineSession`, add observables `currentDraft` and
  `refineActivity`, and wire `hotkey.onRefineStart`/`onRefineEnd` in `activate()`. On a
  dictation-segment boundary (first option-down, or fn-up with no option pressed), mode-clean the
  segment via the existing `produceText` and `RefineSession.appendDictation`; the **first** such chunk
  seeds the base draft = selected-mode output (FR-004) — so US1 is independently functional without
  US3.
- [X] T018 [US1] In `DictationController`: on option-up, finish the instruction segment and call
  `llmCleaner.refine(draft, instruction, mode)` wrapped in `withThrowingDeadline(cleanupDeadline)`;
  validate → `RefineSession.applyRefine`; on empty instruction → `undo()`; on error/timeout →
  `keepOnFailure()` + `Feedback.declined()` cue (FR-002/007/010).
- [X] T019 [US1] In `DictationController`: on fn-up, inject the final `draft` through the existing
  `performInjection` (unchanged secure-field/focus-guard/sanitizer/no-Return); intermediate drafts
  never injected.
- [X] T020 [US1] In `Sources/Bark/UI/RecordingHUDView.swift`: show `currentDraft` and a "refining…"
  indicator while `refineActivity == .refining` (full three-state styling lands in US4).

**Checkpoint**: Single in-session refinement works end-to-end; base path unregressed. MVP shippable.

---

## Phase 4: User Story 2 - Chained refinements (Priority: P1)

**Goal**: Repeat the gesture; each instruction builds on the prior result; only the final draft injects.

**Independent Test**: Spec example 3 — "change name to bar" then "make a longer introduction" → the
long introduction injects; intermediate drafts never reach the field.

- [X] T021 [P] [US2] Write the chained-refinement flow test (spec example 3 + intermediate-not-injected
  + FIFO ordering + **repeatable empty-tap undo down to the base draft**, SC-008) in
  `Tests/BarkAppTests/RefineSessionFlowTests.swift`. Must fail first.
- [X] T022 [US2] In `DictationController`: serialize refine turns FIFO via a chained task so a turn
  started before the prior finishes applies to the latest draft, in order (FR-003/FR-008).
- [X] T023 [US2] In `DictationController`: on fn-up, await the in-flight turn (≤ `cleanupDeadline`)
  before injecting; guarantee only the final draft is injected (FR-006/FR-009, SC-005).

**Checkpoint**: Multi-turn chaining + undo (from T018) work; only final draft injects.

---

## Phase 5: User Story 6 - Security parity at injection (Priority: P1)

**Goal**: Instruction treated as untrusted data; final injection re-runs all existing controls.

**Independent Test**: Start a refine session targeting TextEdit, switch focus to a password field
before fn-release → injection refused with the standard secure-field message; field untouched.

- [X] T024 [P] [US6] Write security flow tests in `Tests/BarkAppTests/RefineSessionFlowTests.swift`:
  secure-field refusal mid-session (FakeInjector secure-field error), instruction with a literal
  `</instruction>` neutralized end-to-end, and undo/intermediate never injecting. Must fail first.
- [X] T025 [US6] In `DictationController`: confirm the fn-release injection uses the unchanged
  `performInjection` path (secure-field, focus-guard PID re-check, `TextSanitizer`, no Return/Enter);
  add a guard/assertion if any refine path bypasses it (FR-014).
- [X] T026 [US6] Update `SECURITY.md`: add a STRIDE entry for the spoken-instruction surface (fenced
  via `PromptTemplate`, bounded by `OutputValidator`, injects only at fn-release) with honest residuals.

**Checkpoint**: Refine surface re-verifies Bark's security posture; documented.

---

## Phase 6: User Story 3 - Continue dictating between refinements (Priority: P2)

**Goal**: Speech with option not held appends (mode-cleaned) to the running draft; first chunk = base.

**Independent Test**: "first point" → bullet-list it → "second point" (appended) → "tighten it" →
final draft contains both points, tightened.

- [X] T027 [P] [US3] Write the append-between-turns flow test (base = selected-mode output of the
  first chunk; later dictation appended; subsequent refine sees the combined draft) in
  `Tests/BarkAppTests/RefineSessionFlowTests.swift`. Must fail first.
- [X] T028 [US3] In `DictationController`: reuse the segment-boundary append from T017 for dictation
  segments that occur **after** a refinement — re-enter `.dictation` context on option-up so further
  speech is mode-cleaned and appended to the running draft, and the next refinement sees the combined
  text (FR-005). (Base-seeding itself is T017; this task covers the between-refinement case + its test.)

**Checkpoint**: Dictation can be interleaved with refinements within one fn hold.

---

## Phase 7: User Story 4 - Live HUD feedback (Priority: P2)

**Goal**: HUD distinguishes dictating / capturing-instruction / refining and shows the current draft.

**Independent Test**: Run a two-turn refinement and observe the HUD move dictating → instruction →
"refining…" → updated draft for each turn.

- [X] T029 [P] [US4] Write a HUD-state test asserting `refineActivity` transitions
  (`.dictating`/`.capturingInstruction`/`.refining`/`.none`) across boundaries in
  `Tests/BarkAppTests/RefineSessionFlowTests.swift`. Must fail first.
- [X] T030 [US4] In `DictationController`: drive `refineActivity` through all four states at the
  segment/turn boundaries (FR-012).
- [X] T031 [US4] In `Sources/Bark/UI/RecordingHUDView.swift`: render the three active states
  distinctly (compact + enhanced layouts) and the evolving `currentDraft`.

**Checkpoint**: The multi-turn flow is legible in the HUD.

---

## Phase 8: User Story 5 - Graceful behavior without the LLM (Priority: P2)

**Goal**: Without an available LLM or with the toggle off, left-option is a no-op; base injects as today.

**Independent Test**: Lean build (or toggle off) → holding left-option does nothing; base dictation
injects exactly as today; a one-time hint notes refinement needs the LLM.

- [X] T032 [P] [US5] Write fail-open flow tests (no LLM cleaner → left-option ignored, base injects;
  `holdToRefineEnabled == false` → no-op) in `Tests/BarkAppTests/RefineSessionFlowTests.swift`. Must fail first.
- [X] T033 [US5] In `DictationController`: gate the refine path on `holdToRefineEnabled &&
  llmAvailable && llmEnabled && llm.isAvailable`; when off, ignore `onRefineStart`/`onRefineEnd` and
  keep all speech as dictation; surface the "refinement needs the LLM" hint guarded by an in-memory
  `refineHintShown` flag (session-scoped, set on first show, not persisted) so it appears once per app
  run; expose `holdToRefineEnabled` get/set (settings passthrough). (FR-011/FR-017)
- [X] T034 [US5] In `Sources/Bark/UI/SettingsView.swift`: add an "Enable hold-to-refine" toggle
  (shown only when the LLM engine is present) bound to `holdToRefineEnabled`.

**Checkpoint**: Lean build and toggle-off collapse to today's behavior; opt-out reachable.

---

## Phase 9: Polish & Cross-Cutting Concerns

- [ ] T035 [P] Run `quickstart.md` manual validation: the three examples + undo + right-option,
  no-LLM, fail-open, and secure-field negative checks. *(On-device-only, per constitution L-5 — the
  same scenarios are covered automatically by `RefineSessionFlowTests`; live macOS GUI run pending.)*
- [X] T036 `swift build` (lean) + MLX build clean; `swift test` green with output captured (SC-007).
- [X] T037 [P] Document the hold-to-refine gesture in `README.md` (and any onboarding copy).
- [X] T038 Adversarial review (Codex + ef-adversary) on the diff per the constitution workflow; fix
  or explicitly document accepted findings.
- [X] T039 [P] Verify FR-015: integration test in `Tests/BarkAppTests/RefineSessionFlowTests.swift`
  that a hands-free / key-toggle session ignores left-option entirely (no refine, no draft change, no
  injection difference) — confirms the second stage is push-to-talk-only.

---

## Dependencies & Execution Order

### Phase dependencies

- **Setup (P1)** → no deps.
- **Foundational (P2)** → after Setup; **blocks all stories**. Tests T003–T005 before T006/T007/T011.
- **US1 (P3)** → after Foundational. The MVP; its capture rework (T016) underpins later stories.
- **US2, US6** → after US1 (need a working refine session to chain / to inject-test).
- **US3, US4, US5** → after US1; independent of US2/US6 and of each other (different concerns).
- **Polish (P9)** → after all desired stories.

### Key intra-feature dependencies

- T011 depends on T008 (`Mode.revisionPrompt`); T012 depends on T010 + T011; T013 depends on T007.
- T017–T020 depend on T016 (the capture loop) and the foundational types.
- T022/T023 depend on T018 (single-turn apply). T028 depends on T016/T017. T030/T031 depend on T017.
- T033/T034 depend on T009 (`holdToRefineEnabled`) + T017.

### Parallel opportunities

- Setup: T002 ∥ T001-tail.
- Foundational: T003/T004/T005 (tests) ∥; then T006/T007/T008/T009 ∥; T014 ∥ throughout.
- Each story's test task is `[P]` relative to that story's **implementation** tasks (different
  files), so it can be authored while the impl proceeds.
- Cross-story (after US1): US3, US4, US5 **implementation** can proceed in parallel by different
  people. ⚠️ Their flow-test tasks (T021/T024/T027/T029/T032/T039) all extend the single file
  `Tests/BarkAppTests/RefineSessionFlowTests.swift`, so those test edits are **serialized** (one
  owner or sequential merges) despite the `[P]` marker — `[P]` there means "parallel with non-test
  tasks", not with each other.

---

## Parallel Example: Foundational

```bash
# Author the three pure-logic test suites together (all must fail first):
Task: "RefineSessionTests in Tests/BarkCoreTests/RefineSessionTests.swift"
Task: "RefineKeyDecoderTests in Tests/BarkCoreTests/RefineKeyDecoderTests.swift"
Task: "PromptTemplateRefineTests in Tests/BarkCoreTests/PromptTemplateRefineTests.swift"

# Then implement the independent pure/persistence pieces together:
Task: "RefineSession.swift in Sources/BarkCore/Refine/"
Task: "RefineKeyDecoder.swift in Sources/BarkCore/Refine/"
Task: "Mode.revisionPrompt in Sources/BarkCore/Cleanup/Mode.swift"
Task: "Settings.holdToRefineEnabled in Sources/BarkCore/Settings/Settings.swift"
```

---

## Implementation Strategy

### MVP (User Story 1 only)

1. Setup → Foundational (pure types, prompt, hotkey, fakes).
2. US1: capture rework + single refine turn + inject final + minimal HUD.
3. **STOP & VALIDATE**: example 2 works; no-option base path byte-identical (T001 baseline).

### Incremental delivery

US1 (MVP) → US2 (chaining) → US6 (security parity) → US3 (append) → US4 (HUD polish) → US5
(no-LLM/toggle). Each adds value without breaking the prior; ship/demo at any checkpoint.

---

## Notes

- [P] = different files, no incomplete dependency. [US#] maps to spec user stories for traceability.
- Tests-first for pure logic; verify they fail before implementing.
- The single hardest task is T016 (capture rework); guard it with the T001 baseline + T015 flow test.
- Commit per task or logical group; stop at any checkpoint to validate a story independently.
