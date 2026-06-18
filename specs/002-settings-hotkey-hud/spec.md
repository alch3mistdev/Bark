# Feature Specification: Settings reachability, hotkey UX, and live HUD

**Feature Branch**: `002-settings-hotkey-hud`
**Created**: 2026-06-18
**Status**: Draft
**Input**: "Settings doesn't seem to work. I want to be able to change the hotkey. Make other general
improvements the app should have."

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Open Settings reliably (Priority: P1, FIX)
Clicking "Settings…" in the menu bar reliably opens a focused Settings window where every control
works. (Today, a menu-bar `.accessory` app + SwiftUI `Settings` scene + `openSettings()` opens
unfocused/behind/not at all — Settings is effectively unreachable.)

**Independent Test**: Click Settings in the menu → a window appears, comes to the front, accepts input.

**Acceptance Scenarios**:
1. **Given** Bark in the menu bar, **When** the user clicks "Settings…", **Then** a Settings window
   appears frontmost and focused.
2. **Given** the Settings window, **When** the user changes a control, **Then** it persists and applies
   (verified on relaunch).

### User Story 2 — Change the hotkey (Priority: P1)
The user can pick a push-to-talk hotkey from clear presets (Hold fn / Right ⌘ / Right ⌥ / Right ⌃) or
record a custom toggle key, and it takes effect immediately and persists.

**Independent Test**: Choose a preset or record a key in Settings → the new binding drives dictation and
survives relaunch.

**Acceptance Scenarios**:
1. **Given** the Hotkey settings, **When** a preset is selected, **Then** dictation responds to it
   immediately and the choice persists.
2. **Given** the recorder, **When** a function key is captured, **Then** that key toggles dictation and
   doesn't leak to the focused app.

### User Story 3 — Live recording HUD (Priority: P2)
While dictating, a small floating overlay shows the current state (Listening / Transcribing / Cleaning)
and the live partial transcript, so the user has clear feedback that Bark is working.

**Independent Test**: Start dictation → HUD appears with state + live text; on completion it disappears.

**Acceptance Scenarios**:
1. **Given** dictation starts, **When** speaking, **Then** the HUD shows "Listening" + partial text.
2. **Given** dictation ends/cancels/errors, **When** the pass finishes, **Then** the HUD hides.

### User Story 4 — Menu polish (Priority: P2)
The menu shows the last result with a one-click "Copy last", clearer status, and direct access to
Settings — making repeated workflows fast.

**Acceptance Scenarios**:
1. **Given** a completed dictation, **When** the menu opens, **Then** the last inserted text is shown
   with a Copy button.

### User Story 5 — Audio cue (Priority: P3)
A subtle start/stop sound confirms dictation begin/end (toggle in Settings, default on).

## Edge Cases
- Settings window already open → re-clicking focuses the existing window (no duplicates).
- HUD must never steal focus from the target app (non-activating panel) or block injection.
- Changing the hotkey mid-session must not leave a stuck listener.
- Audio cue must not be recorded back into the mic (play on stop only, or after capture stops).

## Success Criteria
- Settings opens, focuses, and all controls persist + apply.
- Hotkey is user-changeable (presets + recorder), live + persisted.
- HUD reflects pipeline state without stealing focus.
- `swift build` clean, `swift test` green (new pure logic covered).
