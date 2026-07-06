# Feature Specification: Prompt Transparency & Editing

**Feature Branch**: `013-prompt-editing`

**Created**: 2026-07-06

**Status**: Draft

**Input**: User description: "In the settings area for built-in and custom prompts, users should be able to view and edit the exact prompt text used by the app. Built-in prompts should be viewable and editable (with ability to reset to default), and custom prompts should expose their full prompt text for editing."

## Clarifications

### Session 2026-07-06

- Q: What happens when a user saves an empty task instruction? → A: Saving an empty task instruction is allowed; the mode then uses the generic default instruction, and the editor states this fallback explicitly next to the field.
- Q: What is the maximum length of user-provided prompt text? → A: 4,000 characters per instruction field (task instruction and refinement instruction each); the editor shows the limit and prevents saving text that exceeds it.
- Q: Do deterministic (non-LLM) modes send any prompt? → A: They send no rewrite prompt, but hold-to-refine sends the refine prompt in every mode. The editor therefore states "no rewrite prompt" for these modes and still shows (and allows editing of) the refinement instruction, so the display always tells the truth (adversarial review finding ADV-001).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - View the exact prompt a mode uses (Priority: P1)

A user who relies on the LLM rewrite wants to see precisely what instruction text drives each mode — built-in or custom — before trusting it with their dictation. From the modes area of settings, they open any mode and see the complete, exact prompt text the app will send for that mode: the fixed safety preamble (read-only) and the mode's task instruction, plus the mode's refinement instruction when one exists.

**Why this priority**: Transparency is the foundation of the feature — without an accurate view of the real prompt, editing is meaningless. It also delivers standalone value: users can audit what the app tells the model, consistent with the project's privacy-and-trust posture.

**Independent Test**: Can be fully tested by opening each built-in mode in settings and confirming the displayed prompt text matches, character for character, what the rewrite stage actually sends for that mode.

**Acceptance Scenarios**:

1. **Given** the settings modes area is open, **When** the user selects a built-in mode that uses the LLM rewrite, **Then** the full prompt is displayed, including the fixed safety preamble and that mode's task instruction, exactly as sent to the model.
2. **Given** the settings modes area is open, **When** the user selects a custom mode, **Then** its full prompt text (task instruction and refinement instruction, if any) is displayed in full — not truncated or paraphrased.
3. **Given** a mode that does not use the LLM rewrite (e.g., a deterministic-only mode), **When** the user views it, **Then** the app clearly states that no rewrite prompt is sent for this mode, while still showing the refinement prompt that hold-to-refine would send.
4. **Given** any mode's prompt view, **When** the user inspects the safety preamble, **Then** it is visibly marked as fixed/read-only and cannot be altered.

---

### User Story 2 - Edit a built-in mode's prompt and reset to default (Priority: P2)

A user finds a built-in mode's rewrite style close-but-not-quite (e.g., the email mode is too formal). They edit that built-in mode's task instruction (and refinement instruction) directly in settings. The change takes effect for subsequent dictations and survives app restarts. A visible indicator shows the mode has been modified from its default, and a reset action restores the original text at any time.

**Why this priority**: Editing built-ins is the headline capability requested; reset-to-default is its safety net. It depends on the viewing surface from Story 1.

**Independent Test**: Edit a built-in mode's task instruction, dictate with that mode, and confirm the rewrite follows the edited instruction; then reset and confirm the original prompt text and behavior return.

**Acceptance Scenarios**:

1. **Given** a built-in mode's prompt view, **When** the user edits the task instruction and saves, **Then** subsequent dictations in that mode use the edited instruction.
2. **Given** a built-in mode has been edited, **When** the app is quit and relaunched, **Then** the edited prompt is still in effect.
3. **Given** a built-in mode has been edited, **When** the user views the modes list, **Then** the mode is visibly marked as modified from default.
4. **Given** a modified built-in mode, **When** the user chooses "Reset to default", **Then** the mode's prompt text returns exactly to the shipped default and the modified indicator disappears.
5. **Given** an unmodified built-in mode, **When** the user views it, **Then** no reset action is offered (or it is disabled), making the default state unambiguous.
6. **Given** a built-in mode's prompt view, **When** the user saves an empty task instruction, **Then** the mode uses the generic default instruction and the editor states this fallback explicitly.

---

### User Story 3 - Edit a custom mode's full prompt text (Priority: P3)

A user who created a custom mode wants to refine it over time. From settings they reopen the custom mode and edit its complete prompt text — both the main task instruction and the refinement instruction used by hold-to-refine — rather than only the single instruction field available today.

**Why this priority**: Completes the feature for custom modes. Custom modes are already editable in part, so this is an extension of an existing surface rather than a new capability.

**Independent Test**: Create a custom mode, save it, reopen it, edit both its task instruction and refinement instruction, and confirm both edits persist and drive the rewrite and refine stages respectively.

**Acceptance Scenarios**:

