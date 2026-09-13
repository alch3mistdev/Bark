# Feature Specification: Socratic Discussion (pre-action prompt refinement)

**Feature Branch**: `017-socratic-discussion`

**Created**: 2026-09-13

**Status**: Draft

**Input**: User description: "Add an interactive, pre-action discussion phase before finalizing a
prompt: a real-time back-and-forth dialogue (text overlay, optional spoken voice) between the user
and the AI, Socratic in style, where the user explores ideas, clarifies intentions, and narrows
objectives. When the discussion concludes, the AI synthesizes a final prompt and inserts it at the
cursor of the focused application — any app, CLI or otherwise."

## Clarifications

### Session 2026-09-13

- Q: Primary use case? → A: Any focused text field, app-agnostic from day one (not CLI-specific).
- Q: AI output channel? → A: Text overlay is primary; optional on-device TTS
  (`AVSpeechSynthesizer`) behind a settings toggle. TTS is additive audio, never a control path.
- Q: Screen-context grounding? → A: Capture the frontmost window at session start (reusing the
  015 capture: accessibility tree with OCR fallback), plus a manual **Recapture** action
  mid-session that replaces the snapshot. Context stays in memory, never saved.
- Q: Dialogue engine? → A: Both, via the 015 engine-selection seam — on-device model by default,
  opt-in OpenAI-compatible endpoint with a privacy warning (strengthened: a discussion transcript
  reveals multi-turn intent, more sensitive than a one-shot capture).
- Q: Mic model for the user's turns? → A: Both, user picks in Settings — push-to-talk per turn, or
  continuous hands-free VAD (speaker-gate compatible). Half-duplex either way: the mic is
  hard-disarmed while TTS plays and while the engine is thinking.
- Q: Session end + handoff? → A: Preview + confirm. Synthesized prompt is shown in the overlay;
  user Confirms (inject via the existing safe-injection path), Resumes the discussion, or Cancels.
  Never auto-submits; Return is never synthesized. No auto-submit option is offered at all.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Refine a vague goal into a precise prompt by conversation (Priority: P1)

The user focuses a text field (a terminal running a coding agent, an email compose box, a doc)
and presses the discussion hotkey (default **F7**). Bark snapshots the focused target, captures
the visible window content, and opens a floating overlay in which the AI asks a first Socratic
question grounded in that context (e.g. "You're replying to a question about deployment — what
outcome do you want?"). The user answers by voice; the AI asks follow-ups that narrow scope,
surface unstated constraints, and challenge ambiguity. When goals are clear — the AI signals
readiness or the user presses **Done** — the AI synthesizes a single final prompt, shows it in a
preview, and on **Confirm** Bark inserts it at the cursor of the original app.

**Why this priority**: This is the entire feature — the dialogue loop, synthesis, and handoff.

**Independent Test**: Focus a text editor, press F7, answer 2–3 AI questions by voice, press
Done, Confirm the preview → the editor's cursor position receives the synthesized prompt text,
and nothing was typed into any other app.

**Acceptance Scenarios**:

1. **Given** a focused text field and the feature enabled, **When** the user presses F7, **Then**
   the overlay opens showing an AI opening question that references the captured window content
   (or a visible "no context" indicator if capture failed, with the discussion still usable).
2. **Given** an open session in push-to-talk mode, **When** the user holds the dictation key,
   speaks, and releases, **Then** the transcribed turn appears in the transcript and the AI's
   next question follows in the overlay (and is spoken aloud when TTS is enabled).
3. **Given** an open session in hands-free mode, **When** the user speaks and pauses, **Then**
   the turn is taken without any key press, and the mic re-arms only after the AI's reply is
   fully presented (TTS finished, if enabled).
4. **Given** the AI has signaled readiness ("Ready for me to draft it?"), **When** the user
   answers affirmatively, **Then** synthesis runs and the preview is shown.
5. **Given** the preview is shown, **When** the user chooses **Confirm** and the frontmost app
   PID still matches the session-start snapshot, **Then** the prompt is inserted through the
   existing injection path (sanitized, secure-field-refused, no Return, clipboard restored).
6. **Given** the preview is shown, **When** the user chooses **Resume**, **Then** the discussion
   continues with the full transcript intact and a later Done produces a new synthesis.
7. **Given** the preview is shown, **When** the frontmost app changed since session start,
   **Then** Bark refuses to inject, says why, and keeps the preview available for clipboard copy.

---

### User Story 2 - Spoken dialogue with TTS, without self-transcription (Priority: P2)

The user enables **Spoken replies** in Settings. During a session the AI's questions are read
aloud by the on-device synthesizer while also shown in the overlay. The microphone is never
armed while the synthesizer is speaking, so Bark never transcribes its own voice. Tapping the
dictation key during playback skips the speech immediately and opens the user's turn.

**Why this priority**: TTS is the "natural conversation" half of the request, but the feature is
fully usable text-only; TTS must layer on without creating an audio feedback path.

**Independent Test**: With TTS on and hands-free mode active, run a 3-turn session next to the
Mac's speakers → no AI-spoken words ever appear in the user's transcript turns.

**Acceptance Scenarios**:

1. **Given** TTS enabled, **When** an AI reply is presented, **Then** the reply is spoken and the
   mic remains disarmed until playback completes.
2. **Given** TTS playback in progress, **When** the user taps the dictation key, **Then**
   playback stops at once and the user's turn opens.
3. **Given** the synthesizer fails, **When** an AI reply is presented, **Then** the session
   continues text-only with no user-facing error (failure logged).

---

### User Story 3 - Mid-session context refresh and graceful engine failure (Priority: P3)

Halfway through a discussion the user switches the target window's content (e.g. the coding
agent printed new output) and presses **Recapture** in the overlay; subsequent AI questions
reference the new content. Separately: when the engine times out or errors mid-dialogue, the
overlay offers "retry turn" or "Done — draft from what we have"; the session is never silently
lost, and if synthesis itself fails twice the transcript is offered for clipboard copy.

