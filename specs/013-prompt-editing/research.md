# Research: Prompt Transparency & Editing (013)

No NEEDS CLARIFICATION markers remained after `/speckit-clarify`. Research below records the design decisions and the alternatives evaluated against the existing codebase.

## R1: How to store built-in prompt edits

**Decision**: Per-mode override map `builtInPromptOverrides: [String: PromptOverride]` in `Settings`, where `PromptOverride` holds optional `systemPrompt` / `revisionPrompt` strings. Overrides are applied on top of `Mode.builtInModes` when the effective mode list is built.

**Rationale**:
- Reset-to-default is trivially "remove the override" and always restores the *current shipped* default — including defaults changed by future app updates (spec edge case).
- The "modified" indicator falls out for free: override present ⇔ modified.
- `Mode.builtInModes` stays a compile-time constant; `ModeRegistry.remove` and `DictationController.upsertMode`'s built-in-shadowing guard (`DictationController.swift:174`) keep working untouched.
- Lenient `Settings` decoding (`decodeIfPresent … ?? default`, Settings.swift:111-133) makes the new field backward/forward compatible with zero migration.

**Alternatives considered**:
- *Store edited built-ins wholesale in `customModes`*: rejected — collides with the built-in-id shadowing guard, freezes name/icon/toggles into the copy, and a future default change would silently never reach users who edited once.
- *Persist a full copy of all six built-ins in Settings*: rejected — same staleness problem, plus bloats every settings payload for the common (unmodified) case.
- *Mutable global registry seeded at launch*: rejected — loses `Sendable`/value semantics, complicates strict concurrency, and hides the modified/default distinction.

## R2: Where the effective mode list is computed

**Decision**: One function, `Settings.effectiveModes()` → `[Mode]` (built-ins with overrides applied, then customs). `makeModeRegistry()` and `DictationController.modes` both call it.

**Rationale**: Today the composition `Mode.builtInModes + customModes` is duplicated (Settings.swift:137, DictationController.swift:132). Overrides must apply at *both* call sites or the HUD/pipeline and the settings UI would disagree — SC-001 (displayed ≡ sent) forbids that. Centralizing removes the duplication instead of tripling it.

**Alternatives considered**: applying overrides only in `DictationController` — rejected; `makeModeRegistry()` is public BarkCore API and would silently return stale prompts.

## R3: What "exact prompt" means in the UI

**Decision**: The editor shows, verbatim from `PromptTemplate`: (a) the fixed guardrail (`guardrail` / `refineGuardrail`) as read-only locked text, (b) the joining scaffold ("Task: " / "Instruction style: "), (c) the editable task / refinement instruction, and (d) the documented fallbacks for empty fields ("Fix grammar, punctuation, and capitalization." / `genericRefineInstruction`). The transcript is represented by its fencing description, not sample content.

**Rationale**: `PromptTemplate.system(for:)` = `guardrail + "\n\nTask: " + task` (PromptTemplate.swift:24-29) and `refineSystem(for:)` = `refineGuardrail + "\n\nInstruction style: " + style` (PromptTemplate.swift:62-65). Rendering those same constants/derivations guarantees byte-identity with what `MLXTextCleaner` sends (MLXTextCleaner.swift:49,59). Tests assert identity by calling the same functions.

**Alternatives considered**: paraphrased/summarized prompt description — rejected by the feature's core requirement (FR-001, "no paraphrasing").

## R4: Guardrail editability

**Decision**: Guardrail text is never editable, never persisted, always rendered read-only. Only `Mode.systemPrompt` and `Mode.revisionPrompt` are user-writable.

**Rationale**: Constitution IV (non-negotiable injection defenses) + PromptTemplate's documented purpose (AIML-002/SEC-010/OWASP LLM01). The guardrail always prefixes the task at assembly time, so even a hostile task instruction cannot remove or precede it. Recorded as a spec assumption; no user decision needed.

## R5: Prompt length bound

**Decision**: 4,000 characters per instruction field, enforced in `PromptOverride.validate`/UI (live count, Save disabled) and re-checked in controller write paths. Clarified in spec session 2026-07-06.

**Rationale**: Orders of magnitude above the shipped prompts (~200-300 chars) while keeping worst-case system prompt (~4.3k chars incl. guardrail) comfortably inside the local model's context alongside a dictated transcript; a hard bound also caps `UserDefaults` payload growth. Blocking save (vs silent truncation) per FR-009.

## R6: Empty task instruction

**Decision**: Allowed; the engine's existing fallback applies (`PromptTemplate.system` substitutes "Fix grammar, punctuation, and capitalization." when the task is empty, PromptTemplate.swift:25-27; `refineSystem` substitutes `genericRefineInstruction`). The editor states the fallback inline next to each field (FR-010).

**Rationale**: Fallback already exists and is deterministic; blocking would force users to invent filler text to "clear" a prompt.

## R7: In-flight dictation semantics

**Decision**: No code needed. `effectiveMode()` is resolved when dictation starts (DictationController.swift:143-149) and the resolved `Mode` value (a struct copy) travels through the pipeline; a settings write during flight cannot retroactively change it.

**Rationale**: Value semantics of `Mode` already give the spec's required behavior (edit applies from next dictation).
