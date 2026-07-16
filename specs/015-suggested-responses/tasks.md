# Tasks: Suggested Responses

**Input**: Design documents from `/specs/015-suggested-responses/` (spec.md, plan.md, research.md)

**Tests**: Included — constitution Principle II requires tests-first for pure logic and fake-driven flow tests for orchestration.

**Organization**: Grouped by user story. US1 (P1) is the MVP checkpoint; US2/US3 layer on independently.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable (different files, no dependency on incomplete tasks)
- **[US1/US2/US3]**: user-story tag

---

## Phase 1: Setup

- [ ] T001 Baseline evidence: `swift build` + `swift test` green on both `Package.swift` (MLX) and `Package-lean.swift` before any change; record output.
- [ ] T002 [P] Governance: verify constitution v2.0.0 amendment (`.specify/memory/constitution.md`, `docs/constitution.md`) and `docs/ADR-009-suggested-responses-privacy-exceptions.md` are merged on this branch (done during spec phase; confirm).

## Phase 2: Foundational (blocking — no story work before this completes)

Tests first for every pure type:

- [ ] T003 [P] Failing tests `Tests/BarkCoreTests/SuggestionSessionTests.swift` — legal/illegal transitions (idle→capturing→generating→presenting→injecting/dictating/failed), highlight moves, dismiss-from-any-state.
- [ ] T004 [P] Failing tests `Tests/BarkCoreTests/SuggestionPromptTests.swift` — guardrail present, `<screen_context>`/`<focused_field>`/`<history_snippets>` fencing, tag-neutralization of forged closers, empty-history omission.
- [ ] T005 [P] Failing tests `Tests/BarkCoreTests/SuggestionResponseParserTests.swift` — clean JSON array, prose-wrapped JSON, bullet/numbered salvage, dedupe, length/single-line bounds, zero-valid → error.
- [ ] T006 [P] Failing tests `Tests/BarkCoreTests/SuggestionKeyDecoderTests.swift` — number keys 1–4, arrows, Return/keypad-Enter, Escape, `o` for Other, unknown keys pass through.
- [ ] T007 [P] Failing tests `Tests/BarkCoreTests/HistoryRelevanceTests.swift` — keyword extraction from field label + context tail (stopwords stripped), scoring by overlap+recency, top-3 clipped to 120 chars.
- [ ] T008 [P] Failing tests `Tests/BarkCoreTests/ContextBudgetTests.swift` — tail-clip for terminal-like targets, head-clip otherwise, 4000-char bound, `isThin` threshold (<80 chars).
- [ ] T009 [P] Failing tests `Tests/BarkCoreTests/AutoSubmitPolicyTests.swift` — exhaustive decision table: enabled × secureInput × focusChanged × routing(copyOnly) → fires only in the single approved row.

Implement the pure types (make tests green):

- [ ] T010 [P] `Sources/BarkCore/Suggest/SuggestionSession.swift` — state machine modeled on `RefineSession`/`DictationStateMachine`.
- [ ] T011 [P] `Sources/BarkCore/Context/CapturedContext.swift` + `ContextBudget` (clip strategies, thinness) and `Sources/BarkCore/Context/ContextCapturing.swift` protocol.
- [ ] T012 [P] `Sources/BarkCore/Suggest/SuggestionEngine.swift` — protocol, `SuggestionRequest`, `SuggestionBackendID`, typed `SuggestionError`.
- [ ] T013 [P] `Sources/BarkCore/Suggest/SuggestionPrompt.swift` — mirror `PromptTemplate` guardrail/fencing patterns.
- [ ] T014 [P] `Sources/BarkCore/Suggest/SuggestionResponseParser.swift`.
- [ ] T015 [P] `Sources/BarkCore/Suggest/SuggestionKeyDecoder.swift` — twin of `RefineKeyDecoder`.
- [ ] T016 [P] `Sources/BarkCore/Suggest/HistoryRelevance.swift`.
- [ ] T017 [P] `Sources/BarkCore/Suggest/AutoSubmitPolicy.swift`.

Shared plumbing:

