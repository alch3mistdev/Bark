# Contract: Settings payload & Modes UI (013)

## Persisted settings (UserDefaults key `com.bark.settings.v1`, JSON)

Addition to the `Settings` object. All existing fields unchanged.

```jsonc
{
  // ... existing Settings fields ...
  "builtInPromptOverrides": {          // NEW, optional — absent ⇒ {}
    "email": {
      "systemPrompt": "Rewrite as a friendly, casual email body...",  // optional
      "revisionPrompt": null            // optional; null/absent ⇒ not overridden
    }
  }
}
```

Compatibility rules:
- **Older app reading newer payload**: unknown key is ignored by `decodeIfPresent` pattern — no crash, overrides simply inactive.
- **Newer app reading older payload**: missing key decodes to `{}` — all built-ins default.
- Keys must be built-in mode ids (`raw`, `clean`, `email`, `message`, `code`, `list`); unknown keys are inert and may be pruned on next write.
- Both override fields ≤ 4,000 characters; writers must reject (not truncate) longer values.
- Empty-object overrides (`{}` / both fields null) must not be persisted (pruned).

## Prompt assembly (unchanged — normative reference)

For an effective mode `m` the engine sends exactly:

- Rewrite system message: `PromptTemplate.guardrail + "\n\nTask: " + t` where `t = m.systemPrompt` if non-empty else `"Fix grammar, punctuation, and capitalization."`
- Refine system message: `PromptTemplate.refineGuardrail + "\n\nInstruction style: " + s` where `s = m.revisionPrompt` if non-empty else `PromptTemplate.genericRefineInstruction`

The settings editor MUST render these from the same constants/functions (no duplicated literals) so display ≡ sent.

## Modes UI contract (Settings › Modes)

| Surface | Requirement |
|---------|-------------|
| Built-in row | Clickable → prompt editor. Shows "Modified" badge iff an override is stored for that id. LLM tag as today. |
| Custom row | Clickable → same editor (full `Mode` edit incl. refinement prompt). Delete as today. |
| Editor: guardrail section | Guardrail text verbatim, visibly read-only/locked, for both rewrite and refine stages. Never editable. |
| Editor: task instruction | Multiline text field, live character count, hard limit 4,000, Save disabled while over limit. Inline note: empty ⇒ falls back to the generic default instruction (text shown). |
| Editor: refinement instruction | Same as task field. Inline note: empty ⇒ generic refinement behavior (text shown). |
| Editor: non-LLM mode | States that no prompt is sent for this mode (deterministic cleanup only); prompt fields hidden or disabled. |
| Editor: built-in footer | "Reset to Default" action, enabled only when modified; single action restores shipped default text immediately. |
| Persistence | Save applies from next dictation, no restart. In-flight dictation unaffected. |
