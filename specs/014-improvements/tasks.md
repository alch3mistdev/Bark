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

- [x] T008 [PR2] Render `controller.refineHint` (takes over the HUD status line, orange) in both layouts in `Sources/Bark/UI/RecordingHUDView.swift`
- [x] T009 [PR2] `CleanupOutcome` enum + `lastCleanupOutcome` on `DictationController`, set in `produceText`; "Inserted — basic cleanup (…)" completion note; fallback gets the 2.5s error linger. **Bonus bug fix**: `performInjection` reset `.completed` → `.idle` in the same runloop turn, so "Done" never rendered at all — now `.completed` persists through the linger (`scheduleCompletedReset`, 2.6s) and `startDictation` recovers from it directly
- [x] T010 [PR2] `ProgressView` during `.cleaning` in both HUD layouts
- [x] T011 [P] [PR2] `.completed` → `checkmark.circle.fill` + green HUD accent in `Sources/Bark/BarkApp.swift` / `RecordingHUDView.swift`
- [x] T012 [PR2] `LLMStatusBadge` extracted to `Sources/Bark/UI/LLMStatusBadge.swift`; menu banner + Download/Retry button when selected mode wants the unready LLM; optional non-gating onboarding download row (`#if MLXCleanup`, opt-in + warm via `llmEnabled = true`)
- [x] T013 [PR2] Build + test green (255 tests; 7 assertions updated to the new `.completed`-linger contract, 4 new `lastCleanupOutcome` assertions); live HUD walkthrough left to reviewer

## Phase 4: PR 3 — Accessibility pass (P0)

- [x] T014 [P] [PR3] Tab labels + `.isSelected` traits + "Settings sections" container in `Sources/Bark/UI/SettingsView.swift`
- [x] T015 [P] [PR3] LevelBar accessibility element ("Microphone level", % value / "inactive"); both HUD layouts `.accessibilityElement(children: .combine)` + "Dictation status" in `Sources/Bark/UI/RecordingHUDView.swift`
- [x] T016 [P] [PR3] HotkeyRecorder: current-binding label/value, recording-state button label, F1–F20 hint in `Sources/Bark/UI/HotkeyRecorder.swift`
- [ ] T017 [PR3] Accessibility Inspector audit of scoped controls — left to reviewer (needs GUI session)

## Phase 5: PR 4 — LLM lifecycle (P1)

- [x] T018 [PR4] `unload()` on `TextCleaner` protocol (default no-op); MLX impl `container = nil` + `Memory.clearCache()`
- [x] T019 [PR4] `warmLLMIfNeeded()` at `startDictation()`/`startHandsFree()` when effective mode uses LLM — load overlaps speech
- [x] T020 [PR4] LLM-off branch unloads (off = not resident); idle TTL (`llmIdleUnloadAfter` init param, default 15 min, controller-owned so `llmStatus` and availability never desync; armed on `.ready` and re-armed on each successful clean/refine)
- [x] T021 [PR4] 3 new `LLMStatusTests`: toggle-off unload, TTL expiry + re-prepare, dictation-start warm (258 tests green)
- [x] T022 [PR4] Comment updated: cancellation propagation verified in pinned mlx-swift-lm source (per-token `Task.isCancelled` check) — timed-out rewrites stop within ~a token; live GPU watch left to reviewer

## Phase 6: PR 5 — Settings & error surfaces (P1)

- [x] T023 [PR5] Corrupt blob → backup under `<key>.backup` + `didResetSettings` flag + one-time menu notice with OK; 3 new `SettingsStoreTests` (also closes the untested-wrapper gap)
- [x] T024 [P] [PR5] Injection failure rescues produced text to clipboard + "Your text was copied to the clipboard." — EXCEPT secure-field refusals (that text was headed for a password field; keeping it off the world-readable pasteboard is the point of the guard)
- [x] T025 [P] [PR5] `InjectionError.accessibilityDenied` gets an explicit message; `lastErrorPermission` drives an "Open System Settings" button in the menu
- [x] T026 [P] [PR5] HotkeyRecorder: "Press a function key (F1–F20)…", inline rejection note with the why, Escape cancels
- [x] T027 [PR5] Icon+caption tabs (7 after folding Per-app into Modes as `AppModeSections`); monolith split into `UI/Settings/{General,Hotkey,Modes,PromptEditors,History,Permissions,Privacy,Models}Pane.swift`; `SettingsView.windowSize` shared with WindowManager
- [x] T028 [P] [PR5] `PermissionKind.displayName/.purpose` extension (UI/PermissionCopy.swift) consumed by settings/onboarding/menu; onboarding headline now says only mic is required
- [x] T029 [PR5] Build + test green (261 tests); corruption/permission-loss/injection-failure live walkthrough left to reviewer

## Phase 7: PR 6 — Hygiene (P2)

- [x] T030 [P] [PR6] Deleted dead `feedTask`/`resultTask` + all cancel/nil sites (grep-verified zero refs)
- [x] T031 [P] [PR6] `MLXTextCleaner.defaultModelID` static; CompositionRoot uses init default
- [x] T032 [P] [PR6] `isBuiltInModified` → `override?.isValid == true` (agrees with `effectiveModes()`); new hand-edited-payload test
- [x] T033 [P] [PR6] README test count → "260+" (2 places). CORRECTION: the "phantom type names" review finding was wrong — `FocusGuard`/`TerminalDetector` (InjectionPlan.swift), `HotkeyConfig` (HotkeyManager.swift), `ModeRegistry` (Mode.swift) all exist, nested in other files; diagram left as-is
- [x] T034 [P] [PR6] `SpeakerEnrollmentControllerTests`: 4 tests — 5-good-takes happy path (centroid saved, onComplete), quiet-take redo without counting, embedder-failure fails closed (nothing persisted), cancel discards
- [x] T035 [PR6] Build + test green — **266 tests, 0 failures** (was 254 at review start)

## Dependencies

- PR 1 first (telemetry gates later tuning). PRs 2/3 independent of each other. PR 4 depends on PR 1 merge only for clean diff (protocol file overlap none). PRs 5/6 anytime after PR 1.
