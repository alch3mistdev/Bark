# Feature Specification: In-session voice refinement (hold-to-refine)

**Feature Branch**: `012-staged-refinement`

**Created**: 2026-06-23

**Status**: Draft

**Input**: User description: While holding fn and after speaking a base utterance, hold the
left-option key to speak a transform instruction that rewrites the running draft; repeat while fn
is held, each instruction building on the prior result; release fn to inject the final draft.

## Clarifications

### Session 2026-06-23

- Q: How is the LLM rewrite prompt built per dictation mode? → A: Per-mode refine prompt template,
  reusing feature 009's revision-prompt field + prompt fencing, with a generic default for modes
  that do not define one.
- Q: What does an empty left-option turn (press/release with no speech) do? → A: One-step undo of
  the most recent refinement (repeatable); a no-op when there is no refinement to undo. This
  supersedes the earlier "empty turn = no-op" behavior.
- Q: Is there a Settings toggle for the feature and what is its default? → A: A "Enable
  hold-to-refine" toggle, default ON when an LLM is available; off / no-op in the lean build.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Single refinement before injection (Priority: P1)

While holding fn and after speaking a base utterance, the user presses and holds **left-option**,
speaks a transform instruction ("make it sound very happy"), then releases left-option. Bark
rewrites the running draft per the instruction and shows the new draft in the HUD; releasing fn
injects that refined text instead of the base text.

**Why this priority**: This is the core of the feature; without it there is no second stage.

**Independent Test**: Hold fn, say "hello my name is foo", hold left-option, say "sound very
happy", release left-option then fn → the focused field receives a happy rephrasing ("hi there!
they call me foo!"), not the literal base text.

**Acceptance Scenarios**:

1. **Given** fn is held and a base utterance was spoken, **When** the user holds left-option,
   speaks an instruction, and releases left-option, **Then** the running draft is rewritten by the
   LLM using the instruction and the HUD shows the updated draft (no injection yet).
2. **Given** a refinement completed, **When** the user releases fn, **Then** the latest draft is
   injected, subject to the existing focus / secure-field controls.
3. **Given** at least one refinement has been applied, **When** the user does an empty left-option
   turn (press/release with no speech), **Then** the draft reverts to its state before the most
   recent refinement (one-step undo) and nothing is injected; with no refinement to undo the empty
   turn is a no-op.
4. **Given** a rewrite fails validation or exceeds the deadline, **When** the refinement
   completes, **Then** the prior draft is preserved and a non-destructive "refinement rejected"
   cue is shown; the session continues.

---

### User Story 2 - Chained refinements (Priority: P1)

Without releasing fn, the user repeats the left-option gesture multiple times; each instruction
operates on the result of the previous one. Only the final draft is injected on fn release.

**Why this priority**: Multi-turn chaining is the differentiator versus feature 009 (single-turn,
post-injection). It is the user's primary example.

**Independent Test**: Hold fn, say "hello my name is foo"; left-option → "change name to bar" →
draft becomes "hello my name is bar"; left-option → "make a longer introduction" → draft becomes
"greetings and salutations everyone, I am the one they call bar…"; release fn → the final draft is
injected.

**Acceptance Scenarios**:

1. **Given** one refinement has been applied, **When** the user holds left-option again and speaks
   a second instruction, **Then** the second instruction operates on the current (already-refined)
   draft.
2. **Given** multiple refinements, **When** the user releases fn, **Then** only the final draft is
   injected; intermediate drafts are never injected.
3. **Given** a new left-option press arrives while a prior rewrite is still in flight, **When**
   both complete, **Then** refinements apply in order (FIFO), each on the prior result.

---

### User Story 3 - Continue dictating between refinements (Priority: P2)

Speech spoken while fn is held but left-option is **not** held is mode-cleaned and appended to the
running draft as additional dictated content, so the user can add material and then shape it.

**Why this priority**: Flexibility — lets the user build up content and refine iteratively within
one fn session rather than re-dictating.

**Independent Test**: Hold fn, say "first point"; left-option → "make this a bullet list" → draft
shaped; say "second point" (appended); left-option → "tighten it" → release fn → final draft
contains both points as a tightened list.

**Acceptance Scenarios**:

1. **Given** fn held and left-option not held, **When** the user speaks, **Then** the transcribed
   text is mode-cleaned and appended to the current draft.
2. **Given** content was appended after a refinement, **When** the next refinement runs, **Then**
   it operates on the combined draft (prior refined text + appended dictation).
3. **Given** the base utterance before the first left-option press, **When** the first refinement
   runs, **Then** it operates on the selected-mode output of that base utterance.

---

### User Story 4 - Live HUD feedback for the refine session (Priority: P2)

The HUD distinguishes three states — dictating (live partial + level meter), instruction capture
(left-option held), and refining (rewrite running) — and shows the current draft after each turn.

