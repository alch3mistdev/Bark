# Feature Specification: Multipersona Review Improvements

**Feature Branch**: `014-improvements`

**Created**: 2026-07-15

**Status**: Draft

**Input**: Multipersona review (performance engineer + product/UX designer personas) of the whole app. Three exploration passes mapped the codebase; two persona reviews produced prioritized findings, each verified against source (including the pinned MLX checkout under `.build/checkouts`).

## Review verdict

Architecture is sound: strict `Bark → {BarkEngines, BarkCleanupMLX} → BarkCore` layering, protocol seams, constructor DI, ~254 tests. The gaps cluster into six independently shippable improvement sets (one PR each): LLM generation bounds, trust/feedback UX, accessibility, LLM memory lifecycle, settings/error surfaces, and hygiene.

### Corrections established during review (do not re-litigate)

- mlx-swift-lm rev `1c05248` **does** propagate cancellation (per-token `Task.isCancelled` check; stream termination cascades `task.cancel()`). The comment at `DictationController.swift:1206-1209` overstates the leak.
- First-LLM-dictation model load is **not** user-visible latency — `produceText` falls back to basic cleanup while loading. Earlier warmup buys *quality sooner*, not faster injection.

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Bounded, observable LLM generation (Priority: P0)

A user dictates in an LLM mode. Generation is capped by output tokens sized to the input (not just the 8-second wall clock), runs deterministically (temperature 0), aborts mid-stream the moment output exceeds the validator's growth bound, and logs prompt/generation timing plus tokens-per-second so every future tuning decision has data. Hands-free mode can never wedge on a stalled transcriber finalize.

**Why this priority**: A runaway generation today wastes the full 8s deadline before falling back; the hands-free loop can freeze permanently on one bad utterance (the push-to-talk path already fixed this exact bug — commit `0f9a9a3`). Telemetry gates every later performance decision.

**Acceptance Scenarios**:

1. **Given** an LLM-mode dictation whose generation balloons, **When** accumulated output exceeds the growth bound (input×3 + 40 chars), **Then** generation is aborted within ~one token and the deterministic fallback is injected — well under the 8s deadline.
2. **Given** any LLM cleanup or refine call, **Then** a `BarkLog.cleanup` line records prompt time, generation time, and tokens/sec.
3. **Given** hands-free mode and a transcriber whose finalize hangs, **When** an utterance ends, **Then** the finalize is abandoned after 5s (with `cancel()`), the utterance falls back gracefully, and the hands-free loop keeps listening.
4. **Given** repeated identical dictations, **Then** LLM output is deterministic (temperature 0).
5. **Given** 10 consecutive LLM dictations, **Then** MLX GPU cache is bounded by the configured cache limit (256 MB).

---

### User Story 2 — Honest feedback during and after cleanup (Priority: P0)

A user can always tell what the app did with their speech: a spinner shows the LLM is working, the completion message distinguishes "LLM polished" from "basic cleanup fallback (model not ready / failed)", the menu-bar icon shows a distinct success state, and holding refine without the LLM enabled shows the existing (currently dead) hint instead of silent nothing.

**Why this priority**: Silent fallback corrodes trust in the flagship feature; `refineHint` is set by the controller and asserted in tests but rendered by no view — a shipped feature that is invisible.

**Acceptance Scenarios**:

1. **Given** the `.cleaning` phase, **Then** the HUD shows an active progress indicator, in both compact and enhanced layouts.
2. **Given** an LLM fallback (not ready, failed, or timed out), **Then** the completion status reads "Inserted — basic cleanup (…)" and lingers long enough to read (error linger).
3. **Given** a successful injection, **Then** the menu-bar icon shows a distinct success symbol (not the idle mic).
4. **Given** hold-to-refine engaged while the LLM is off, **Then** the HUD shows the refine hint text.
5. **Given** an LLM mode selected while the model is not downloaded/loaded, **Then** the menu popover shows a status banner with a one-click download action, and onboarding (MLX build) offers an optional, non-gating download step.

---

### User Story 3 — VoiceOver can operate the app (Priority: P0)

A VoiceOver user can navigate the 8 settings tabs by name, hear the microphone level as a percentage, operate the hotkey recorder with announced state, and hear the HUD as one coherent element.

**Why this priority**: A dictation app draws disproportionately from assistive-tech users; today the app has exactly one accessibility annotation.

**Acceptance Scenarios**:

1. **Given** VoiceOver on the settings window, **Then** each tab button announces its pane title and selected state.
2. **Given** VoiceOver on the recording HUD, **Then** the level meter announces "Microphone level, N%" and the HUD reads as one combined element.
3. **Given** VoiceOver on the hotkey recorder, **Then** the current binding and recording state are announced.

---

### User Story 4 — LLM memory returned when not in use (Priority: P1)

The ~2.5–3 GB model unloads when the user disables the LLM rewrite or after 15 minutes idle, and reloads transparently (warm-up starts at dictation start, overlapping speech) so the next utterance gets LLM quality as often as possible.

**Acceptance Scenarios**:

1. **Given** the LLM toggle switched off, **Then** the model container is released and process footprint drops accordingly.
2. **Given** 15 minutes with no dictation after an LLM cleanup, **Then** the model unloads and status returns to "not loaded".
3. **Given** a dictation started in an LLM mode with the model unloaded, **Then** loading begins immediately at dictation start (overlapping speech); if not ready by cleanup time, the existing basic fallback applies.
4. **Given** any unload, **Then** `llmStatus` and actual availability never desync (re-prepare works from `.notLoaded`).

