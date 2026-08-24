# Tasks: Streaming Suggested Responses

**Input**: Design documents from `/specs/016-streaming-suggestions/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/streaming-engine.md, quickstart.md

**Tests**: Included — constitution Quality Gates require pure logic unit-tested and orchestration tested with fakes; SC-002…SC-005 are test-defined.

**Organization**: Tasks grouped by user story. US1 (progressive fill) is the MVP; US2 (early selection/cancel) and US3 (prewarm guarantee) layer on it.

## Phase 1: Setup

- [x] T001 Verify baseline: `swift build` clean and `swift test` green on the branch point (record output; constitution Principle II)

## Phase 2: Foundational (blocking prerequisites)

- [x] T002 Extract the shared validation rulebook (trim, ≤160 cap, non-empty, dedupe, candidate cap) from the private helpers of `Sources/BarkCore/Suggest/SuggestionResponseParser.swift` into an internal type both parsers use; batch parser behavior unchanged (existing `SuggestionResponseParserTests` stay green)
- [x] T003 [P] Add `suggestStream(_:) -> AsyncThrowingStream<String, Error>` to the protocol with the batch-wrapping default per `contracts/streaming-engine.md` in `Sources/BarkCore/Suggest/SuggestionEngine.swift`
- [x] T004 Implement `SuggestionStreamParser` (pure, prefix-stable incremental extraction: think-span hold-back, quote/escape-aware JSON string elements, marker-line completion on newline, shared validation) in `Sources/BarkCore/Suggest/SuggestionStreamParser.swift`
- [x] T005 Write `Tests/BarkCoreTests/SuggestionStreamParserTests.swift`: chunked parity corpus (every batch-parser fixture split at every index + multi-split cases ⇒ incremental emissions + `finish()` == batch parse, SC-002), conservatism (unclosed think span / string literal never emitted), monotonicity, dedupe across arrivals, cap enforcement

**Checkpoint**: Pure streaming machinery proven — no UI or controller changes yet; `swift test` green.

## Phase 3: User Story 1 — Progressive fill (Priority: P1) 🎯 MVP

**Goal**: Overlay appears immediately; each validated candidate shows the moment it completes; stable numbering; generating footer until done.

**Independent test**: Scripted streaming fake engine → overlay rows appear one at a time in arrival order, numbering never changes, footer clears on finish; zero-candidate stream ⇒ existing error state.

- [x] T006 [US1] Replace `.candidatesReady` with `.candidateArrived(String)` + `.generationFinished`, add `isStreaming`, per data-model.md transition table in `Sources/BarkCore/Suggest/SuggestionSession.swift`
- [x] T007 [US1] Update `Tests/BarkCoreTests/SuggestionSessionTests.swift` for the incremental events: first-arrival → `.presenting`, append in `.presenting`, `generationFinished` in both phases, zero-candidate guard, safety valves unchanged
- [x] T008 [P] [US1] Implement native `suggestStream` yielding each `streamDetails` chunk (respecting `suggestOutputCharBound`) in `Sources/BarkCleanupMLX/MLXTextCleaner+Suggest.swift`
- [x] T009 [US1] Rework `runFlow` to iterate `engine.suggestStream` through `SuggestionStreamParser` in a dedicated `generationTask` (separate from `flowTask`), publishing `.candidateArrived` per candidate and `.generationFinished`/timeout per FR-011, `passToken`-guarded, external→local fallback re-entering the same loop, in `Sources/Bark/SuggestionController.swift`
- [x] T010 [P] [US1] Progressive rows + "more coming…" footer while `isStreaming`, footer-aware `size(for:)`, Other… row present from `.generating` in `Sources/Bark/UI/SuggestionOverlayView.swift`
- [x] T011 [US1] Take key from `.generating` (capture already complete; R3 preserved at `.capturing`) in `Sources/Bark/SuggestionOverlayController.swift`
- [x] T012 [US1] Create `Tests/BarkAppTests/SuggestionStreamingFlowTests.swift`: streaming fake engine end-to-end — progressive arrival order, stable numbering, footer lifecycle, zero-candidate error, deadline-with-partial-set completes normally (FR-011)
- [x] T013 [US1] Update `Tests/BarkAppTests/SuggestionControllerFlowTests.swift` (and any other 015 flow tests referencing `.candidatesReady`) to the incremental events; all 015 scenarios stay green via the batch default (SC-005 regression gate)

**Checkpoint**: MVP shippable — streaming visible end-to-end with the local engine; degrade path proven.

## Phase 4: User Story 2 — Early selection cancels the rest (Priority: P2)

**Goal**: Selecting a shown candidate (or Other…, Escape, focus loss) mid-stream cancels generation; injection carries exactly the chosen text.

**Independent test**: Slow streaming fake → select row 1 while 3–4 pending: exact text injected, generation cancelled, no late UI; Escape/focus-loss variants inject nothing.

- [x] T014 [US2] Cancel `generationTask` before injection/dictation/dismissal in `choose(_:)`, `acceptHighlighted()`, `chooseOther()`, `dismiss()`; allow `.chooseOther` from `.generating`; highlight-on-Other tracks the Other row across appends per data-model.md in `Sources/Bark/SuggestionController.swift` + `Sources/BarkCore/Suggest/SuggestionSession.swift`
- [x] T015 [US2] Extend `Tests/BarkCoreTests/SuggestionSessionTests.swift`: `.chooseOther` legal in `.generating`, highlight stability when a candidate arrives while Other… is highlighted
- [x] T016 [US2] Extend `Tests/BarkAppTests/SuggestionStreamingFlowTests.swift`: early selection mid-stream (exact text, engine sees cancellation, no post-dismiss publishes — SC-003/SC-004), Escape and focus-loss mid-stream, Other… during `.generating` starts one-shot dictation and abandons generation

**Checkpoint**: The latency win is bankable — users act on the first good candidate.

## Phase 5: User Story 3 — Prewarm guarantee (Priority: P3)

**Goal**: Lock the existing prepare-overlaps-capture behavior with regression tests (research R6 — no behavior change).

**Independent test**: Instrumented fakes record ordering: prepare begins before capture completes; secure-field refusal ⇒ zero engine calls.

- [x] T017 [P] [US3] Add prewarm-ordering + refusal-abandons-preparation tests with instrumented fake capture/engine in `Tests/BarkAppTests/SuggestionStreamingFlowTests.swift`

## Phase 6: Polish & Cross-Cutting

- [x] T018 Full-suite gate: `swift build` clean + `swift test` green, output captured (constitution Principle II)
- [ ] T019 [P] Record SC-001 TTFC baseline vs branch (median of ≥5 runs, reference machine, per quickstart.md) in the PR description
- [x] T020 [P] Docs touch-up: verify `specs/016-streaming-suggestions/quickstart.md` manual QA steps match the shipped UI copy; note the R2 (no-SSE) residual in `contracts/streaming-engine.md` if the client shape changed during implementation

## Dependencies & Execution Order

- Phase 2 → everything (T002 → T004 → T005; T003 parallel after T002 lands)
- US1 (Phase 3): T006 → T007; T008 parallel; T009 after T003/T004/T006; T010/T011 after T006; T012/T013 after T009–T011
- US2 (Phase 4): after US1 (extends its controller/session/tests)
- US3 (Phase 5): after T009 (needs the streaming flow's seams); independent of US2
- Phase 6 last

**Parallel opportunities**: T003∥T004 (after T002), T008∥T006–T007, T010∥T009, T017∥T014–T16 cleanup, T019∥T020.

## Implementation Strategy

MVP = Phases 1–3 (US1): independently shippable progressive fill with degrade regression. US2 then makes early action safe; US3 is pure test hardening. Stop-and-ship is possible after each checkpoint.