**Why this priority**: Without a visible evolving draft the multi-turn flow is opaque and the user
cannot tell whether an instruction landed.

**Independent Test**: Run a two-turn refinement and observe the HUD move through dictating →
instruction → "refining…" → updated-draft for each turn.

**Acceptance Scenarios**:

1. **Given** the dictation context, **When** the user speaks, **Then** the HUD shows the live
   partial and level meter (as today).
2. **Given** left-option is held, **When** the user speaks, **Then** the HUD indicates an
   instruction is being captured (visually distinct from dictation).
3. **Given** a rewrite is running, **When** it completes, **Then** the HUD shows "refining…" while
   in flight and the new draft on completion.

---

### User Story 5 - Graceful behavior without the LLM (Priority: P2)

When no LLM cleaner is available (lean build, LLM disabled, or not yet ready), the second stage is
unavailable: left-option is ignored, all speech is treated as dictation, and the base text injects
exactly as today. A subtle one-time hint explains that refinement needs the LLM.

**Why this priority**: The feature must not regress the lean build; base dictation must always
work (fail-open).

**Independent Test**: With the lean build, hold fn, say "hello", hold left-option, say "sound
happy", release → "hello" (mode output) is injected unchanged; a one-time hint notes refinement
needs the LLM.

**Acceptance Scenarios**:

1. **Given** no LLM is available, **When** the user holds left-option and speaks, **Then** no
   refinement occurs and the speech keeps appending as dictation.
2. **Given** no LLM is available, **When** the user releases fn, **Then** the base / dictated text
   injects exactly as it does today.
3. **Given** an LLM is available but the "Enable hold-to-refine" setting is off, **When** the user
   holds left-option, **Then** the gesture is ignored and base dictation injects exactly as today.

---

### User Story 6 - Security parity at injection (Priority: P1)

The spoken instruction is treated as untrusted data and fenced like existing LLM prompts; rewrite
output passes existing validation/sanitization; and the final injection (only on fn release)
re-runs all existing controls: secure-field refusal, focus-guard PID re-check, sanitizer, and
never synthesizing Return/Enter.

**Why this priority**: Every new text-touching surface must re-verify Bark's security posture; the
instruction is a prompt-injection vector and the refined draft is still injected text.

**Independent Test**: Begin a refine session targeting TextEdit, switch focus to a password field
before releasing fn → injection is refused with the standard secure-field message; the field is
not mutated.

**Acceptance Scenarios**:

1. **Given** a spoken instruction, **When** the rewrite prompt is built, **Then** the instruction
   is fenced as user-data and cannot escalate into prompt instructions.
2. **Given** a rewrite result, **When** it becomes the new draft, **Then** it has passed the
   existing output validation and sanitizer.
3. **Given** fn release, **When** the final draft is injected, **Then** secure-field refusal and
   focus-guard re-check run exactly as on the primary path.

---

### Edge Cases

- Right-option (not left) pressed during a session → ignored; only left-option opens a refine turn.
- Left-option pressed with no active fn session → ignored (behaves as an ordinary modifier).
- fn released while left-option is still held → flush the in-progress instruction (apply it if
  non-empty), then inject.
- fn released while a rewrite is in flight → await it (bounded by the existing cleanup deadline),
  then inject the result, not a stale draft.
- Empty instruction turn → one-step undo of the last refinement (repeatable down to the base
  draft); no-op if there is nothing to undo; never injects.
- Undo requested while a rewrite is in flight → the undo settles against the stack after the
  in-flight rewrite resolves (or is queued behind it); the snapshot stack is never corrupted.
- Rapid repeated left-option presses → serialized FIFO; each applies to the prior result.
- Rewrite errors / times out / fails output validation → prior draft preserved; cue shown; session
  continues.
- Very long fn session → mic stays open for the hold; per-utterance audio caps apply per segment;
  draft and audio stay on-device.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: While fn (push-to-talk) is held, the system MUST detect press and release of the
  **left-option** key specifically, distinct from right-option, and use it to open and close a
  refinement turn.
- **FR-002**: On left-option release, the system MUST transform the current running draft using the
  speech captured during the left-option hold as the instruction, via the LLM cleaner, and replace
  the draft with the result.
- **FR-003**: The system MUST support multiple sequential refinement turns within a single fn
  session, each operating on the result of the previous turn.
- **FR-004**: Before the first refinement, the running draft MUST equal the selected mode's output
  of the base utterance (current pipeline behavior).
- **FR-005**: Speech captured while fn is held and left-option is NOT held MUST be mode-cleaned and
  appended to the running draft as dictated content.
- **FR-006**: The system MUST inject only the final draft, only on fn release, and MUST NOT inject
  intermediate drafts.
- **FR-007**: An empty instruction turn (left-option press/release with no speech) MUST revert the
  draft to its state before the most recent refinement (one-step undo); the gesture MUST be
  repeatable down to the base draft and MUST be a no-op when no refinement remains to undo. It MUST
  NOT inject.
