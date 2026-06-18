# Feature Specification: Bark Daily Driver (installable + complete UX)

**Feature Branch**: `001-daily-driver`
**Created**: 2026-06-18
**Status**: Draft
**Input**: "Build whatever is needed to install Bark as a DMG/app and use it day to day — backend + UX complete, testing complete, build and usage working."

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Install and first run (Priority: P1)
A user downloads `Bark.dmg`, drags Bark to Applications, and launches it. A first-run onboarding window
walks them through granting Microphone, Accessibility, and Input Monitoring. The app lives in the menu
bar with no Dock icon.

**Why this priority**: Without install + first-run permission UX there is no usable product.

**Independent Test**: Build the DMG, mount it, copy the app, launch — onboarding appears and deep-links
to each System Settings pane; once all three are granted, the app is ready.

**Acceptance Scenarios**:
1. **Given** the DMG, **When** opened, **Then** it shows Bark + an Applications shortcut to drag into.
2. **Given** first launch, **When** permissions are missing, **Then** onboarding shows each with a Grant
   button and live status, and the menu shows "needs permission" until satisfied.
3. **Given** all permissions granted, **When** the user holds the hotkey and speaks, **Then** cleaned
   text is inserted into the focused app.

### User Story 2 — Settings persist + launch at login (Priority: P1)
Selected mode, hotkey, locale, and feature toggles survive quit/relaunch. The user can enable "Launch
at login" so Bark is always available.

**Why this priority**: A daily driver must remember the user's setup and be present at login.

**Independent Test**: Change mode + hotkey, quit, relaunch → retained. Toggle Launch at Login → the app
is registered as a login item.

**Acceptance Scenarios**:
1. **Given** a changed mode/hotkey/locale, **When** the app relaunches, **Then** the choices persist.
2. **Given** Launch at Login enabled, **When** the user logs in, **Then** Bark starts automatically.

### User Story 3 — Configure hotkey and modes (Priority: P2)
From Settings the user can rebind the push-to-talk hotkey (record a key/modifier) and create/edit/delete
custom rewrite modes.

**Why this priority**: Personalization is what makes dictation fit a real workflow.

**Independent Test**: Record a new hotkey → it triggers dictation; add a custom mode → it appears in the
menu and is selectable.

**Acceptance Scenarios**:
1. **Given** the hotkey recorder, **When** a new key is captured and saved, **Then** that key drives
   dictation and persists.
2. **Given** a new custom mode, **When** saved, **Then** it appears in the menu and Settings and persists.

### User Story 4 — Opt-in encrypted history (Priority: P2)
History is OFF by default. When enabled, recent transcripts are recorded locally, encrypted at rest, and
viewable; the user can copy or purge them.

**Why this priority**: Recall/redo of past dictations is a common daily-use need; must honor privacy.

**Independent Test**: Enable history → dictations appear in a list, persisted encrypted. Disable/purge →
the store is wiped.

**Acceptance Scenarios**:
1. **Given** history disabled (default), **When** the user dictates, **Then** nothing is persisted.
2. **Given** history enabled, **When** the user dictates, **Then** the transcript is saved encrypted and
   shown; **When** purged, **Then** the file and key are removed.

### User Story 5 — Verified correctness (Priority: P2)
The orchestration logic (start/stop, raw vs LLM, fallback, error/restart, secure-field refusal) is covered
by automated tests using injected fakes, so daily reliability is verified — not just compiled.

**Why this priority**: The user asked for testing to be complete; the prior pass only tested pure logic.

**Independent Test**: `swift test` exercises `DictationController` with fake engines and asserts the
pipeline transitions, fallbacks, and refusals.

**Acceptance Scenarios**:
1. **Given** a fake STT/cleaner/injector, **When** a dictation runs, **Then** the controller injects the
   expected text and ends in `.completed`.
2. **Given** an LLM that fails/times out, **When** an LLM mode runs, **Then** the deterministic text is
   injected (fallback) and no exception escapes.

## Edge Cases
- Permission revoked while running → next dictation fails gracefully with actionable error, mic released.
- Hotkey release missed / rapid re-press → no stuck mic; restart works.
- Empty/silent utterance → nothing injected.
- Secure field / focus changed at inject time → refuse + notify, clipboard restored.
- LLM model not downloaded / disabled → deterministic cleaner used.

## Success Criteria
- A signed (ad-hoc acceptable for personal use) `Bark.app` inside `Bark.dmg` installs and runs.
- Settings + login item + hotkey + modes persist and work.
- `swift build` clean and `swift test` green, including controller orchestration tests.
- Offline guarantee and all Principle-IV injection controls intact; history encrypted + opt-in.
