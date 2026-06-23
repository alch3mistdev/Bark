# Quickstart: In-session voice refinement (hold-to-refine)

Validation guide. Proves the second stage end-to-end and confirms the base path is unregressed.
Implementation detail lives in tasks.md; this file is run/verify only.

## Prerequisites

- macOS 26+, Apple Silicon.
- The **MLX build** (refinement needs the LLM): `swift build -Xswiftc -DMLXCleanup` (or the project's
  `Package-mlx.swift` configuration). The lean build has no second stage by design.
- "Enable hold-to-refine" ON (default) and the LLM enabled + downloaded in Settings.
- Push-to-talk hotkey = hold fn (default).

## Build & test

```bash
swift build                              # lean: second stage compiles out, base path intact
swift build -Xswiftc -DMLXCleanup        # MLX: second stage active
swift test                               # BarkCoreTests (pure) + BarkAppTests (flow) green
```

Targeted suites:

```bash
swift test --filter RefineSessionTests          # apply / append / undo / empty / flush
swift test --filter RefineKeyDecoderTests        # left(58) vs right(61), fn-gating
swift test --filter PromptTemplateRefineTests    # fence + per-mode vs generic
swift test --filter RefineSessionFlowTests       # the three examples, chaining, fail-open, toggle-off
```

## Manual end-to-end (the three spec examples)

Focus a plain text field (TextEdit) for each.

1. **Base only** — Hold fn, say "hello my name is foo", release fn.
   - Expect: `hello my name is foo` (selected mode's output). Identical to today. (SC-001, SC-002)

2. **Single refinement** — Hold fn, say "hello my name is foo"; hold **left-option**, say "make it
   sound very happy", release left-option (HUD shows a happy rephrase), release fn.
   - Expect: a happy rephrasing injected (e.g. "Hi there! They call me foo!"). Only the final draft
     is injected. (SC-001, SC-005)

3. **Chained + undo** — Hold fn, say "hello my name is foo"; left-option → "change name to bar" →
   release (HUD: "hello my name is bar"); left-option → "make a longer introduction" → release (HUD:
   "greetings and salutations…"); release fn.
   - Expect: the long introduction injected. (SC-001)
   - **Undo check**: after the second refinement, do an **empty** left-option tap (no speech) → HUD
     reverts to "hello my name is bar"; tap empty again → reverts to "hello my name is foo". Release
     fn → "hello my name is foo" injected. (SC-008)

## Negative / safety checks

- **Right option**: repeat example 2 using **right** option → no refinement; base text injects. (SC-004)
- **No LLM**: lean build (or toggle off) → holding left-option is a no-op; base dictation injects
  exactly as today. (SC-003, FR-011/FR-017)
- **Fail-open**: force a refine failure (offline model / `FakeCleaner.fail` in tests) → prior draft
  preserved, faint "rejected" cue, session continues. (SC-006)
- **Secure field**: start a refine session targeting TextEdit, switch focus to a password field
  before releasing fn → injection refused with the standard secure-field message; field untouched.
  (US6)

## Expected HUD states

dictating (live partial + level) → capturing instruction (visually distinct while left-option held) →
"refining…" (rewrite in flight) → updated draft shown after each turn. (FR-012)