- **FR-008**: Refinement turns MUST be serialized; if a turn begins before a prior rewrite
  completes, they apply in order (FIFO).
- **FR-009**: On fn release with a rewrite in flight or an open instruction, the system MUST
  finalize/await it before injecting, bounded by the existing cleanup deadline.
- **FR-010**: If a rewrite errors, times out, or fails output validation, the system MUST preserve
  the prior draft and surface a non-destructive cue.
- **FR-011**: When no LLM cleaner is available, the system MUST ignore the left-option gesture,
  treat all speech as dictation, inject base text as today, and never block dictation.
- **FR-012**: The HUD MUST distinguish dictation, instruction-capture, and refining states and
  display the current draft after each turn.
- **FR-013**: The spoken instruction MUST be treated as untrusted data and fenced in the rewrite
  prompt; rewrite output MUST pass the existing output validation and sanitization.
- **FR-014**: Final injection MUST re-run the existing secure-field, focus-guard, sanitizer, and
  no-Return/Enter controls unchanged.
- **FR-015**: The second stage MUST be limited to hold-fn push-to-talk sessions; toggle and
  hands-free dictation styles MUST be unaffected.
- **FR-016**: The rewrite prompt MUST use the active mode's refine prompt template — reusing the
  per-mode revision-prompt field shared with feature 009 — when one is defined, and a generic
  refine prompt otherwise; the spoken instruction remains fenced as untrusted data per FR-013.
- **FR-017**: The feature MUST be controlled by an "Enable hold-to-refine" setting that defaults to
  ON when an LLM cleaner is available; when the setting is off (or no LLM is available, per FR-011)
  the left-option gesture MUST be ignored and base dictation MUST be unchanged.

### Key Entities *(include if feature involves data)*

- **Refinement session**: state spanning one fn hold — the running draft, the current capture
  context (dictation vs instruction), the turn queue, and a **draft-snapshot stack** (one snapshot
  pushed before each refinement) enabling repeatable one-step undo.
- **Refinement turn**: one left-option hold → captured instruction → resulting draft (or, when the
  instruction is empty, a one-step undo that pops the snapshot stack).
- **Running draft**: the evolving text — mode output of the base utterance plus appended
  dictation, transformed by each turn; the only thing injected, and only on fn release.
- **Instruction**: an untrusted spoken directive applied to the draft via the LLM.
- **Mode refine prompt**: an optional per-mode template (the revision-prompt field shared with
  feature 009) that shapes how an instruction is applied; falls back to a generic refine prompt.
- **Hold-to-refine setting**: a user toggle, default ON when an LLM cleaner is available, that
  enables the second stage.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: The system reproduces all three example interactions exactly — base-only, single
  refinement, and two chained refinements.
- **SC-002**: When the user does not use left-option, base dictation has no user-perceptible added
  delay; the refine path is fully opt-in and the primary path is unchanged.
- **SC-003**: With no LLM (lean build), base dictation behavior is identical to today and
  left-option is a no-op.
- **SC-004**: Left-option is distinguished from right-option in at least 99% of presses;
  right-option never triggers a refinement.
- **SC-005**: Across chained refinements, only the final draft reaches the focused field;
  intermediate drafts are never injected.
- **SC-006**: A failed or timed-out rewrite never corrupts or loses the prior draft; the session
  remains usable.
- **SC-007**: `swift build` (lean) and `swift build` (MLX) are clean and `swift test` is green;
  new unit tests cover turn sequencing, append-between-turns, the empty-instruction undo, fail-open
  without LLM, the disabled-toggle no-op, and left-vs-right-option discrimination, using injected
  fakes.
- **SC-008**: An empty left-option turn reverts exactly one refinement and is repeatable down to
  the base draft; it never injects and never corrupts the draft.

## Assumptions

- The trigger key is the left-option key — default and fixed for v1; configurability is future work.
- Left-option vs right-option is determined by the changed key's keycode on the modifier-change
  event; the generic "flags can't tell left from right" limitation does not apply because the
  refine detector reads the keycode, not just device-independent flags.
- The second stage requires an available LLM cleaner (the MLX build). The lean build keeps base
  dictation fully functional (fail-open).
- Refinement reuses the existing LLM cleaner, prompt-fencing, output validation, and cleanup
  deadline — no new model and no new network path (offline-first preserved).
- The per-mode refine prompt reuses feature 009's revision-prompt field; if that field does not yet
  exist when this feature is built, this feature introduces the equivalent per-mode field. A generic
  refine prompt always exists as the fallback, so the feature does not hard-depend on 009 shipping
  first.
- Each appended dictation segment receives the same mode treatment as a standalone utterance today.
- Scope is push-to-talk (modifierHold) only; toggle and hands-free are explicitly out of scope.
- The microphone remains open for the duration of the fn hold; the running draft and per-turn audio
  stay on-device.
