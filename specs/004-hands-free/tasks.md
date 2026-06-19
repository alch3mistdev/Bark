# Tasks: Hands-free dictation

- [ ] T001 [BarkCore] `VoiceActivityDetector` + `VADSensitivity` (RMS, onset/hangover) + tests.
- [ ] T002 [BarkCore] Settings: `handsFreeHotkey` (default F5 toggle) + `vadSensitivity`.
- [ ] T003 [Bark] DictationController: `handsFreeActive`, `toggleHandsFree()`, `runHandsFree` loop
  (VAD-gated per-utterance capture → produceText → inject), mutual-exclusion with push-to-talk.
- [ ] T004 [Bark] CompositionRoot + activate(): second `HotkeyManager` for the hands-free toggle.
- [ ] T005 [Bark] Settings UI (hands-free hotkey recorder + sensitivity) + menu indicator.
- [ ] T006 [Bark] HUD stays visible while hands-free is active.
- [ ] T007 [Tests] VAD unit tests; HandsFreeTests (fakes: synthetic frames → utterances → injects, toggle off stops).
- [ ] T008 Build + test green; review (Codex + ef-adversary); commit + merge + push.
