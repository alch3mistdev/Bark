# Feature Specification: Enhanced recording overlay (opt-in)

**Branch**: `008-enhanced-hud` | **Created**: 2026-06-19 | **Status**: Draft
**Input**: User asked whether dictation could live-stream at the cursor and reform after LLM cleanup. True
in-field live-insert-then-reform was assessed as unsafe (delete/replace over arbitrary apps fights the
never-Return / focus-guard / secure-field / data-loss guarantees). User chose instead: keep the current
HUD as default, add an **opt-in richer overlay** toggled in Settings.

## User Scenarios

### US1 — Enhanced overlay toggle (P1)
A Settings toggle switches the recording overlay between the default compact strip and an enhanced card.
Default stays the compact strip (no behaviour change for existing users).

**Acceptance**:
1. Off (default): the current bottom-center compact HUD, unchanged.
2. On: a larger card with bigger live transcript text (up to 3 lines) and a live mic-level meter.

### US2 — Live mic-level meter (P1)
While dictating (push-to-talk and hands-free), the enhanced overlay shows a segmented level meter that
tracks input loudness and settles to zero on silence / when the session ends.

**Acceptance**:
1. The meter rises with speech and falls during silence (asymmetric attack/release smoothing).
2. The level resets to 0 when dictation completes, fails, is cancelled, or hands-free stops.

### US3 — Anchor near the cursor (P2, best-effort)
When enabled and the focused field exposes a caret rect (Accessibility), the overlay is positioned just
below the text caret; otherwise it falls back to the bottom-center position.

**Acceptance**:
1. Apps exposing an AX caret rect → overlay anchored near the caret, clamped on-screen.
2. Apps that don't (or any AX failure) → bottom-center fallback. The overlay is a non-activating panel, so
   a wrong position is never destructive and never steals focus.

## Out of scope (assessed, rejected)
- Live-insert into the field while speaking + reform after LLM. Requires backspace/replace over third-party
  apps; desyncs on user edits/autocorrect/IME, risks deleting the user's own text, and breaks the
  never-Return / secure-field / focus-guard promises. Documented as deferred in the roadmap.

## Success Criteria
- Pure `LevelMeter` (RMS→0...1, dBFS floor, attack/release) and `HUDPlacement` (caret→AppKit origin,
  clamp) unit-tested in BarkCore. `Settings.enhancedHUD` with tolerant decode. Controller publishes
  `inputLevel`; both feed loops drive it; all terminal paths reset it. `swift build` clean (0 warnings),
  `swift test` green.