1. **Given** an existing custom mode, **When** the user reopens it from settings, **Then** its current task instruction and refinement instruction are shown in full for editing.
2. **Given** a custom mode with no refinement instruction, **When** the user views it, **Then** the app shows the generic refinement behavior that applies and lets the user provide a mode-specific one.
3. **Given** edits to a custom mode's prompt text, **When** the user saves, **Then** the edits persist across app restarts and are used by subsequent dictations and refinements.

---

### Edge Cases

- What happens when a user pastes an extremely long prompt? Each instruction field is bounded at 4,000 characters; the editor shows the limit and blocks saving over-limit text rather than silently truncating.
- What happens when an edited prompt contains text resembling the app's internal delimiters or attempts to countermand the safety preamble? The safety preamble remains fixed and always precedes the task instruction; the rewrite must still treat dictated speech as data only.
- What happens to an edited built-in prompt when a future app update changes the shipped default? The user's edit must remain in effect; resetting then restores the *new* shipped default.
- What happens when the user edits a prompt while a dictation is in flight? The in-flight dictation completes with the prompt it started with; the edit applies from the next dictation.
- What happens when a custom mode saved by an older app version (without a refinement instruction) is opened? It loads cleanly, showing the generic refinement behavior.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Settings MUST display, for every mode that uses the LLM rewrite, the exact prompt text sent to the model — the fixed safety preamble plus the mode's task instruction — with no paraphrasing or truncation.
- **FR-002**: Settings MUST display each mode's refinement instruction (used by the in-session refine stage) where one exists, and MUST show the generic refinement behavior when the mode defines none.
- **FR-003**: The fixed safety preamble MUST be viewable but MUST NOT be editable or removable by any user action, for any mode.
- **FR-004**: Users MUST be able to edit the task instruction and refinement instruction of every built-in mode; edits MUST persist across app restarts.
- **FR-005**: Users MUST be able to reset any edited built-in mode's prompt text to the shipped default in a single action; the reset MUST restore the current shipped default exactly.
- **FR-006**: The modes list MUST visibly distinguish built-in modes whose prompt text has been modified from the shipped default.
- **FR-007**: Users MUST be able to view and edit the full prompt text of custom modes — both the task instruction and the refinement instruction — when creating and when re-editing them.
- **FR-008**: Prompt edits MUST take effect for the next dictation without requiring an app restart; a dictation already in progress completes with the prompt it started with.
- **FR-009**: The system MUST bound each user-provided instruction field (task instruction, refinement instruction) at 4,000 characters, show the limit in the editor, and prevent saving over-limit text rather than silently truncating.
- **FR-010**: The system MUST accept an empty task instruction by applying the generic default instruction, and the editor MUST state this fallback explicitly next to the field.
- **FR-011**: Modes that do not use the LLM rewrite MUST clearly indicate in settings that no rewrite prompt is sent for them, and MUST still display (and allow editing of) the refinement instruction, because hold-to-refine sends the refine prompt in every mode.
- **FR-012**: Deleting or resetting prompt customizations MUST never alter the shipped defaults themselves; defaults remain recoverable at all times.

### Key Entities

- **Mode**: A named dictation style (built-in or custom) with a task instruction, an optional refinement instruction, and non-prompt settings (name, icon, deterministic-cleanup toggles). Built-in modes ship with default prompt text; custom modes are wholly user-defined.
- **Prompt override**: A user's stored edit to a built-in mode's task and/or refinement instruction. Its existence is what marks a built-in mode "modified"; removing it (reset) re-exposes the shipped default.
- **Safety preamble**: The fixed, read-only instruction text that always precedes any mode's task instruction and enforces that dictated speech is treated as data, never as commands.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: For 100% of LLM-rewrite modes, the prompt text shown in settings is byte-identical to the instruction text actually sent to the model for that mode.
- **SC-002**: A user can view any mode's full prompt within 2 interactions from opening the modes area of settings.
- **SC-003**: A user can edit a built-in mode's prompt and see the changed rewrite behavior in their very next dictation, with zero app restarts.
- **SC-004**: A user can restore any edited built-in mode to its default in one action, with the restored text matching the shipped default exactly in 100% of cases.
- **SC-005**: 100% of prompt edits survive an app quit-and-relaunch.
- **SC-006**: The safety preamble is present, unmodified, ahead of the task instruction in 100% of rewrite requests, regardless of any user edits.

## Assumptions

- "Exact prompts" is satisfied by showing the full assembled instruction (safety preamble + task instruction) and the refinement instruction; the dictated transcript itself varies per use and is represented by its placeholder/fencing, not by sample content.
- The safety preamble is a non-negotiable security control (prompt-injection defense) under Constitution Principle IV; it is therefore viewable for transparency but never editable. User edits are scoped to each mode's task instruction and refinement instruction.
- Editing a built-in mode's prompt does not convert it into a custom mode; it remains the same built-in mode with an override, keeping its identity, icon, and position.
- Only prompt-related fields of built-in modes become editable in this feature; names, icons, and deterministic-cleanup toggles of built-ins stay fixed.
- Existing custom modes created before this feature load unchanged; absent refinement instructions display as "generic refinement behavior" until the user provides one.
- All prompt data remains on-device with existing settings persistence; no new data leaves the device (Constitution Principle I).
