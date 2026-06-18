# Implementation Plan: Bark Daily Driver

**Branch**: `001-daily-driver` | **Date**: 2026-06-18 | **Spec**: ./spec.md

## Summary
Take the verified pipeline from a buildable spine to an installable, persistent, daily-use menu-bar app:
settings persistence + launch-at-login, configurable hotkey + custom modes UI, first-run onboarding,
opt-in encrypted history, `.app`+DMG packaging with an app icon, and orchestration test coverage.

## Technical Context
**Language/Version**: Swift 6.0 (toolchain 6.3.2), SwiftUI / AppKit
**Primary Dependencies**: none added to the default build (Apple frameworks only). MLX stays opt-in.
**Storage**: `UserDefaults` (settings, JSON-encoded `Settings`); history = CryptoKit AES-GCM file in
Application Support, key in Keychain.
**Testing**: XCTest. New `BarkAppTests` target testing `DictationController` via injected fakes.
**Target Platform**: macOS 26+, Apple Silicon
**Project Type**: native desktop menu-bar app
**Performance Goals**: unchanged — raw dictation sub-second; UI never blocks the pipeline.
**Constraints**: offline-only at runtime; non-sandboxed Developer-ID/ad-hoc hardened runtime.

## Constitution Check
- I (Offline): no network added; history is local + encrypted. PASS.
- II (Evidence): every task ends with build+test output. PASS.
- III (Protocols): new `SettingsStore`, `HistoryStore`, `LoginItemService` are protocol-fronted; pure
  bits (`Settings`, hotkey codec, retention) in `BarkCore`. PASS.
- IV (Least privilege/injection): no new permissions; history adds an at-rest encryption obligation
  (met via CryptoKit+Keychain). PASS.
- V (Speed/non-blocking): persistence + history writes are async/off the hot path. PASS.

## Approach
1. **Settings**: `Settings` value type + `HotkeyConfig` Codable (move/extend in `BarkCore`).
   `SettingsStore` (@MainActor @Observable, UserDefaults-backed) in the app; `DictationController`
   reads/writes it (selected mode, custom modes, hotkey, locale, toggles).
2. **Login item**: `LoginItemService` wrapping `SMAppService.mainApp` (ServiceManagement).
3. **Hotkey UX**: a SwiftUI key-recorder; apply live by reconfiguring `HotkeyManager`.
4. **Onboarding**: a `Window` scene shown on first run (or when permissions missing) with per-permission
   status + Grant/Open-Settings; dismiss when satisfied.
5. **History**: `HistoryStore` protocol in `BarkCore`; `EncryptedHistoryStore` in `BarkEngines`
   (CryptoKit `AES.GCM`, `SymmetricKey` in Keychain, JSON records, count cap + purge, file `0600`,
   `isExcludedFromBackup`). Wired into the pipeline only when enabled.
6. **Packaging**: `scripts/make-icon.swift` (AppKit-drawn `.icns`), upgraded `scripts/make-app.sh`
   (icon + version + hardened sign), `scripts/make-dmg.sh` (`hdiutil` + Applications symlink).
7. **Tests**: `BarkAppTests` with `FakeSTTEngine`, `FakeTextCleaner`, `FakeTextInjector`, fake
   permissions/hotkey to drive `DictationController` and assert transitions/fallbacks/refusals;
   `BarkCore` tests for `Settings` codec + history retention/crypto round-trip helpers.

## Project Structure
```
Sources/BarkCore/Settings/Settings.swift, Hotkey/HotkeyConfig (moved), History/HistoryRecord.swift
Sources/BarkEngines/History/EncryptedHistoryStore.swift, System/LoginItemService.swift
Sources/Bark/Settings/SettingsStore.swift, UI/OnboardingView.swift, UI/HotkeyRecorder.swift, UI/HistoryView.swift
Tests/BarkCoreTests/SettingsTests.swift, HistoryStoreTests.swift
Tests/BarkAppTests/DictationControllerTests.swift + Fakes.swift
scripts/make-icon.swift, make-app.sh (upd), make-dmg.sh
```

## Risks
- `HotkeyConfig` is currently in `BarkEngines` (CGEventFlags/CGKeyCode). Make it `Codable` and keep the
  CG types; `BarkCore` can't import CoreGraphics cleanly → keep hotkey codec in `BarkEngines`, store the
  raw values in `Settings` (in BarkCore) as `UInt64`/`UInt16`.
- SMAppService requires a bundled, signed app — login item won't register from a bare CLI binary; test
  the registration call path, document that it takes effect from the installed `.app`.
- Testing executable target: use `@testable import Bark`; ensure `DictationController` deps are injectable
  (already are).
