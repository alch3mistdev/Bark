# Implementation Plan: Multipersona Review Improvements

**Branch**: `014-improvements` | **Date**: 2026-07-15 | **Spec**: [spec.md](spec.md)

**Input**: Multipersona review backlog from `/specs/014-improvements/spec.md`

## Summary

Six independently shippable PRs, ordered by impact/risk. PR 1 (LLM generation bounds + telemetry + hands-free deadline) first — highest impact, lowest risk, and its telemetry gates later tuning. Each PR leaves `swift build && swift test` green and is reviewable standalone.

## Technical Context

**Language/Version**: Swift 6.1 (strict concurrency), macOS 26 target (per Package.swift)

**Primary Dependencies**: mlx-swift-lm `1c05248` (pinned; APIs verified in `.build/checkouts`), SwiftUI + Observation; BarkCore stays dependency-free

**Testing**: XCTest via `swift test`; controller tests use the existing fakes in `Tests/BarkAppTests/Fakes.swift`

**Constraints**: LLM must never block delivery (ADR-003); guardrail/fencing/fresh-session security properties untouched; no pipeline latency regressions

## Constitution Check

| Principle | Status | Evidence |
|-----------|--------|----------|
| I. Offline-First | PASS | No network surface changes; download UX reuses existing `prepareLLM` path. |
| II. Evidence or It Didn't Happen | PASS | Each PR adds scoped unit tests; PR 1 adds the telemetry that makes later perf claims measurable. |
| III. Swappable Engines Behind Protocols | PASS | Only protocol change is additive `unload()` with default no-op (PR 4). |
| IV. Least Privilege & Safe Injection | PASS | Prompts, fencing, validator, fresh-session-per-call all untouched. Clipboard rescue (PR 5) only ever holds text the user just dictated. |
| V. Speed-First, Non-Blocking | PASS | maxTokens/early-abort strictly reduce worst-case latency; warmup overlaps speech. |

## Per-PR technical approach

### PR 1 — Bound & observe LLM generation

Files: `Sources/BarkCleanupMLX/MLXTextCleaner.swift`, `Sources/Bark/DictationController.swift`, `Tests/BarkAppTests/Fakes.swift`, `Tests/BarkAppTests/DictationControllerTests.swift`

1. Both `clean` and `refine`: `ChatSession(container, instructions: …, generateParameters: GenerateParameters(maxTokens: cap, temperature: 0))` where `cap = max(64, min(2048, input.count * 6/5 + 20))` (~4 chars/token English + 1.5× headroom). API: `ChatSession.init(_:instructions:generateParameters:)`, `GenerateParameters(maxTokens:temperature:)` — verified in pinned checkout (`ChatSession.swift:48-56`, `Evaluate.swift:60-111`). A cap-truncated output exceeds the validator char bound → rejected → existing fallback; no new failure mode.
2. Replace `session.respond(to:)` with `session.streamDetails(to: prompt, images: [], videos: [])`; accumulate `.chunk` payloads; **throw `CleanupError.outputRejected` the moment accumulated count > input×3 + 40** (breaking the stream fires `onTermination` → generation task cancelled within ~one token); on `.info(GenerateCompletionInfo)` log `promptTime`/`generateTime`/`tokensPerSecond` via `BarkLog.cleanup`.
3. `MLX.GPU.set(cacheLimit: 256 * 1024 * 1024)` after container load in `prepare` (API: `mlx-swift GPU+Metal.swift:101`); log `GPU.snapshot()` numbers after load.
4. Hands-free deadline — mirror `endSegment` at `DictationController.swift:1129`:
   ```swift
   do { try await withThrowingDeadline(seconds: 5) { [stt] in try await stt.finishStream() } }
   catch { await stt.cancel() }
   ```
5. Test: add a hanging-finish fake STT engine mode to `Fakes.swift`; assert hands-free loop advances past a wedged finalize (pattern: `FakeCleaner(.hang)` + short deadline, injectable via existing constructor DI).

### PR 2 — Trust & feedback UX

Files: `Sources/Bark/UI/RecordingHUDView.swift`, `Sources/Bark/DictationController.swift`, `Sources/Bark/RecordingHUDController.swift`, `Sources/Bark/UI/MenuContentView.swift`, `Sources/Bark/UI/SettingsView.swift`, `Sources/Bark/UI/OnboardingView.swift`, `Sources/Bark/BarkApp.swift`

1. Render `controller.refineHint` as orange caption in both HUD layouts (cleared already at `DictationController.swift:561`).
2. `ProgressView` beside status line when `phase == .cleaning`. New `lastCleanupOutcome` enum (`llm`, `fallbackNotReady`, `fallbackFailed`, `deterministic`) set in `produceText`; fallback → status "Inserted — basic cleanup (model not ready / rewrite failed)" + reuse 2.5s error linger in `RecordingHUDController`.
3. `.completed` → `checkmark.circle.fill` (green) in the phase→symbol map (`BarkApp.swift:73-96`).
4. Extract `LLMStatusBadge` (private, `SettingsView.swift:145-164`) to a shared file. MenuContentView banner when `llmEnginePresent && selectedMode.usesLLM && status ∈ {notLoaded, downloading, failed}` with Download button → `controller.prepareLLM()` (progress plumbing exists at `DictationController.swift:307-311`). OnboardingView: optional non-gating download row, `#if MLXCleanup` build only.

