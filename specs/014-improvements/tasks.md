# Tasks: Multipersona Review Improvements

**Input**: Design documents from `/specs/014-improvements/`

**Prerequisites**: plan.md, spec.md

**Tests**: Included — Constitution Quality Gates require pure logic to be unit-tested (`swift test` green).

**Organization**: Grouped by PR; each PR is independently shippable and leaves the build green.

## Format: `[ID] [P?] [PR] Description`

- **[P]**: Can run in parallel (different files, no dependencies)

## Phase 1: Setup

- [x] T001 Create feature branch `014-improvements` from `main`

---

## Phase 2: PR 1 — Bound & observe LLM generation (P0) 🎯 first

- [x] T002 [PR1] Add `GenerateParameters(maxTokens: max(64, min(2048, input.count*6/5 + 20)), temperature: 0)` to `clean` and `refine` ChatSessions in `Sources/BarkCleanupMLX/MLXTextCleaner.swift`
- [x] T003 [PR1] Replace `respond(to:)` with `streamDetails(...)`: accumulate chunks, abort with `CleanupError.outputRejected` when length exceeds `OutputValidator.maxChars` (new shared helper), log promptTime/generateTime/tokensPerSecond via `BarkLog.cleanup` in `Sources/BarkCleanupMLX/MLXTextCleaner.swift`
- [x] T004 [PR1] `Memory.cacheLimit = 256*1024*1024` after container load in `prepare` (API is `MLX.Memory`, not `GPU.set`); log active memory in `Sources/BarkCleanupMLX/MLXTextCleaner.swift`
- [x] T005 [P] [PR1] Wrap hands-free `stt.finishStream()` in `withThrowingDeadline` + `cancel()` fallback; deadline injectable via new `sttFinalizeDeadline` init param (default 5, also used by endSegment) in `Sources/Bark/DictationController.swift`
- [x] T006 [P] [PR1] `HangingFinishSTTEngine` fake in `Tests/BarkAppTests/Fakes.swift`; `testHangingFinalizeDoesNotWedgeHandsFree` in `Tests/BarkAppTests/HandsFreeTests.swift`
- [x] T007 [PR1] `swift build && swift test` green (255 tests, 0 failures); manual forced-balloon walkthrough left to reviewer (needs loaded model + GUI session)

## Phase 3: PR 2 — Trust & feedback UX (P0)

- [ ] T008 [PR2] Render `controller.refineHint` as orange caption in both HUD layouts in `Sources/Bark/UI/RecordingHUDView.swift`
- [ ] T009 [PR2] Add `lastCleanupOutcome` enum to `DictationController`, set in `produceText`; fallback status message + error linger in `Sources/Bark/RecordingHUDController.swift`
- [ ] T010 [PR2] `ProgressView` during `.cleaning` in both HUD layouts
- [ ] T011 [P] [PR2] `.completed` → `checkmark.circle.fill` green in `Sources/Bark/BarkApp.swift` phase map
- [ ] T012 [PR2] Extract `LLMStatusBadge` to shared view; menu banner + Download button in `Sources/Bark/UI/MenuContentView.swift`; optional onboarding download row (`#if MLXCleanup`) in `Sources/Bark/UI/OnboardingView.swift`
- [ ] T013 [PR2] Build + test green; manual walkthrough LLM on/off

## Phase 4: PR 3 — Accessibility pass (P0)

- [ ] T014 [P] [PR3] Tab labels + `.isSelected` traits in `Sources/Bark/UI/SettingsView.swift`
- [ ] T015 [P] [PR3] LevelBar accessibility element (label + % value); HUD root `.accessibilityElement(children: .combine)` in `Sources/Bark/UI/RecordingHUDView.swift`
- [ ] T016 [P] [PR3] HotkeyRecorder binding + recording-state announcements in `Sources/Bark/UI/HotkeyRecorder.swift`
- [ ] T017 [PR3] Accessibility Inspector audit of scoped controls

## Phase 5: PR 4 — LLM lifecycle (P1)

- [ ] T018 [PR4] `unload()` on `TextCleaner` protocol (default no-op) in `Sources/BarkCore/Cleanup/TextCleaner.swift`; MLX impl (`container = nil` + `GPU.clearCache()`)
- [ ] T019 [PR4] Warm at dictation start: `prepareLLM()` in `startDictation()`/`startHandsFree()` when effective mode uses LLM
- [ ] T020 [PR4] LLM-off branch calls `unload()`; idle TTL (15 min, controller-owned MainActor task) → unload + `.notLoaded`
- [ ] T021 [PR4] Extend `Tests/BarkAppTests/LLMStatusTests.swift` for toggle-off unload + TTL + re-prepare paths
- [ ] T022 [PR4] Manual: cancellation-propagation check (deadline 0.5s, watch GPU); update stale comment `DictationController.swift:1206-1209`

## Phase 6: PR 5 — Settings & error surfaces (P1)

- [ ] T023 [PR5] Settings-corruption backup key + `didResetSettings` one-time menu notice in `Sources/Bark/SettingsStore.swift` + `Sources/Bark/UI/MenuContentView.swift`
- [ ] T024 [P] [PR5] Injection-failure clipboard rescue + message + 4s linger in `Sources/Bark/DictationController.swift`
- [ ] T025 [P] [PR5] Accessibility-denied error → actionable message + "Open System Settings"
- [ ] T026 [P] [PR5] HotkeyRecorder affordance: "Press F1–F20…", rejection note, Escape cancels
- [ ] T027 [PR5] Tab captions; fold Per-app pane into Modes; per-pane file split (`Sources/Bark/UI/Settings/`); shared window-size constant
- [ ] T028 [P] [PR5] `PermissionKind` displayName/purpose extension consumed by all 3 views; fix onboarding copy
- [ ] T029 [PR5] Build + test green; corruption/permission/injection-failure manual walkthrough

## Phase 7: PR 6 — Hygiene (P2)

- [ ] T030 [P] [PR6] Delete dead `feedTask`/`resultTask` + cancel/nil sites in `Sources/Bark/DictationController.swift`
- [ ] T031 [P] [PR6] `MLXTextCleaner.defaultModelID` static; CompositionRoot uses default
- [ ] T032 [P] [PR6] `isBuiltInModified` respects override validity; test in `DictationControllerPromptOverrideTests`
- [ ] T033 [P] [PR6] README: fix test count + phantom type names
- [ ] T034 [P] [PR6] New `Tests/BarkAppTests/SpeakerEnrollmentControllerTests.swift` (short/quiet-take rejection, centroid, fail-closed, happy path)
- [ ] T035 [PR6] Build + test green

## Dependencies

- PR 1 first (telemetry gates later tuning). PRs 2/3 independent of each other. PR 4 depends on PR 1 merge only for clean diff (protocol file overlap none). PRs 5/6 anytime after PR 1.