**Why this priority**: Robustness and long-session usefulness; the P1 loop works without either.

**Independent Test**: Start a session, change the target window content, press Recapture, ask
"what do you see now?" → the AI's reply references the new content. Kill the engine mid-session
→ the retry/Done affordance appears; the transcript is never lost.

**Acceptance Scenarios**:

1. **Given** an open session, **When** the user presses Recapture, **Then** the context snapshot
   is replaced (not appended) and later replies are grounded in the new snapshot.
2. **Given** an engine reply exceeds its deadline or fails, **When** the turn errors, **Then**
   the overlay offers retry-turn and Done, and the transcript is preserved.
3. **Given** synthesis fails twice, **When** the user is notified, **Then** the transcript can be
   copied to the clipboard before the session closes.

---

### Edge Cases

- Empty STT turn (silence, or speaker-gate rejected all audio): ignored; mic re-arms (VAD) or
  waits for the next key hold (PTT). No engine call.
- User presses F7 while a session is already open: brings the overlay to front; no second session.
- Dictation hotkey (fn) pressed for ordinary dictation while a discussion session is open: the
  discussion owns the mic; in-session the dictation key *is* the turn key (PTT hold / TTS skip
  tap), and ordinary dictation is unavailable until the session ends (the overlay states this).
- Hands-free continuous dictation (F5) already running when F7 is pressed: hands-free is
  suspended for the session and resumes automatically when the session ends.
- Secure field focused at session start: session refuses to start (same policy signals as
  dictation: Secure Input active or `AXSecureTextField`).
- Target app quits mid-session: discussion may continue; Confirm refuses to inject (PID gone) and
  offers clipboard copy.
- Captured context or user speech containing prompt-injection text ("ignore your instructions"):
  fenced as untrusted data in every engine call; the Socratic system prompt is never overridable
  by screen or speech content.
- Lean build (no LLM): feature hidden/disabled — a dialogue requires an engine; no deterministic
  fallback exists.
- External endpoint selected but unreachable: same retry/Done degradation as any engine failure;
  no silent fallback to the on-device model (engine choice is explicit).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: A configurable global hotkey (default F7, off by default overall) MUST start a
  discussion session against the focused app, snapshotting the target (PID + bundle ID) and
  capturing frontmost-window context via the 015 capture path (AX tree, OCR fallback).
- **FR-002**: The session MUST run a turn loop: user speech → STT → transcript append → engine
  reply → overlay presentation (plus TTS when enabled), until synthesis or cancel.
- **FR-003**: The engine reply contract MUST carry a machine-readable readiness flag
  (`isReadyToSynthesize`) distinct from the reply text; free text MUST never drive control flow.
- **FR-004**: The user MUST be able to force synthesis (**Done**), continue past a readiness
  signal, **Resume** from preview, **Recapture** context, and **Cancel** at any point.