---

### User Story 5 — Errors leave the user in control (Priority: P1)

Settings corruption resets to defaults but backs up the unreadable blob and tells the user once. A failed injection puts the dictated text on the clipboard instead of losing it. Losing the accessibility permission mid-use produces an actionable message with a shortcut to System Settings. The hotkey recorder says what it accepts (F1–F20) and explains rejections. Settings tabs gain captions; permission copy is unified; the settings monolith is split per-pane (mechanical).

**Acceptance Scenarios**:

1. **Given** a corrupt settings blob at launch, **Then** defaults load, the old blob is preserved under a backup key, and a one-time notice appears in the menu popover.
2. **Given** an injection failure, **Then** the produced text is on the clipboard and the error message says so.
3. **Given** an accessibility-denied injection error, **Then** the message names the permission and offers "Open System Settings".
4. **Given** a printable key pressed in the hotkey recorder, **Then** an inline note explains only function keys can be global hotkeys; Escape cancels recording.
5. **Given** the settings window, **Then** tabs show icon + caption; per-app mapping lives inside the Modes pane; permission wording is identical across settings, onboarding, and menu.

---

### User Story 6 — Hygiene (Priority: P2)

Dead code removed (`feedTask`/`resultTask`), model ID single-sourced, "Modified" badge accurate for invalid overrides, README test count and phantom type names fixed, `SpeakerEnrollmentController` gains its missing unit tests.

**Acceptance Scenarios**:

1. **Given** an invalid (over-limit) persisted override, **Then** the mode does NOT show "Modified" (badge reflects `effectiveModes()` reality).
2. **Given** the enrollment controller test suite, **Then** capture-validation (length/loudness), centroid averaging, and fail-closed persistence are covered with existing fakes.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: LLM generation MUST pass explicit generation parameters: temperature 0 and a max-token cap derived from input length (`max(64, min(2048, chars×6/5 + 20))`).
- **FR-002**: LLM generation MUST stream internally and abort as soon as accumulated output exceeds the `OutputValidator` growth bound; abort MUST surface as rejection → existing deterministic fallback.
- **FR-003**: Every LLM clean/refine MUST log prompt time, generate time, and tokens/sec via `BarkLog`.
- **FR-004**: The hands-free finalize path MUST bound `finishStream` with the same 5s deadline + `cancel()` fallback as push-to-talk.
- **FR-005**: MLX GPU cache MUST be bounded (256 MB) after model load.
- **FR-006**: The HUD MUST show an active indicator during `.cleaning` and the completion message MUST distinguish LLM output from each fallback cause.
- **FR-007**: `refineHint` MUST be rendered in both HUD layouts.
- **FR-008**: `.completed` MUST have a distinct menu-bar symbol.
- **FR-009**: Model download/status MUST be reachable from the menu popover when an LLM mode is selected and the model is not ready; onboarding MAY offer a non-gating download (MLX build only).
- **FR-010**: Settings tabs, level meter, hotkey recorder, and HUD MUST carry VoiceOver labels/traits/values as scoped in US3.
- **FR-011**: The cleaner protocol MUST support `unload()`; MLX MUST release its container and clear GPU cache on unload; unload MUST be triggered by LLM-off and by a 15-minute idle TTL; `llmStatus` MUST be flipped in the same place.
- **FR-012**: `prepareLLM()` MUST be invoked at dictation start (push-to-talk and hands-free) when the effective mode uses the LLM.
- **FR-013**: Settings corruption MUST back up the unreadable blob and surface a one-time notice; injection failure MUST place produced text on the clipboard; accessibility-denied errors MUST offer opening System Settings.
- **FR-014**: Permission display copy MUST come from a single `PermissionKind` extension.
- **FR-015**: `isBuiltInModified` MUST report true only for overrides that `effectiveModes()` actually applies.

### Success Criteria

- **SC-001**: A ballooning generation falls back in < 2s (was: 8s deadline exhaustion).
- **SC-002**: Hands-free survives a hanging finalize (unit-tested with a hanging fake engine).
- **SC-003**: Process footprint drops by the model size within seconds of LLM-off or TTL expiry.
- **SC-004**: 100% of scoped controls pass an Accessibility Inspector audit for label/value/trait presence.
- **SC-005**: No dictated text is ever lost to an injection failure (clipboard rescue).
- **SC-006**: All existing tests stay green; each PR adds its scoped tests.

## Explicitly out of scope (both personas concur)

- Ring-buffer poll/wakeup rework or drop-policy change (protects the SPSC ownership contract; overflow needs a 30s consumer stall).
- WhisperKit/Parakeet true streaming (not compiled in the default build; never run against real SDKs).
- SettingsStore debounced/async writes (KB-scale, click-driven).
- ChatSession reuse / KV-prefix caching (fresh-session-per-call is a stated security property).
- Settings window redesign; `DictationController` god-object split (separate workstream); haptics; localization; HUD token streaming (spinner + honest outcome ≈ 90% of the trust for 10% of the effort; `cleanStream` hook remains available).

## Measure-first deferrals

- `beginStream` cost on the hotkey-down path: add a `BarkLog` timing; only prebuild analyzer pairs if it exceeds ~100ms (touchiest lifecycle in the app).
- Cancellation propagation: one-off manual verification (deadline 0.5s, watch GPU); update the stale comment either way.
