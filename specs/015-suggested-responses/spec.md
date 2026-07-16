# Feature Specification: Suggested Responses

**Feature Branch**: `015-suggested-responses`

**Created**: 2026-07-16

**Status**: Draft

**Input**: User description: "Context-aware suggested responses: hotkey captures frontmost app screen context, LLM generates 3-4 probable replies, overlay picker inserts chosen reply or falls back to dictation"

## Clarifications

### Session 2026-07-16

- Q: LLM engine policy for suggestion generation? → A: Local MLX plus a user-configurable external OpenAI-compatible endpoint (covers Ollama and cloud); opt-in toggle with a privacy warning in settings; constitution amended (v2.0.0, ADR-010). ACP bridge to CLI agents: research only, deferred.
- Q: How to capture screen context? → A: Accessibility (AX) tree first — focused element value/label/title plus window text; OCR fallback (window screenshot + on-device text recognition) when AX yields thin or no text. Both offline. Capture refused over secure fields.
- Q: Personal-data memory for suggestions (address example)? → A: History-informed only in v1 — relevant snippets from the existing encrypted dictation history feed the suggestion prompt. No new memory store.
- Q: How does the chosen suggestion reach the target app? → A: Through the existing output-routing pipeline (insert at cursor vs clipboard-only, terminal keystroke vs paste), unchanged.
- Q: Auto-submit — it does not exist today (injectors never post Return, SEC-005/T-006)? → A: Add as an opt-in setting for this feature only, default OFF, warning copy in settings, documented SEC-005/Principle IV exception (ADR-010).
- Q: How far to run speckit this cycle? → A: Spec + plan + tasks now; implementation via /speckit-implement later.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Answer a coding agent's question by picking a suggestion (Priority: P1)

A developer runs a coding agent in a terminal. The agent prints a long summary of what it just did and asks "what should I do next?". Instead of typing or dictating, the developer presses the suggestions hotkey. Bark reads the visible context of the frontmost window, generates 3–4 probable next replies (e.g. "Run the tests and fix any failures", "Commit this and open a PR", "Refactor before adding more"), and shows them in a small floating overlay near the cursor. The developer presses `2` (or arrows + Return, or clicks) and the chosen text is inserted at the terminal cursor. Pressing Escape dismisses the overlay with no effect.

**Why this priority**: This is the headline scenario the feature was requested for and is independently valuable with only the local engine, AX capture, and the existing injection pipeline. Everything else layers on top.

**Independent Test**: With a fake context source and a fake suggestion engine, fire the hotkey, verify the overlay presents the engine's candidates, select one by keyboard and by mouse, and verify exactly that text reaches the injector with the terminal keystroke strategy. End-to-end: trigger against a real terminal showing a question and verify insertion at the cursor.

**Acceptance Scenarios**:

1. **Given** a terminal is frontmost with a pending question visible and the feature is enabled, **When** the user presses the suggestions hotkey, **Then** an overlay appears showing 3–4 distinct single-line suggestions plus an "Other…" option, without the terminal losing focus.
2. **Given** the overlay is showing, **When** the user presses a number key (1–4), arrow keys + Return, or clicks a row, **Then** the overlay dismisses and exactly the chosen text is inserted at the cursor through the existing routing pipeline (keystroke strategy in terminals, paste elsewhere, clipboard-only when routing says so).
3. **Given** the overlay is showing, **When** the user presses Escape (or focus moves away), **Then** the overlay dismisses, nothing is inserted, and the captured context is discarded from memory.
4. **Given** the frontmost focused field is a secure/password field, **When** the user presses the hotkey, **Then** Bark refuses to capture, shows a brief "not available here" state, and reads nothing.
5. **Given** suggestion generation fails (timeout or unparseable output), **When** the failure occurs, **Then** the overlay shows an honest error state with a dismiss action — malformed text is never injected.

---

### User Story 2 - Dictate my own reply, optionally auto-submit (Priority: P2)

The suggestions don't fit, so the user picks "Other…" and simply speaks; the narrated reply goes through the normal dictation pipeline into the same field. Separately, a user who trusts the flow enables auto-submit in settings: after a **selected suggestion** is inserted, Bark presses Return for them so the reply is actually sent to the coding agent.

**Why this priority**: "Other" keeps the feature from being a dead end when candidates miss; auto-submit closes the loop for the hands-off terminal workflow. Both build strictly on US1.

**Independent Test**: With fakes, choose "Other" and verify a one-shot dictation starts and its result is injected into the original target; enable auto-submit and verify a Return keypress is posted only after successful insertion of a selected suggestion, and never on the dictation path, never on secure fields, never after focus changed.

**Acceptance Scenarios**:

1. **Given** the overlay is showing, **When** the user selects "Other…", **Then** the overlay dismisses and a one-shot dictation session starts; the utterance is processed by the normal pipeline and injected into the originally captured target; the session ends after the first completed (or failed) utterance.
2. **Given** auto-submit is enabled and a suggestion was selected and successfully inserted, **When** insertion completes, **Then** Bark re-verifies focus and secure-field state and posts a single Return keypress after a short settle delay.
3. **Given** auto-submit is enabled, **When** the focused app or field changed between selection and insertion, or a secure field is focused, **Then** no Return is posted.
4. **Given** auto-submit is disabled (default), **When** any suggestion is inserted, **Then** no Return is ever posted.

---

### User Story 3 - Smarter context: form fields, history, and a stronger model (Priority: P2)

A user focuses an "Address" field in a browser form and presses the hotkey. Bark reads the field's label and offers the address it has seen in past dictations alongside generic completions. In an app whose accessibility tree exposes nothing useful (some terminals, Electron apps), Bark falls back to reading the window pixels with on-device text recognition. A power user points Bark at their own Ollama server (or a cloud endpoint) for higher-quality suggestions, accepting the privacy warning; if the endpoint is down, Bark quietly falls back to the local model.

**Why this priority**: Breadth and quality. Each piece (history relevance, OCR fallback, external backend) independently improves hit-rate but none is required for the MVP loop.

**Independent Test**: Seed history with an address record, fake an AX context whose field label is "Address", and verify a history-informed suggestion appears. Fake a thin AX result and verify the OCR path is attempted (permission granted) or skipped gracefully (denied). Point the external client at a stubbed endpoint and verify request shape, key handling, and fallback-to-local on 401/timeout.

**Acceptance Scenarios**:

1. **Given** the focused field has a recognizable label (e.g. "Address") and history contains matching past outputs, **When** suggestions generate, **Then** at least one candidate reflects the user's own history content.
2. **Given** AX capture returns less than the usefulness threshold and Screen Recording permission is granted, **When** the hotkey fires, **Then** Bark captures one frame of the frontmost window, recognizes text on-device, and proceeds with that context.
3. **Given** Screen Recording permission is not granted and AX was thin, **When** the hotkey fires, **Then** the overlay explains what's missing and offers a link to grant the permission — no capture happens silently.
4. **Given** the external backend is selected and reachable, **When** suggestions generate, **Then** the request goes to the configured endpoint with the API key from the Keychain, and the response is validated exactly like local output.
5. **Given** the external backend fails (unreachable, 401, malformed response), **When** the local engine is available, **Then** Bark retries locally and the overlay still presents suggestions; the reverse escalation (local failure → network) never happens.

---

### Edge Cases

- Accessibility permission missing entirely → hotkey shows guidance state (permission deep link), captures nothing.
- AX and OCR both yield no usable text → honest empty state ("Couldn't read this screen"), no LLM call with an empty prompt.
- LLM produces fewer than 3 valid candidates → show what validated (minimum 1); zero valid → error state.
- Suggestion text over length bound or multi-line → dropped by validation, never injected.
- Hotkey pressed while a dictation session is active (push-to-talk or hands-free) → ignored.
- Hotkey pressed while the overlay is already showing → dismisses it (toggle semantics).
- Focus/app changes while overlay is open → overlay dismisses; injection preflight independently re-verifies target.
- Very long terminal scrollback → context clipped from the tail (most recent text wins); forms clip from the head.
- External endpoint configured but local model not downloaded and external fails → error state pointing at settings.
- LLM warm-up in progress when hotkey fires → overlay shows a working state; generation starts when the engine is ready or times out honestly.
- Clipboard-only routing → chosen suggestion lands on the clipboard, no keystrokes, auto-submit never fires.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: A dedicated global hotkey (user-configurable, default distinct from the dictation and hands-free hotkeys) MUST trigger the suggestion flow when the feature is enabled; the feature MUST ship disabled by default.
- **FR-002**: On trigger, the system MUST snapshot the frontmost app as the injection target and capture on-screen context via the accessibility tree: the focused element's value, label/title, placeholder, and role, plus visible window text.
- **FR-003**: When accessibility capture yields text below a usefulness threshold and Screen Recording permission is granted, the system MUST fall back to capturing a single frame of the frontmost window and recognizing its text entirely on-device.
- **FR-004**: The system MUST refuse to capture any context when a secure/password field is focused or Secure Input is active, and MUST refuse capture (not degrade) rather than read around it.
- **FR-005**: Captured context MUST be ephemeral: held in memory only, never persisted, never logged (sizes/counts only in diagnostics), never written to history, and discarded when the overlay dismisses.
- **FR-006**: Captured context MUST be bounded to a fixed character budget before prompting — clipped from the tail for terminal-like targets (most recent text retained) and from the head otherwise.
- **FR-007**: The system MUST generate 3–4 candidate responses per trigger; each candidate MUST be single-line, 1–160 characters, non-duplicate; candidates failing validation MUST be dropped, and a trigger yielding zero valid candidates MUST surface an error state instead of injecting anything.
- **FR-008**: All captured context and history snippets MUST be treated as untrusted input in prompt assembly — fenced and tag-neutralized under the same injection-hardening posture as the existing prompt templates, with a fixed non-editable guardrail.
- **FR-009**: The overlay MUST present the candidates plus an "Other…" option, support selection by number keys, arrow keys + Return, and mouse click, dismiss on Escape or focus loss, and MUST NOT steal focus from the target app while showing.
- **FR-010**: A selected suggestion MUST be delivered through the existing output-routing pipeline (insert vs clipboard-only; terminal keystroke vs paste), inheriting all existing injection safeguards (sanitization, clipboard snapshot/restore, focus re-verification, secure-field refusal).
- **FR-011**: Selecting "Other…" MUST start a one-shot dictation session targeting the originally captured app, ending automatically after the first completed or failed utterance.
- **FR-012**: An opt-in auto-submit setting (default OFF, with warning copy) MUST, after successful insertion of a selected suggestion only, re-run injection preflight (focus unchanged, no secure field, no Secure Input) and post a single Return keypress; Return synthesis MUST be confined to one dedicated component and MUST never occur on the dictation path or under clipboard-only routing (ADR-010).
- **FR-013**: Suggestion generation MUST support two backends: the existing local model, and a user-configured OpenAI-compatible endpoint (base URL + model name) whose API key is stored in the Keychain and never in the settings blob; backend selection defaults to local, and selecting external MUST display a privacy warning naming exactly what is transmitted.
- **FR-014**: External-backend failures MUST fall back to the local engine when it is enabled and available; local failures MUST NOT escalate to the network. Generation MUST run under a hard deadline with an honest error state on expiry.
- **FR-015**: When the focused field exposes a label and the dictation history contains relevant past outputs, the system MUST include up to three clipped history snippets in the prompt so candidates can reflect the user's own data; history remains opt-in and its absence MUST NOT block generation.
- **FR-016**: The suggestion flow MUST NOT start while a dictation session is active; triggering while the overlay is open MUST dismiss it; the local backend MUST reuse the existing model residency and warm/idle-unload lifecycle rather than loading a second model instance.
- **FR-017**: Every missing capability MUST degrade with guidance, not silence: absent Accessibility permission, absent Screen Recording permission, local model not downloaded, or endpoint unconfigured each produce a distinct, actionable overlay or settings state.

