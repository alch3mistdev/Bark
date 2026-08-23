# Feature Specification: Streaming Suggested Responses

**Feature Branch**: `016-streaming-suggestions`

**Created**: 2026-08-24

**Status**: Draft

**Input**: User description: "Streaming suggested responses: reduce time-to-first-candidate after the suggestions hotkey. Parse the LLM output stream incrementally and show each validated candidate in the overlay as soon as it completes, while later candidates keep generating (progressive fill, stable numbering). Prewarm the suggestion engine when the hotkey is pressed (before/parallel with context capture) instead of on request. Overlay shows a subtle 'still generating' state until the set completes or times out; selection of an already-shown candidate is allowed immediately and cancels remaining generation. All existing safety rules unchanged: candidates only shown after per-candidate validation, malformed output never shown or injected, secure-field refusal, Escape cancels everything including generation."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - See the first suggestion while the rest are still being written (Priority: P1)

A developer presses the suggestions hotkey over a terminal question. Today the overlay appears only after the entire candidate set is generated — a multi-second blank wait. With streaming, the overlay appears immediately and the first validated candidate shows up as soon as it is complete, with candidates 2–4 filling in below it while generation continues. Each candidate keeps the number it was assigned on arrival — rows never reorder or renumber under the user's eyes. A subtle "still generating" indicator sits at the bottom of the list until the set completes or times out.

**Why this priority**: The whole feature's perceived quality hinges on time-to-first-candidate. Everything else in this spec is refinement of this moment.

**Independent Test**: With a fake suggestion engine that emits candidates one at a time with controlled delays, fire the hotkey and verify: the overlay appears before any candidate exists, each candidate row appears as its text completes validation, numbering is assigned in arrival order and never changes, and the generating indicator disappears exactly when the engine finishes or the deadline passes.

**Acceptance Scenarios**:

1. **Given** the feature is enabled and a terminal is frontmost with a question visible, **When** the user presses the suggestions hotkey, **Then** the overlay appears promptly (before generation completes) showing the "Other…" option and a generating indicator, and each suggestion row appears individually as soon as that candidate is complete and validated.
2. **Given** three candidates have already appeared, **When** a fourth candidate completes, **Then** it is appended as row 4 and rows 1–3 are unchanged in text, position, and number.
3. **Given** candidates are streaming in, **When** an arriving candidate fails validation (too long, empty, duplicate of an already-shown candidate, or malformed), **Then** it is silently dropped and never rendered, and later valid candidates still appear.
4. **Given** generation completes or the overall deadline passes, **When** at least one candidate is shown, **Then** the generating indicator disappears and the overlay behaves exactly like today's completed overlay.
5. **Given** generation completes or times out with zero valid candidates, **When** that happens, **Then** the overlay shows the existing honest error state with a dismiss action — nothing is injectable.

---

### User Story 2 - Act immediately: select early, cancel the rest (Priority: P2)

The first candidate is exactly what the user wants. They press `1` (or Return on the highlighted row, or click) the moment it appears — without waiting for the remaining candidates. The chosen text is inserted through the existing routing pipeline and any in-flight generation is cancelled. Likewise, Escape or focus loss at any point during streaming cancels generation entirely and discards the captured context.

**Why this priority**: Early selection is where the latency win is actually banked — the user acts as soon as their answer exists instead of when the slowest candidate finishes.

**Independent Test**: With a fake engine that streams slowly, select candidate 1 while candidates 3–4 are still pending; verify exactly the chosen text reaches the injector, the overlay dismisses, and the engine receives a cancellation (no further candidates are produced or rendered). Repeat with Escape and with focus loss: verify cancellation, no injection, and context discarded.

**Acceptance Scenarios**:

1. **Given** at least one candidate is shown and generation is ongoing, **When** the user selects a shown candidate by number key, arrows + Return, or click, **Then** the overlay dismisses, remaining generation is cancelled, and exactly the chosen text is inserted via the existing routing pipeline.
2. **Given** generation is ongoing, **When** the user presses Escape or focus moves away, **Then** generation is cancelled, the overlay dismisses, nothing is inserted, and the captured context is discarded from memory.
3. **Given** the user selects "Other…" while candidates are still streaming, **Then** generation is cancelled and the existing one-shot dictation flow starts unchanged.
4. **Given** a selection was made during streaming, **When** a late candidate would have arrived after dismissal, **Then** no UI appears and no state is retained.

---

### User Story 3 - Faster start: prepare the engine while context is captured (Priority: P3)

Pressing the hotkey today captures context first, then asks a cold engine to generate. With this change, engine preparation begins the moment the hotkey is pressed, in parallel with context capture, so generation starts against a ready engine. If capture is refused (secure field), preparation work is simply abandoned with no side effects.

**Why this priority**: Compounds US1's win by removing fixed startup cost from the critical path, but is invisible on its own.

**Independent Test**: With instrumented fakes, verify engine preparation starts before context capture completes; verify that on secure-field refusal the preparation is abandoned, nothing is generated, and no context was read.

**Acceptance Scenarios**:

1. **Given** the feature is enabled, **When** the hotkey is pressed, **Then** engine preparation and context capture begin concurrently, and generation begins as soon as both are ready.
2. **Given** the focused field is secure/password, **When** the hotkey is pressed, **Then** the existing refusal behavior is unchanged (brief "not available here", nothing read) and any preparation started is abandoned without generating.

