# Implementation Plan: Settings reachability, hotkey UX, live HUD

**Branch**: `002-settings-hotkey-hud` | **Date**: 2026-06-18 | **Spec**: ./spec.md

## Summary
Make Settings reachable (AppKit-hosted window opened from the menu, reusing the onboarding-window
pattern that fixed the launch crash), give the hotkey a presets + recorder UX that applies live, add a
non-activating live recording HUD, polish the menu (last result + copy), and an optional start/stop cue.

## Technical Context
**Language**: Swift 6 / SwiftUI + AppKit. **Deps**: none added. **Storage**: existing `SettingsStore`.
**Platform**: macOS 26, Apple Silicon. **Tests**: XCTest (pure logic + controller).

## Constitution Check
- I (Offline): no network. PASS.
- III (Protocols): HUD/window are app-layer; hotkey presets are pure data in `BarkCore`. PASS.
- IV (Injection safety): HUD is a **non-activating** panel — must not change focus or interfere with
  the focus/secure-field checks. PASS (panel never becomes key).
- V (Speed/non-blocking): HUD updates observe existing published state; no added latency. PASS.

## Approach
1. **Settings window (FIX)** — replace the `Settings` scene + `openSettings()` with an AppKit
   `WindowManager` in the app layer: a lazily-created `NSWindow` hosting `SettingsView`
   (`hosting.sizingOptions = []`, explicit contentRect — same fix as onboarding). Opened via a
   controller callback (`onOpenSettings`) wired by `AppDelegate`; `NSApp.activate` + single-instance.
2. **Hotkey UX** — add `HotkeyPreset` (pure, `BarkCore`): the common bindings + mapping to
   `HotkeySetting`. Settings shows a preset Picker + the existing recorder for a custom toggle key.
   `controller.hotkeySetting` already applies live + persists.
3. **Recording HUD** — `RecordingHUDController` (app layer) owns a non-activating floating `NSPanel`
   hosting `RecordingHUDView(controller:)`. Driven by `controller.onPhaseChange` (new): show on active
   phases, hide on idle/completed/failed. Panel: `.nonactivatingPanel`, `.floating` level,
   `collectionBehavior` for all spaces, no title, rounded material content.
4. **Menu polish** — controller exposes `lastResult`; `MenuContentView` shows it + a Copy button +
   "Settings…" (now via callback).
5. **Audio cue** — `Settings.soundFeedback` (default true); play system sounds on start (after capture
   is live) and on insert via a small `Feedback` helper. Off-by-default risk of mic bleed mitigated by
   keeping cues quiet/short and playing the stop cue post-injection.

## Files
```
Sources/BarkCore/Settings/HotkeyPreset.swift            (pure: presets + mapping)   [+tests]
Sources/Bark/WindowManager.swift                        (AppKit settings window)
Sources/Bark/UI/RecordingHUDView.swift                  (HUD content)
Sources/Bark/RecordingHUDController.swift               (NSPanel owner)
Sources/Bark/Feedback.swift                             (start/stop sounds)
Sources/Bark/DictationController.swift                  (onPhaseChange, lastResult, onOpenSettings, soundFeedback)
Sources/Bark/BarkApp.swift                              (wire WindowManager + HUD; drop Settings scene)
Sources/Bark/UI/{MenuContentView,SettingsView}.swift    (preset picker, last result, callback)
Tests/BarkCoreTests/HotkeyPresetTests.swift
```

## Risks
- HUD panel stealing focus → use `NSPanel` with `.nonactivatingPanel` and never `makeKey`; `orderFront`
  only. Verify injection focus-guard still sees the real target (panel isn't frontmost-app).
- Dropping the `Settings` scene removes the ⌘, menu item — acceptable for an accessory app; the menu
  provides access. Keep a `Settings` scene only if harmless; otherwise remove to avoid confusion.
- `onPhaseChange` via `didSet` must stay cheap and main-actor.
