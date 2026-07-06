# Tasks: Prompt Transparency & Editing

**Input**: Design documents from `/specs/013-prompt-editing/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/settings-schema.md, quickstart.md

**Tests**: Included — Constitution Quality Gates require pure logic to be unit-tested (`swift test` green with output shown).

**Organization**: Grouped by user story; each story is independently testable.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: US1 (view), US2 (edit built-in + reset), US3 (edit custom full prompt)

## Phase 1: Setup

- [x] T001 Create feature branch `013-prompt-editing` from `main` (git checkout -b)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Override model + effective-mode plumbing every story reads through.

- [x] T002 Create `PromptOverride` struct (Codable/Sendable/Equatable; optional `systemPrompt`/`revisionPrompt`; `isEmpty`; `maxFieldLength = 4_000`; `validated()` rejecting over-limit fields) and `Mode.applyingOverride(_:)` copy helper in `Sources/BarkCore/Cleanup/PromptOverride.swift`
- [x] T003 Add `builtInPromptOverrides: [String: PromptOverride]` to `Settings` (default `[:]`, lenient `decodeIfPresent` decode), add `effectiveModes()` (built-ins with overrides applied + customs), and rebase `makeModeRegistry()` on it in `Sources/BarkCore/Settings/Settings.swift`
- [x] T004 Rebase `DictationController.modes` on `settings.settings.effectiveModes()` and add override API — `builtInOverride(id:)`, `setBuiltInOverride(id:_:)` (built-in-id guard, length validation, prune empty/default-equal), `isBuiltInModified(id:)`; add same length validation to `upsertMode` — in `Sources/Bark/DictationController.swift`
- [x] T005 [P] Add `PromptOverrideTests` (override application; nil vs empty-string semantics; default-equal pruning predicate; 4,000-char limit rejection; unknown-key inertness via `effectiveModes()`; byte-identity: `PromptTemplate.system(for:)`/`refineSystem(for:)` on an overridden mode start with the guardrail constants and contain the override text; empty task → generic fallback string) in `Tests/BarkCoreTests/PromptOverrideTests.swift`
- [x] T006 [P] Extend `SettingsTests` (encode/decode round-trip with overrides; legacy payload without `builtInPromptOverrides` decodes to `[:]`; `makeModeRegistry()` reflects overrides) in `Tests/BarkCoreTests/SettingsTests.swift`
- [x] T007 Run `swift build && swift test` — all green before UI work (Constitution gate)

**Checkpoint**: Core model proven; UI stories can start.

---

## Phase 3: User Story 1 — View the exact prompt a mode uses (P1) 🎯 MVP

**Goal**: Any mode's full, exact prompt (guardrail + task + refinement) visible from Settings › Modes; non-LLM modes say no prompt is sent.

**Independent test**: Open each built-in mode in settings; displayed text matches `PromptTemplate.system(for:)`/`refineSystem(for:)` verbatim; "Clean" shows the no-prompt statement.

- [x] T008 [US1] Create `PromptEditorView` (read-only pass first): guardrail sections rendered verbatim from `PromptTemplate.guardrail`/`refineGuardrail` with locked styling + "Task: "/"Instruction style: " scaffold; task & refinement text shown in full; empty-field fallback notes rendered from the same constants (`"Fix grammar, punctuation, and capitalization."`, `PromptTemplate.genericRefineInstruction`); non-LLM modes show "No prompt is sent for this mode" and hide prompt sections — in `Sources/Bark/UI/SettingsView.swift`
- [x] T009 [US1] Make built-in AND custom rows in `ModesPane` open `PromptEditorView` for their mode (built-ins read-only until US2) in `Sources/Bark/UI/SettingsView.swift`
- [x] T010 [US1] Validate scenarios 1–2 of `specs/013-prompt-editing/quickstart.md` — byte-identity + display-source unit tests pass (PromptOverrideTests); live-app walkthrough left to reviewer (GUI session required, see PR notes)

**Checkpoint**: Transparency shipped — auditable prompts without any editing.

---

## Phase 4: User Story 2 — Edit a built-in mode's prompt and reset to default (P2)

**Goal**: Built-in task/refinement instructions editable with persistence, "Modified" badge, one-click reset, 4,000-char bound, explicit empty-fallback note.

**Independent test**: Edit Email's task instruction → next dictation follows it and survives relaunch; reset restores shipped text exactly and clears badge.

- [x] T011 [US2] Make `PromptEditorView` editable for built-ins: bind task/refinement fields to a draft `PromptOverride`; live character count with hard 4,000 limit disabling Save; Save calls `controller.setBuiltInOverride`; Cancel discards — in `Sources/Bark/UI/SettingsView.swift`
- [x] T012 [US2] Add "Reset to Default" footer action (enabled only when `isBuiltInModified`; calls `setBuiltInOverride(id:, nil)` and refreshes fields to shipped text) and "Modified" badge on built-in rows in `ModesPane` — in `Sources/Bark/UI/SettingsView.swift`
- [x] T013 [P] [US2] Add controller-level tests with existing fakes (set/get/reset override round-trip through `SettingsStore`; built-in-id guard rejects custom ids; over-limit rejected; default-equal edit prunes to unmodified) in `Tests/BarkAppTests/DictationControllerPromptOverrideTests.swift`
- [x] T014 [US2] Validate scenarios 3–7 of `specs/013-prompt-editing/quickstart.md` — persistence/reset/limit/fallback covered by DictationControllerPromptOverrideTests (incl. store-relaunch survival); live-app walkthrough left to reviewer

**Checkpoint**: Headline capability shipped.

---

## Phase 5: User Story 3 — Edit a custom mode's full prompt text (P3)

**Goal**: Custom modes expose task AND refinement instructions on create and re-edit, through the same editor surface.

**Independent test**: Create custom mode, reopen, edit both fields; both persist and drive rewrite + hold-to-refine.

- [x] T015 [US3] Route custom-mode create/edit through `PromptEditorView` (replacing the old minimal `ModeEditor` fields): name + LLM toggle + full prompt sections including refinement instruction with generic-fallback note; keep existing save path (`controller.upsertMode`) — in `Sources/Bark/UI/SettingsView.swift`
- [x] T016 [P] [US3] Extend `PromptOverrideTests` or `SettingsTests` with custom-mode coverage (revisionPrompt persists through Settings round-trip; `refineSystem(for:)` uses it; legacy custom mode without `revisionPrompt` decodes and shows generic fallback) in `Tests/BarkCoreTests/`
- [x] T017 [US3] Validate scenario 8 of `specs/013-prompt-editing/quickstart.md` — round-trip + refine-drive covered by core tests; live-app walkthrough left to reviewer

**Checkpoint**: All three stories complete.

---

## Phase 6: Polish & Cross-Cutting

- [x] T018 Full gate: `swift build` clean + `swift test` green; record output (Constitution II)
- [x] T019 [P] Verify guardrail immutability end-to-end (scenario 9: no editable guardrail surface; assembled previews always start with guardrail) and SC-001 byte-identity across all six built-ins with and without overrides
- [x] T020 Adversarial review of the diff per Constitution workflow; fix or document flagged correctness/security issues; commit, push branch, open PR with evidence

---

## Dependencies

```text
T001 → T002 → T003 → T004 → {T005, T006} → T007
T007 → US1 (T008 → T009 → T010)
US1 UI (T008) → US2 (T011 → T012 → {T013} → T014)
US1 UI (T008) → US3 (T015 → {T016} → T017)   # US3 independent of US2
{US1, US2, US3} → T018 → {T019} → T020
```

- US2 and US3 both build on the US1 editor view but are independent of each other → parallelizable after T009.
- [P] tasks touch distinct files and can run concurrently.

## Parallel Examples

- After T004: T005 and T006 together (different test files).
- After T009: T011 (US2) and T015 (US3) in parallel — same file `SettingsView.swift`, so only if split across agents with worktree isolation; otherwise sequence US2 → US3.
- T013 alongside T012; T016 alongside T015 wrap-up; T019 alongside T018 evidence capture.

## Implementation Strategy

**MVP**: Phase 2 + US1 (T001–T010) — full prompt transparency, zero risk. Then US2 (headline edit/reset), then US3, then polish. Each checkpoint is shippable.