- [ ] T018 Settings schema in `Sources/BarkCore/Settings/Settings.swift` — `suggestionsEnabled=false`, `suggestionsHotkey` (F6/97 keyToggle), `suggestionBackend=.local`, `externalLLMEndpoint=""`, `externalLLMModel=""`, `suggestionAutoSubmit=false`; lenient decode; round-trip + lenient-decode additions to `Tests/BarkCoreTests/SettingsTests.swift`.
- [ ] T019 `Sources/BarkEngines/Permissions/PermissionsCoordinator.swift` — add `.screenRecording` (`CGPreflightScreenCaptureAccess`/`CGRequestScreenCaptureAccess`, deep link `Privacy_ScreenCapture`).
- [ ] T020 [P] Fakes in `Tests/BarkAppTests/Fakes.swift` — `FakeContextCapture` (scripted `CapturedContext`), `FakeSuggestionEngine` (canned/failing candidates).
- [ ] T021 [P] `Sources/BarkEngines/Suggest/KeychainSecretStore.swift` (pattern: `EncryptedSpeakerProfileStore.swift:89-110`, injectable seam) + `Tests/BarkAppTests/KeychainSecretStoreTests.swift`.
- [ ] T022 **SPIKE (gates R3)**: throwaway key-accepting non-activating panel — verify key routing, `NSWorkspace.frontmostApplication` stability, and AX focused-element stability while panel is key on macOS 26. Write result into research.md R3; on failure, switch overlay tasks to the event-tap fallback.

**Checkpoint**: all BarkCoreTests green; both builds compile.

## Phase 3: User Story 1 — Pick a suggested response in a terminal (P1) 🎯 MVP

- [ ] T023 [US1] Failing flow test `Tests/BarkAppTests/SuggestionControllerFlowTests.swift` — scripted context → canned engine → hotkey → presenting; select index 1 → FakeInjector receives exactly that text with `.keystroke` strategy for a terminal target; Escape → nothing injected, context discarded; engine failure → failed state, nothing injected; hotkey during active dictation ignored; secure field focused → capture refused, nothing read (FR-004).
- [ ] T024 [US1] `Sources/BarkEngines/Context/AXContextReader.swift` — off-main (pattern `FocusProbe.focusedCaretRect`, 0.25 s AX timeout): focused element `AXValue`/`AXTitle`/`AXDescription`/`AXPlaceholderValue` + label via `AXTitleUIElement`; window DFS depth ≤ 8, ≤ 200 elements under `ContextBudget`; refuse via `SecureFieldDetector` before any read.
- [ ] T025 [US1] `Sources/BarkEngines/Context/ContextCaptureService.swift` — `ContextCapturing` impl, AX-only at this phase (OCR seam stubbed).
- [ ] T026 [US1] `Sources/BarkCleanupMLX/MLXTextCleaner+Suggest.swift` — `SuggestionEngine` conformance sharing `ModelContainer`; temp 0, `maxTokens ≈ 256`, mid-stream abort past parser bound (reuse `collect` pattern); lean-build stub reports unavailable.
- [ ] T027 [US1] `Sources/Bark/SuggestionController.swift` — hotkey guards (enabled, no active dictation, toggle-dismiss), target snapshot, secure-field refusal, capture → history relevance → prompt → engine under 12 s deadline (`withThrowingDeadline` pattern), parse/validate, session state, injection via own `InjectionRouter`+injectors, error states, LLM warm via `dictation.prepareLLM()`.
- [ ] T028 [US1] `Sources/Bark/SuggestionOverlayController.swift` + `Sources/Bark/UI/SuggestionOverlayView.swift` — panel per spike outcome; numbered rows + Other… + loading ("Reading screen…"/"Thinking…") + error states; keyboard via `SuggestionKeyDecoder`, mouse clicks; caret placement (`HUDPlacement.underCaret`, `bottomCenter` fallback); dismiss on Escape/`resignKey`.
- [ ] T029 [US1] Wiring: `Sources/Bark/CompositionRoot.swift` (third `HotkeyManager`, capture service, engine selection, controller) + `Sources/Bark/BarkApp.swift` (activate; keep HUD multiplex untouched); 3-way hotkey collision guard on the new setter.
- [ ] T030 [US1] Minimal `Sources/Bark/UI/Settings/SuggestionsPane.swift` (enable + hotkey recorder) + `.suggestions` case in `Sources/Bark/UI/SettingsView.swift`.