### PR 3 — Accessibility pass

Files: `Sources/Bark/UI/SettingsView.swift`, `Sources/Bark/UI/RecordingHUDView.swift`, `Sources/Bark/UI/HotkeyRecorder.swift`

Labels + traits + values only. Tab buttons: `.accessibilityLabel(item.title)` (titles exist at `SettingsView.swift:25-36`) + `.accessibilityAddTraits(pane == item ? .isSelected : [])`. `LevelBar`: `.accessibilityElement()`, label "Microphone level", value "\(Int(level*100))%". `HotkeyRecorder`: label includes `setting.displayName`, announces recording state. HUD root: `.accessibilityElement(children: .combine)`. Verify with Accessibility Inspector.

### PR 4 — LLM lifecycle

Files: `Sources/BarkCore/Cleanup/TextCleaner.swift`, `Sources/BarkCleanupMLX/MLXTextCleaner.swift`, `Sources/Bark/DictationController.swift`, `Tests/BarkAppTests/LLMStatusTests.swift`

1. Warm at dictation start: `prepareLLM()` call in `startDictation()` (~`:562`, after `capturedTarget`) and `startHandsFree()` (~`:1055`) when `llmEnabled && effectiveMode().usesLLM`. Idempotent already (`:285-305`).
2. `unload()` on `TextCleaner` (default no-op). MLX: `container = nil; MLX.GPU.clearCache()`. Called from `llmEnabled` off-branch; controller sets `llmStatus = .notLoaded`.
3. Idle TTL in the controller (NOT the actor — `llmStatus` lives on the controller and `produceText` re-prepares only from `.notLoaded`/`.failed`, so policy and status must flip together): after each successful clean/refine, cancel-and-reschedule a MainActor `Task` sleeping 15 min → `await llm.unload(); llmStatus = .notLoaded`.
4. Manual: force `cleanupDeadline: 0.5`, watch GPU after timeout; update stale comment at `DictationController.swift:1206-1209`.

### PR 5 — Settings & error surfaces

Files: `Sources/Bark/SettingsStore.swift`, `Sources/Bark/DictationController.swift`, `Sources/Bark/UI/*` (per-pane split), `Sources/Bark/UI/HotkeyRecorder.swift`, `Sources/Bark/WindowManager.swift`, `Sources/Bark/UI/OnboardingView.swift`, `Sources/Bark/UI/MenuContentView.swift`

1. `SettingsStore.load`: on decode failure, copy raw blob to `com.bark.settings.v1.backup` before resetting; set `didResetSettings` flag → one-time menu popover notice.
2. `performInjection` catch: `NSPasteboard` copy of produced text + "— copied to clipboard" appended to `injectionMessage`; error linger ~4s.
3. Accessibility-denied injection error → message naming the permission + "Open System Settings" button (`permissions.openSettings(for:)` exists).
4. HotkeyRecorder: label "Press F1–F20…"; transient inline rejection note (rationale in comment at `:39-41`); Escape cancels.
5. Tab bar: icon + caption VStacks (8 × ~58pt fits 480pt; drops to 7 after fold). Fold Per-app pane (~55 LOC) into Modes pane as a section. Mechanical split of SettingsView.swift into `Sources/Bark/UI/Settings/<Pane>.swift` files — zero behavior change. Single `settingsWindowSize` constant shared with WindowManager.
6. `PermissionKind` extension (`displayName`, `purpose`) consumed by SettingsView/OnboardingView/MenuContentView; fix onboarding "Grant three permissions" copy (mic-only is required).

### PR 6 — Hygiene

1. Delete `feedTask`/`resultTask` (`DictationController.swift:67-68`) + their cancel/nil sites (`:503-504, 899, 908, 923-924`).
2. `MLXTextCleaner.defaultModelID` static; CompositionRoot drops its duplicate literal.
3. `isBuiltInModified` → `override?.isValid == true` semantics (align with `effectiveModes()`); test in `DictationControllerPromptOverrideTests`.
4. README: "172 tests" → current count (2 places); replace phantom names in architecture diagram (`HotkeyConfig`→`HotkeySetting`/`HotkeyPreset`; `ModeRegistry`/`InjectionRouter`/`FocusGuard`/`TerminalDetector` → actual file names).
5. New `Tests/BarkAppTests/SpeakerEnrollmentControllerTests.swift` using `FakeSpeakerEmbedder`, `InMemorySpeakerProfileStore`, `ScriptedAudioCapture`: short-take rejection, quiet-take rejection, centroid averaging, fail-closed (no embedding → `.failed`, nothing persisted), happy-path persistence.

## Verification

- Per PR: `swift build && swift test` green.
- PR 1: long dictation → `BarkLog.cleanup` shows tokens/sec; forced balloon → sub-2s fallback (not 8s); footprint after 10 LLM dictations bounded.
- PR 2/3: run app, dictate LLM off/on → spinner, outcome label, checkmark, refine hint visible; Accessibility Inspector audit passes for scoped controls.
- PR 4: LLM toggle off → footprint drops ~2.5 GB; TTL fires after idle; `LLMStatusTests` extended.
- PR 5: corrupt settings blob → notice + backup key; revoke accessibility mid-session → actionable error; injection failure → text on clipboard.
