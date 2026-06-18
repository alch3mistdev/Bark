# Tasks: Bark Daily Driver

**Input**: ./spec.md, ./plan.md, ../../.specify/memory/constitution.md
**Tests**: included (Principle II + US5 require it).

## Phase 1: Setup
- [ ] T001 Spec Kit artifacts (constitution, spec, plan, tasks) — this phase.

## Phase 2: Foundational (blocks all stories)
- [ ] T002 [BarkCore] `Settings` value type (Codable): selectedModeID, customModes, hotkey raw
  (keyCode/flags/kind), localeID, launchAtLogin, historyEnabled, llmEnabled, restoreClipboard.
- [ ] T003 [BarkEngines] `HotkeyConfig` ↔ `Settings` codec (CG raw values) + make HotkeyManager
  reconfigurable at runtime (`update(config:)`).
- [ ] T004 [Bark] `SettingsStore` (@MainActor @Observable, UserDefaults JSON) load/save/observe.
- [ ] T005 [Bark] `DictationController` consumes `SettingsStore`: restore selected mode/locale on launch,
  persist on change; expose `hotkeyConfig`.

## Phase 3: US1 — Install & first run (P1)
- [ ] T010 [scripts] `make-icon.swift` → `Resources/Bark.icns` (AppKit-drawn).
- [ ] T011 [scripts] upgrade `make-app.sh`: embed icon + CFBundleIconFile, version, hardened sign.
- [ ] T012 [scripts] `make-dmg.sh`: staged folder + /Applications symlink → `dist/Bark.dmg` via hdiutil.
- [ ] T013 [Bark] `OnboardingView` + Window scene; show on first run / when permissions missing;
  per-permission status + Grant + Open Settings; auto-advance when satisfied.

## Phase 4: US2 — Persistence & login (P1)
- [ ] T020 [BarkEngines] `LoginItemService` (SMAppService.mainApp) register/unregister/status.
- [ ] T021 [Bark] Settings "Launch at login" toggle wired to LoginItemService + persisted.
- [ ] T022 Verify mode/hotkey/locale persist across relaunch (covered by SettingsStore tests T050).

## Phase 5: US3 — Hotkey & modes UI (P2)
- [ ] T030 [Bark] `HotkeyRecorder` view; capture key/modifier; save → reconfigure HotkeyManager live.
- [ ] T031 [Bark] Custom modes CRUD in Settings (add/edit/delete, system prompt + flags); persist.

## Phase 6: US4 — Encrypted history (P2)
- [ ] T040 [BarkCore] `HistoryRecord` + `HistoryStore` protocol + `RetentionPolicy` (cap/trim) pure.
- [ ] T041 [BarkEngines] `EncryptedHistoryStore` (CryptoKit AES-GCM, Keychain key, 0600,
  isExcludedFromBackup, cap, purge).
- [ ] T042 [Bark] `HistoryView` + Settings toggle; wire into pipeline (record final text when enabled).

## Phase 7: US5 — Tests
- [ ] T050 [BarkCoreTests] `SettingsTests` (codec round-trip), `HistoryStoreTests` (retention + crypto
  round-trip via a testable seam).
- [ ] T051 [BarkAppTests] new target + fakes; `DictationControllerTests`: raw happy path → injects +
  completed; LLM fallback on cleaner failure/timeout; secure-field refusal; focus-changed refusal;
  empty transcript no-inject; restart-after-failure.

## Phase 8: Polish & verify
- [ ] T060 `swift build` + `swift test` green (show output).
- [ ] T061 Build `Bark.app` + `Bark.dmg`; verify mount/codesign output.
- [ ] T062 Adversarial pass (Codex + ef-adversary) on the diff; fix or document.
- [ ] T063 Update README (install via DMG, login item, history) + `quickstart.md`.

## Dependencies
T002→T003→T004→T005 (foundational) before US stories. US1/US2/US3/US4 independent after foundational.
T050/T051 after their subjects. T060–T063 last.