**Checkpoint (MVP)**: end-to-end against a real terminal — hotkey → overlay → pick → inserted at cursor. Flow tests green.

## Phase 4: User Story 2 — "Other…" + opt-in auto-submit (P2)

- [ ] T031 [US2] Failing flow test — select Other → one-shot hands-free starts; first `.completed` phase → `stopHandsFree()` called; `.failed` likewise.
- [ ] T032 [US2] Phase multiplex in `Sources/Bark/BarkApp.swift` (`onPhaseChange` → HUD + SuggestionController) + one-shot logic in `SuggestionController`.
- [ ] T033 [US2] `Sources/BarkEngines/Inject/ReturnKeySynthesizer.swift` — sole Return site (mirror `synthesizePaste` mechanics), re-runs `InjectionPreflight.check` immediately before posting; ~150 ms settle delay; wire through `AutoSubmitPolicy` in `SuggestionController`.
- [ ] T034 [US2] Auto-submit toggle + warning copy in `SuggestionsPane`.
- [ ] T035 [US2] Failing-then-green flow tests — auto-submit refused on: secure field, focus changed, copyOnly routing, Other/dictation path, setting off (decision-table parity with T009).

**Checkpoint**: US2 scenarios pass; injectors still byte-identical (no Return in any `TextInjector`).

## Phase 5: User Story 3 — OCR fallback, external backend, history-informed (P2)

- [ ] T036 [US3] `Sources/BarkEngines/Context/WindowOCRReader.swift` (SCK one-frame of frontmost window + Vision accurate recognition, top-to-bottom lines) + thin-context fallback in `ContextCaptureService` + JIT Screen Recording flow (T019) + permission row in `Sources/Bark/UI/Settings/PermissionsPane.swift`.
- [ ] T037 [US3] `Sources/BarkEngines/Suggest/OpenAICompatClient.swift` — chat-completions POST, Bearer only when key exists (Ollama keyless), typed errors + `Tests/BarkAppTests/OpenAICompatClientTests.swift` via URLProtocol stub (200 / 401 / timeout / malformed JSON).
- [ ] T038 [US3] Backend picker + endpoint/model/key fields + privacy warning (names exactly what is transmitted) in `SuggestionsPane`; key stored via `KeychainSecretStore`; local-backend row links to Models pane for `llmEnabled` consent (R12).
- [ ] T039 [US3] External→local fallback in `SuggestionController` (R8) + flow test: external 401 → local candidates presented; local failure never calls network.
- [ ] T040 [US3] Wire `HistoryRelevance` into the request path + flow test: seeded history + "Address" field label → history-informed candidate present; history disabled → generation unaffected.

**Checkpoint**: US3 scenarios pass independently of US2.

## Phase 6: Polish & Evidence

- [ ] T041 Failure-mode QA matrix (manual, evidence recorded): no Accessibility permission, no Screen Recording, AX+OCR empty, LLM cold/warm, timeout, endpoint down, secure field, focus drift mid-flow, hotkey toggle-dismiss. Apps: Terminal, iTerm2, VS Code, Safari form.
- [ ] T042 [P] Overlay accessibility (VoiceOver labels on rows/states, per 014 conventions) + visual polish.
- [ ] T043 [P] Docs: SECURITY.md residuals (Return remap best-effort; external endpoint operator visibility), README feature blurb.
- [ ] T044 Evidence: `swift build` + `swift test` output on both configs; SC-002 grep proof (no captured context on disk).
- [ ] T045 Adversarial review (Codex + ef-adversary) on the diff; fix or document flagged items.

---

## Dependencies

- Phase 2 blocks all stories. T022 (spike) blocks T028.
- US1 (T023–T030) blocks US2 (needs overlay+controller) ; US3 depends only on Phase 2 + T025/T027 seams (can start after US1's T027 lands).
- T033 depends on T017 (policy) + T029 (wiring).

## Parallel example

Phase 2: T003–T009 all [P] (distinct test files); then T010–T017 all [P]. Phase 5: T036, T037 parallel (different subsystems).

## Implementation strategy

MVP = Phases 1–3 only: shippable "pick a suggestion in a terminal" with local engine and AX capture. Each later phase is an independently testable increment gated by its checkpoint. Stop-line for any cut: after Phase 3.
