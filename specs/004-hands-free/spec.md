# Feature Specification: Hands-free (voice-activated) dictation

**Branch**: `004-hands-free` | **Created**: 2026-06-19 | **Status**: Draft
**Input**: "A hotkey to toggle regular dictation on/off. When on, automatically detect and record
speech without holding a button — activate when the user speaks, deactivate when they stop."

## User Scenarios & Testing

### US1 — Toggle hands-free with a hotkey (P1)
A dedicated hotkey turns hands-free mode on/off. While on, the user just speaks — no button to hold.

**Acceptance**:
1. Pressing the hands-free hotkey once enters hands-free mode (mic monitored); pressing again exits.
2. The mode is clearly indicated (HUD/menu/icon) so the user knows it's listening.

### US2 — Voice-activated capture + auto-insert (P1)
While hands-free is on, the app detects when the user starts speaking, records that utterance, and when
the user stops (a short pause), transcribes + inserts the cleaned text — then keeps listening for the
next utterance. Repeats until toggled off.

**Acceptance**:
1. **Given** hands-free on and silence, **When** the user speaks, **Then** recording starts automatically.
2. **Given** the user stops talking (~silence), **Then** the text is cleaned + inserted, and the app
   returns to waiting for the next utterance (no toggle needed between utterances).
3. **Given** hands-free off, **Then** the mic is released and nothing is captured.

### US3 — Adjustable sensitivity (P2)
The user can tune how readily speech is detected (sensitivity: low/medium/high → energy threshold), so
it works in quiet vs noisy rooms. (The onset confirmation and silence-gap timings are fixed defaults in
v1; only sensitivity is user-facing.)

## Edge Cases
- Background noise must not trigger endless empty utterances → onset needs sustained speech; empty
  transcripts are not inserted.
- Hands-free and push-to-talk are mutually exclusive (one mic owner). Push-to-talk is ignored while
  hands-free is active; toggling hands-free off frees the mic.
- All injection safety still applies per utterance (secure-field refusal, never-Return, focus check,
  sanitize). Focus target is captured at each utterance's onset.
- Permission loss / model not ready → graceful stop with a message; mic released.

## Success Criteria
- A toggle hotkey enters/exits hands-free; while on, multiple spoken utterances are auto-captured and
  inserted with no button. Off releases the mic.
- VAD logic is pure + unit-tested; the hands-free loop is tested with fakes.
- `swift build` clean, `swift test` green.
