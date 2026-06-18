# Tasks: Settings reachability, hotkey UX, live HUD

**Input**: ./spec.md, ./plan.md  |  **Tests**: included for pure logic.

## Phase 1: Foundational
- [ ] T001 [BarkCore] `HotkeyPreset` enum (fn / right⌘ / right⌥ / right⌃ / custom) ↔ `HotkeySetting`
  mapping + label; pure. + `HotkeyPresetTests`.
- [ ] T002 [Bark] DictationController: add `lastResult`, `onPhaseChange` (via phase didSet),
  `onOpenSettings` callback + `requestOpenSettings()`, and `soundFeedback` get/set.

## Phase 2: US1 — Settings window (P1, FIX)
- [ ] T010 [Bark] `WindowManager`: lazily create a single AppKit `NSWindow` hosting `SettingsView`
  (sizingOptions = [], explicit rect), `NSApp.activate` + focus, reuse if already open.
- [ ] T011 [Bark] BarkApp/AppDelegate: own a `WindowManager`; wire `controller.onOpenSettings`; drop the
  flaky `Settings` scene + `openSettings()` usage.
- [ ] T012 [Bark] MenuContentView "Settings…" → `controller.requestOpenSettings()`.

## Phase 3: US2 — Hotkey UX (P1)
- [ ] T020 [Bark] Settings Hotkey pane: preset Picker (HotkeyPreset) + existing recorder for custom
  toggle; bind to `controller.hotkeySetting` (live + persisted).

## Phase 4: US3 — Recording HUD (P2)
- [ ] T030 [Bark] `RecordingHUDView` (state icon + label + live partial text, material rounded).
- [ ] T031 [Bark] `RecordingHUDController`: non-activating floating `NSPanel`; show on active phase,
  hide on idle/completed/failed; never becomes key (focus-safe).
- [ ] T032 [Bark] Wire HUD to `controller.onPhaseChange` in AppDelegate.

## Phase 5: US4/US5 — Menu polish + audio cue (P2/P3)
- [ ] T040 [Bark] MenuContentView: show `lastResult` + "Copy last"; clearer status.
- [ ] T041 [Bark] `Feedback` helper + `Settings.soundFeedback` toggle; play start (post-capture) /
  insert cues.

## Phase 6: Verify
- [ ] T050 `swift build` clean + `swift test` green (incl. HotkeyPresetTests).
- [ ] T051 Build `.app`; run headless → stays alive; open Settings path exercised; rebuild DMG.
- [ ] T052 Codex + ef-adversary on the diff; fix or document. Update README/quickstart.

## Dependencies
T001/T002 before all stories. US1 (T010-12) and US2 (T020) and US3 (T030-32) independent after
foundational. T040/T041 after T002. Verify last.
