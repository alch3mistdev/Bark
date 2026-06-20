# Tasks: Voice-driven revision of the last injection

**Input**: ./spec.md, ./plan.md, ../../docs/constitution.md
**Tests**: included (Principle II + US1/US3/US5 require them).

## Phase 1 — Setup
- [ ] T001 Spec Kit artifacts (spec, plan, tasks, quickstart) — this phase.

## Phase 2 — Foundational (blocks all stories)

- [ ] T010 [BarkCore] `RevisionEngine` protocol + `RevisionError` enum + `RevisionOutcome` /
      `RevisionAction` types (Sources/BarkCore/Revision/RevisionEngine.swift).
- [ ] T011 [BarkCore] `DeterministicRevisionEngine` — pure, hard-coded dictionary
      (`delete that` → .deleteSelection, `undo` / `undo that` → .systemUndo, `select all` /
      `select everything` → .selectAll, `copy` / `copy that` → .copy, `scratch that` /
      `forget it` → .deleteSelection, unknown → .miss(instruction)). Case-insensitive, single
      phrase, no punctuation.
- [ ] T012 [BarkCore] `Mode` extended with `revisionPrompt: String?` and a
      `defaultRevisionPrompt` static table (Raw/Clean/Email/Message/Code/Commit/List).
- [ ] T013 [BarkCore] `PromptTemplate.revisionSystem(for: Mode)` — fenced prompt mirroring
      `user(transcript:)` with `<previous>` and `<revision>` slots, and a `<rules>` block
      stating: "preserve meaning, preserve identifiers in code mode, do not add content the user
      did not ask for."
- [ ] T014 [BarkCore] `HistoryRecord` extended with `parentID: UUID?`. Tolerant decode (old
      payloads → parentID = nil). No explicit migration step is needed: the encrypted store rewrites
      the entire `[HistoryRecord]` file atomically on every `append`, so old records naturally
      re-encode with `parentID = nil` on the next write.

## Phase 3 — US1 + US5: Quick revise (the core feature, security-first)

- [ ] T020 [BarkCleanupMLX] `LLMRevisionEngine` (Sources/BarkCleanupMLX/LLMRevisionEngine.swift) gated by
      `#if MLXCleanup`. Real impl calls `MLXTextCleaner.clean(...)` with the revision prompt +
      previous text + instruction, then `OutputValidator.validate(revised, against: previous)`
      with the new "length drift ≤ 2×" rule. Stub under `#else` throws `RevisionError.llmUnavailable`.
- [ ] T021 [Bark] `DictationController.reviseLastInjection(instruction: String)` — applies the
      outcome, runs the existing security controls (US5):
        * `SecureFieldPolicy.refuses(target:)` → throw `secureFieldBlocked`
        * `FocusGuard.targetUnchanged(snapshot:, current:)` → throw `focusChanged`
        * `TextSanitizer.sanitize` on the revised text → insert
        * `PromptTemplate` fence around `previous` + `instruction`
- [ ] T022 [Bark] Revision hotkey wiring — second `HotkeyManager` instance (mirroring the
      hands-free hotkey pattern), `revisionHotkey: HotkeySetting` on `Settings`, default ⌥⌘R.
      `onStart` → capture; `onStop` → finalize instruction + call `reviseLastInjection`.
- [ ] T023 [Bark] Composition root wires the `DeterministicRevisionEngine` (always) and the
      `LLMRevisionEngine` (only in MLX builds). Controller takes a `revisionEngine: RevisionEngine`
      composed from those.
- [ ] T024 [BarkAppTests] Tests for US1 + US5:
        * happy path: STT instruction → LLM revision → field rewritten, history parent set
        * secure-field refusal: focused on a SecureTextField → refuses, lastError set
        * focus drift during LLM: PID changes → original text preserved, lastError set
        * validation miss: LLM output 5× previous length → original preserved, "Revision rejected"

## Phase 4 — US2: History linkage + re-insert

