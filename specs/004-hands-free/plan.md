# Implementation Plan: Hands-free dictation

**Branch**: `004-hands-free` | **Spec**: ./spec.md

## Approach
- **VAD (pure, BarkCore).** `VoiceActivityDetector` consumes `AudioFrames`, computes RMS energy, and
  emits `.speechStarted` / `.speechEnded` using onset-confirmation + silence-hangover counts.
  `VADSensitivity` (low/medium/high) maps to an energy threshold. Fully unit-tested with synthetic
  frame energies.
- **Second hotkey.** A separate `HotkeyManager` instance bound to `Settings.handsFreeHotkey` (a
  function-key toggle, default F5). Each press toggles hands-free. Push-to-talk hotkey is unchanged.
- **Hands-free loop (DictationController).** When toggled on: open one continuous mic capture; a
  consumer Task runs the VAD over frames with a small pre-roll buffer. On `.speechStarted`: capture the
  injection target, open the STT stream, feed pre-roll + frames (state = capturing). On `.speechEnded`:
  finalize STT → `produceText` → `inject` (reuses all existing safety) → reset for the next utterance.
  Loop until toggled off (mic released). Mutually exclusive with push-to-talk (`machine.isActive`).
- **UI.** Settings → Hotkey: a hands-free section (recorder for the toggle key + sensitivity picker).
  HUD stays visible while hands-free is active and reflects the per-utterance phase; menu shows a
  "Hands-free: on" state.

## Constitution Check
- IV (injection safety): every utterance goes through the same sanitize + secure-field + focus-guard +
  never-Return path; target captured at each onset. PASS.
- II (privacy): mic open only while hands-free is on; released on toggle-off; no always-on without the
  explicit toggle. PASS.
- V (non-blocking): VAD is cheap per-frame; STT/cleanup off the main thread. PASS.

## Files
```
Sources/BarkCore/Audio/VoiceActivityDetector.swift   (pure VAD) [+ tests]
Sources/BarkCore/Settings/Settings.swift             (handsFreeHotkey, vadSensitivity)
Sources/Bark/DictationController.swift               (handsFreeActive, toggleHandsFree, runHandsFree)
Sources/Bark/CompositionRoot.swift                   (second HotkeyManager)
Sources/Bark/BarkApp.swift                           (HUD reflects hands-free)
Sources/Bark/UI/SettingsView.swift, MenuContentView.swift  (config + indicator)
Sources/Bark/RecordingHUDController.swift            (stay visible while hands-free)
Tests/BarkCoreTests/VoiceActivityDetectorTests.swift
Tests/BarkAppTests/HandsFreeTests.swift
```

## Risks
- Per-utterance STT begin/finish reuses the per-stream-rebuild engine (already in place) — restart
  latency between utterances is acceptable.
- Energy VAD is simple; expose sensitivity. Pre-roll buffer avoids clipping speech onset.
- Two CGEventTaps (push-to-talk + hands-free) — both need Input Monitoring; low overhead.
