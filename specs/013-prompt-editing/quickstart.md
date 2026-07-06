# Quickstart Validation: Prompt Transparency & Editing (013)

## Prerequisites

- macOS 15+, Xcode/Swift 6.1 toolchain
- Repo root: `/Users/alch3mist/DevRepos/scratch/Bark`

## Build & unit tests (Constitution gate)

```sh
swift build          # must be clean
swift test           # must be green; includes PromptOverrideTests + SettingsTests additions
```

Expected new/updated tests (see contracts & data-model for semantics):

- `PromptOverrideTests`: override application, reset semantics, default-equal pruning, 4,000-char limit rejection, empty-string → engine fallback, byte-identity of assembled prompt with override text, unknown-key inertness.
- `SettingsTests`: round-trip encode/decode with overrides; lenient decode of legacy payload (no `builtInPromptOverrides` key).

## Manual validation (app)

Run the app (`swift run bark` or built product), open Settings › Modes.

| # | Scenario (spec ref) | Steps | Expected |
|---|---------------------|-------|----------|
| 1 | View exact prompt (US1) | Open "Email" mode | Guardrail shown verbatim, read-only + task instruction matching `Mode.email.systemPrompt`; refine section with its revision prompt |
| 2 | Non-LLM mode (US1/FR-011) | Open "Clean" mode | "No rewrite prompt is sent" statement; refine prompt section still shown and editable (hold-to-refine fires in every mode) |
| 3 | Edit built-in (US2) | Edit Email task instruction (e.g., "…casual, friendly…"), save; dictate in Email mode | Rewrite follows edited instruction; row shows "Modified" badge |
| 4 | Persistence (US2/SC-005) | Quit + relaunch app | Edited prompt still shown and in effect |
| 5 | Reset (US2/SC-004) | Click "Reset to Default" on Email | Text returns to shipped default exactly; badge disappears; reset disabled/hidden when unmodified |
| 6 | Empty fallback (FR-010) | Clear Email task instruction, save | Editor states fallback; dictation uses generic default instruction |
| 7 | Length bound (FR-009) | Paste >4,000 chars into task field | Live count shows over-limit; Save disabled; message states 4,000-char limit |
| 8 | Custom full edit (US3) | Reopen an existing custom mode | Task AND refinement instructions shown in full; both editable; edits persist and drive rewrite + hold-to-refine |
| 9 | Guardrail immutable (SC-006) | Any editor | Guardrail section not editable anywhere; assembled preview always starts with guardrail |

## Evidence capture

Per Constitution II: record `swift build`/`swift test` output in the PR, plus screenshots of scenarios 1, 3, 5, 7.