- **FR-005**: Mic model MUST be selectable in Settings: push-to-talk per turn, or hands-free VAD
  (speaker-gate compatible). In both, the mic MUST be hard-disarmed while TTS plays and while
  the engine is generating (half-duplex; no self-transcription).
- **FR-006**: TTS MUST be an optional, on-device, additive output (`AVSpeechSynthesizer` seam);
  its failure MUST degrade the session to text-only without data loss. A key tap MUST skip
  playback and open the user's turn.
- **FR-007**: Synthesis MUST produce a single final prompt from the transcript + current context,
  shown in a preview offering exactly Confirm / Resume / Cancel. No auto-submit exists.
- **FR-008**: Confirm MUST re-verify the frontmost app PID against the session-start snapshot and
  refuse to inject on mismatch; injection MUST use the existing router unchanged (sanitizer,
  secure-field refusal, no synthesized Return, clipboard snapshot/restore).
- **FR-009**: Engine replies and synthesis MUST be deadline-bounded and length-bounded; failures
  MUST surface retry-turn / Done affordances, and a twice-failed synthesis MUST offer the
  transcript via clipboard. The transcript MUST never be silently lost while the session is open.
- **FR-010**: Transcript and captured context MUST exist only in memory, never persisted, never
  written to history, and wiped when the session ends.
- **FR-011**: User speech and captured context MUST be fenced as untrusted data in every engine
  call, reusing the existing fencing.
- **FR-012**: Engine selection MUST reuse the 015 seam (on-device default; opt-in
  OpenAI-compatible endpoint) with a privacy warning that explicitly covers multi-turn
  transcripts. The lean build disables the feature.
- **FR-013**: Session start MUST be refused when the focused element is secure (Secure Input
  active or `AXSecureTextField`).

### Key Entities

- **DiscussionSession** (BarkCore, pure): state machine — idle → capturing → awaitingUser →
  transcribing → thinking → presenting → (loop) → synthesizing → previewing → confirmed |
  cancelled — holding the transcript and the context-snapshot reference.
- **DialogueEngine** (BarkCore protocol): `reply(history, context) → DialogueReply{text,
  isReadyToSynthesize}` and `synthesizePrompt(history, context) → String`. Conformers:
  on-device model (BarkCleanupMLX), external OpenAI-compatible engine (BarkEngines).
- **DialoguePromptBuilder** (BarkCore, pure): Socratic system prompt + untrusted-data fencing of
  speech and context; readiness-flag parsing.
- **SpeechSynthesizer** (BarkEngines protocol): speak/stop/didFinish; `AVSpeechSynthesizerEngine`
  conformer. Fake in tests.
- **DiscussionController** (Bark app): orchestration — hotkey, capture, mic gating, turn loop,
  synthesis, preview, injection handoff.
- **DiscussionOverlayController / DiscussionOverlayView** (Bark app): floating key panel —
  transcript, current AI question, state indicator, Recapture / Done / Cancel, preview with
  Confirm / Resume / Cancel.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A user can go from hotkey press to an injected, discussion-refined prompt without
  touching the keyboard except Confirm (voice-only dialogue, both mic models).
- **SC-002**: With TTS enabled, zero AI-spoken words appear in user transcript turns across a
  full session (the half-duplex invariant, asserted by an automated orchestration test).
- **SC-003**: All 015/016 suggestion behaviors and all dictation behaviors are unchanged
  (existing suites pass unmodified).
- **SC-004**: Engine failure at any point never loses the transcript: every failure path ends in
  retry, Done, or clipboard copy — asserted by orchestration tests.
- **SC-005**: Injection safety parity: secure-field refusal, PID-mismatch abort, and
  no-Return guarantees hold on the discussion path, asserted by the same test patterns as 015.

## Assumptions

- The on-device model's multi-turn quality is acceptable for v1 Socratic questioning; the
  external-endpoint seam is the quality escape hatch.
- Dialogue replies are short; v1 uses non-streaming replies (the protocol leaves room to adopt
  016-style streaming later without breaking conformers).
- `AVSpeechSynthesizer` is available on all supported macOS 26 targets with at least one
  installed voice; voice picking beyond the system default is out of scope for v1.
- Barge-in (speaking over the TTS to interrupt) is out of scope for v1; the key-tap skip covers
  the need.
- Ordinary dictation and a discussion session never share the mic; exclusivity is acceptable.
