# Data Model: Prompt Transparency & Editing (013)

## Entities

### PromptOverride (NEW — `Sources/BarkCore/Cleanup/PromptOverride.swift`)

A user's stored edit to one built-in mode's prompt fields. Existence of a (non-empty) override marks the mode "modified".

| Field | Type | Meaning |
|-------|------|---------|
| `systemPrompt` | `String?` | Replacement task instruction. `nil` = not overridden (use shipped default). |
| `revisionPrompt` | `String?` | Replacement refinement instruction. `nil` = not overridden. |

- Conformances: `Codable`, `Sendable`, `Equatable`.
- `isEmpty`: both fields `nil` → override carries no information and must be pruned from storage.
- Validation: each non-nil field ≤ `maxFieldLength` (4,000 characters). Over-limit values are rejected at save time, never truncated (FR-009).
- Note: an *empty string* is a meaningful override ("cleared" → engine fallback per FR-010), distinct from `nil` ("untouched").

Static:
- `maxFieldLength = 4_000`

### Mode (EXISTING — `Sources/BarkCore/Cleanup/Mode.swift`)

Unchanged shape. Gains an override-application helper:

- `applyingOverride(_ override: PromptOverride?) -> Mode` — returns a copy with `systemPrompt`/`revisionPrompt` replaced where the override field is non-nil. Identity, name, symbol, `usesLLM`, and deterministic toggles are never overridden (spec assumption: only prompt fields of built-ins are editable).

### Settings (EXISTING — `Sources/BarkCore/Settings/Settings.swift`)

| Field | Type | Change |
|-------|------|--------|
| `builtInPromptOverrides` | `[String: PromptOverride]` | NEW. Keyed by built-in mode id (`raw`, `clean`, `email`, `message`, `code`, `list`). Default `[:]`. Lenient decode (`decodeIfPresent … ?? [:]`) like every other field. |

New/changed API:
- `effectiveModes() -> [Mode]` — `Mode.builtInModes.map { $0.applyingOverride(builtInPromptOverrides[$0.id]) } + customModes`. Single source of truth.
- `makeModeRegistry()` — now builds from `effectiveModes()`.

Invariants:
- Keys that don't match a built-in id are inert (ignored by `effectiveModes`) and may be pruned on write.
- An override equal in effect to the shipped default is pruned on save so "modified" is never shown spuriously.

### Safety preamble (EXISTING — `PromptTemplate.guardrail`, `PromptTemplate.refineGuardrail`)

Compile-time constants. Not persisted, not user-writable, always prefix the assembled prompt. Displayed verbatim (read-only) in the editor.

## Relationships

```text
Settings ──builtInPromptOverrides[id]──▶ PromptOverride
    │                                        │ applied by
    ▼                                        ▼
effectiveModes() = builtIns.map(applyingOverride) + customModes
    │
    ├──▶ makeModeRegistry() ──▶ pipeline (effectiveMode → PromptTemplate.system/refineSystem → MLX)
    └──▶ DictationController.modes ──▶ Settings UI (list, editor, badges)
```

## State transitions (built-in mode)

| State | Transition | Result |
|-------|-----------|--------|
| Default (no override) | user edits + saves prompt field(s) | Override written → "Modified" badge; next dictation uses edit |
| Modified | user resets | Override key removed → shipped default (current version's) back in effect; badge gone |
| Modified | user re-edits to text equal to shipped default | Override pruned → treated as Default (no badge) |
| Any | app update changes shipped default | Override (if any) still wins; reset now restores the NEW default |
| Any | dictation in flight during edit | In-flight run keeps the `Mode` value captured at start; edit applies from next run |

## Controller API (`DictationController`)

- `builtInOverride(id: String) -> PromptOverride?` — read for UI.
- `setBuiltInOverride(id: String, _ override: PromptOverride?)` — validates (built-in id, field limits), prunes empty/default-equal overrides, persists via `settings.update`.
- `isBuiltInModified(id: String) -> Bool` — badge driver.
- Existing `upsertMode`/`removeMode` unchanged for customs (upsert gains the same length validation).