### Key Entities

- **Captured Context**: Ephemeral snapshot of the frontmost app — source (AX or OCR), app identity, window title, focused-field metadata (label, value, placeholder, role), visible text, clipped to budget. Never persisted.
- **Suggestion Session**: The state of one trigger — capturing → generating → presenting → injecting/dictating/failed — including candidates and highlighted selection. Exists only in memory between hotkey and dismissal.
- **Suggestion Candidate**: One proposed reply — single line, bounded length, validated before display; carries no provenance beyond this session.
- **Suggestion Backend Configuration**: User's engine choice (local | external), endpoint base URL, model name; API key referenced from the Keychain, never stored alongside.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: With the local model warm, hotkey press → overlay showing valid suggestions completes in ≤ 6 seconds on the reference machine (M3-class); the capture stage alone completes in ≤ 1 second.
- **SC-002**: Zero on-disk footprint of captured screen content: after any number of suggestion sessions, no captured context appears in history, settings, logs, or any file — demonstrable by test and by grep over the data directories.
- **SC-003**: 100% of displayed candidates satisfy the validation contract (1–4 items, single-line, 1–160 chars, deduplicated) across the unit-test corpus, including malformed-model-output cases; zero test cases result in unvalidated text reaching an injector.
- **SC-004**: Selection-to-insertion works in all four routing outcomes (paste, terminal keystroke, clipboard-only, secure-field refusal) — verified by the flow-test matrix; auto-submit posts Return in exactly the enabled+preflight-passed case of the matrix and in no other.
- **SC-005**: Both build configurations (lean and MLX) compile clean and the full test suite passes; in the lean build the feature degrades to the external backend or an honest unavailable state.
- **SC-006**: A user can complete the terminal scenario (hotkey → pick → inserted reply) end-to-end without touching the keyboard except the hotkey and one selection key.

## Assumptions

- macOS target per `Package.swift` (currently macOS 26); ScreenCaptureKit and on-device Vision text recognition are available.
- Accessibility permission is already part of Bark's permission surface; Screen Recording is new and only needed for the OCR fallback.
- The local suggestion engine rides the existing LLM opt-in (`llmEnabled`) and model download consent; no separate local-model consent is introduced.
- History-informed suggestions rely on the existing encrypted, opt-in history store (200-record cap, substring search); no schema change and no new memory store in v1.
- The existing non-activating panel + key-routing approach is validated by a spike before overlay build-out; the documented fallback is consuming keys via the existing event-tap pattern.
- ACP (Agent Client Protocol) integration with local CLI agents is out of scope for v1 (research note in research.md).
- Suggestion quality on the 4B local model is best-effort; the external backend exists precisely because some contexts exceed it.