---

### Edge Cases

- Stream produces more valid candidates than the display cap: excess candidates are ignored; generation may be cancelled once the cap is reached.
- Stream emits a duplicate of an already-shown candidate: dropped silently (dedupe applies across the incremental set, not just within one batch).
- Overall deadline fires while some candidates are shown: shown candidates stay selectable; indicator disappears; no error state (partial success is success).
- Deadline fires with zero candidates: existing error state, unchanged.
- User is arrow-navigating rows when a new candidate arrives: the highlighted row must not shift or change identity because of the append.
- Configured backend cannot deliver output incrementally: feature degrades to today's all-at-once behavior — same overlay, candidates simply arrive together; no error, no regression.
- Candidate text is complete but the surrounding stream is malformed: per-candidate validation decides — a candidate is shown only after it individually passes the same validation rules used today; partial or trailing fragments are never rendered.
- Rapid re-trigger: pressing the hotkey again while a streaming session is active follows today's re-trigger behavior (the prior session is cancelled and discarded before the new one starts).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST display each suggestion candidate as soon as that candidate is individually complete and validated, without waiting for the full set.
- **FR-002**: Each candidate MUST pass the same validation applied today (length cap, non-empty, sanitization, dedupe against already-shown candidates, display cap) before being rendered; failing candidates are dropped silently.
- **FR-003**: Candidate numbering MUST be assigned in arrival order and remain stable for the life of the overlay; existing rows never reorder, renumber, or change text when later candidates arrive.
- **FR-004**: The overlay MUST show a non-intrusive "still generating" indicator from first display until generation completes, the deadline passes, or the session is cancelled.
- **FR-005**: Users MUST be able to select any displayed candidate (number key, arrows + Return, click) while generation is ongoing; selection cancels remaining generation before the chosen text is inserted through the existing routing pipeline.
- **FR-006**: Escape or focus loss during streaming MUST cancel generation, dismiss the overlay, insert nothing, and discard the captured context — identical guarantees to the existing dismissal rules.
- **FR-007**: Selecting "Other…" during streaming MUST cancel generation and start the existing one-shot dictation flow unchanged.
- **FR-008**: Engine preparation MUST begin when the hotkey is pressed, concurrently with context capture; secure-field refusal MUST abandon preparation with no capture, no generation, and no user-visible side effects beyond the existing refusal state.
- **FR-009**: Partial, in-progress, or malformed candidate text MUST never be rendered in the overlay nor be injectable, at any point in the stream's life.
- **FR-010**: If the active suggestion backend cannot deliver output incrementally, the system MUST degrade gracefully to current behavior (candidates appear together when ready) with no error and no loss of existing functionality.
- **FR-011**: When the deadline passes with at least one candidate shown, the shown candidates MUST remain selectable and the session completes normally; with zero candidates, the existing error state MUST be shown.
- **FR-012**: The "Other…" option MUST be available from the moment the overlay appears, before any candidate has arrived.
- **FR-013**: All auto-submit, secure-field, and injection safety rules from the existing feature MUST apply unchanged to candidates selected during streaming.

### Key Entities

- **Streaming suggestion session**: The lifecycle from hotkey press to dismissal — states: preparing (engine warm-up + context capture in parallel), generating (candidates arriving), complete (set finished or deadline passed with ≥1 candidate), failed (zero candidates), cancelled (Escape, focus loss, early selection, re-trigger).
- **Candidate**: A single validated suggestion with an arrival-ordered stable number; exists only after passing validation; immutable once displayed.
- **Generating indicator**: Overlay affordance signaling more candidates may arrive; present only during the generating state.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Median time from hotkey press to the first selectable candidate is reduced by at least 40% compared to the pre-streaming build on the same hardware, model, and prompt corpus.
- **SC-002**: In the replay test corpus, 100% of candidates rendered during streaming are byte-identical to the candidates the non-streaming parser would have produced for the same raw output — streaming changes when candidates appear, never what they say.
- **SC-003**: Selecting a candidate mid-stream injects exactly the chosen text in 100% of test runs, with zero instances of partial or late-arriving text being rendered or injected across the fuzz/replay corpus.
- **SC-004**: After Escape, focus loss, or early selection, no further overlay updates occur in 100% of test runs.
- **SC-005**: With a backend that cannot stream, all existing 015 acceptance scenarios still pass unchanged.

## Assumptions

- The existing overlay can be extended to append rows incrementally; overlay position and size behavior are otherwise unchanged.
- The local suggestion engine produces output incrementally today (it already streams internally); "cannot stream" applies mainly to some external endpoints, which fall back to all-at-once display.
- The overall generation deadline, candidate cap (3–4 plus "Other…"), validation rules, prompt content, context capture, history usage, and settings surface are unchanged by this feature.
- Engine preparation ("prewarm") has no user-visible effect and reads no context by itself; it only readies the engine, so starting it before capture consent is resolved is safe and is abandoned on refusal.
- Cancellation of in-flight generation is best-effort at the engine level; the hard guarantee is at the UI/injection boundary (no rendering, no injection after dismissal), consistent with existing safety posture.