- [ ] T030 [Bark] History append now takes an optional `parentID`. The revision path sets it;
      the normal dictation path leaves it nil.
- [ ] T031 [Bark] `HistoryPane` renders a `child of previous` badge when `parentID != nil` and
      a parent chain (one chevron-deep is enough for v1).
- [ ] T032 [BarkAppTests] Tests for history linkage: revision → record with parentID; re-insert
      a parent → new record (parentID nil); re-insert a revision → new record (parentID nil); the
      original parent record is not mutated.

## Phase 5 — US3: Dictionary commands (no-LLM path)

- [ ] T040 [Bark] Apply `RevisionAction` to the focused field:
        * `.deleteSelection` → AX select-all + delete (or fall back to ⌘A then Delete)
        * `.systemUndo` → CGEventPost ⌘Z (with the existing "never synthesise Return" guard)
        * `.selectAll` → ⌘A
        * `.copy` → ⌘C
        * none of these produce a `HistoryRecord` (the field changed but Bark did not produce
          text)
- [ ] T041 [BarkAppTests] Tests for dictionary commands:
        * `delete that` → `.action(.deleteSelection)` recorded, no HistoryRecord appended
        * `undo` → `.action(.systemUndo)`, no HistoryRecord
        * `make this better` (lean build, no LLM) → `.miss(...)` surfaced to UI
- [ ] T042 [Bark] Lean-build smoke: with `MLXCleanup` undefined, every dictionary command works
      end-to-end via fakes; with `MLXCleanup` defined, the LLM path is exercised instead for
      unknown phrases.

## Phase 6 — US4: Per-mode revision prompts

- [ ] T050 [BarkCore] `defaultRevisionPrompt` table (Raw → none, Clean → "rewrite preserving
      meaning", Email → "rewrite in a professional, concise register", Code → "rewrite
      preserving identifiers verbatim and code formatting exactly", Commit → "rewrite as a
      single-line commit subject unless the user asked for a body", List → "rewrite as a
      comma-separated list").
- [ ] T051 [Bark] `LLMRevisionEngine.revise` resolves the prompt as: `mode.revisionPrompt ??
      mode.defaultRevisionPrompt`. Custom modes without `revisionPrompt` fall through to the
      Clean default.
- [ ] T052 [BarkAppTests] Tests for prompt resolution per mode.

## Phase 7 — US6: Settings UI

- [ ] T060 [Bark] `Settings.revisionHotkey: HotkeySetting` (default ⌥⌘R).
- [ ] T061 [Bark] `Settings.revisionEnabled: Bool` (default true).
- [ ] T062 [Bark/UI] `HotkeyPane` gains a "Revision hotkey" row mirroring the push-to-talk
      recorder. Bound to `controller.revisionHotkeySetting` setter.
- [ ] T063 [Bark/UI] `GeneralPane` gains an "Enable voice-driven revision" toggle bound to
      `controller.revisionEnabled`. When off, the hotkey is unbound (no-op).
- [ ] T064 [BarkAppTests] Settings round-trip: `revisionHotkey` + `revisionEnabled` survive
      encode/decode (tolerant decode fills defaults).

## Phase 8 — STRIDE update

- [ ] T070 [docs/SECURITY.md] Add a "Revision surface" control section: re-runs
      `SecureFieldPolicy`, `FocusGuard`, `TextSanitizer`; revision prompt fence; length-drift
      validation; prompt-injection mitigation. Honest residuals: AX automation brittleness in
      Electron apps; spoken instruction as injection vector.
- [ ] T071 [docs/ADRs.md] Append ADR-007 for the revision surface (link to ./spec.md).

## Phase 9 — Verification

- [ ] T080 [Bark] `swift build` clean (lean + MLX).
- [ ] T081 [Bark] `swift test` — 102 → ~120 tests, all green; lean-build subset covers the
      dictionary path; MLX-build subset covers the LLM path.
- [ ] T082 [Bark] Manual smoke (documented in quickstart.md): dictate → revise → revise → revert
      via History pane. With lean build: dictionary commands only.