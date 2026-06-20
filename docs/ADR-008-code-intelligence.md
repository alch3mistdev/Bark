# ADR-008 — Inline code comment + commit-message dictation

**Status:** Proposed (pending spec review — see `specs/010-inline-code-dictation/spec.md`)
**Date:** 2026-06-19
**Context:** `specs/010-inline-code-dictation/spec.md`

## Context

Developers use Bark for two pain points: commit messages and code comments. Today both work
in principle via the existing `Code / Commit` mode, but the experience is poor: no language-
aware comment prefix, identifiers get lost to prose rewrite, commit messages are paragraphs
rather than Conventional Commits. Every competitor treats code as a generic text field. This
is the dev-specific wedge for Bark — the #2-ranked feature from the 2026-06-19 competitive
analysis.

## Decision

### 1. Language-prefix table lives in `BarkCore` (lean-build-friendly)

A static table mapping file extension → comment style. The lean build applies the prefix +
capitalisation + termination rules without an LLM call. This is the no-LLM fast path:
genuinely useful (the `// ` prefix alone is a big UX win) and works in every build.

The table covers Swift, Python, TS/TSX, JS/JSX, Go, Rust, Java, Kotlin, Ruby, C/C++/Obj-C,
Shell (sh/bash/zsh), SQL, HTML, CSS/SCSS, YAML/TOML, JSON, Markdown. New languages are
one-line additions.

### 2. Identifier extraction is a protocol with two impls

```swift
public protocol LanguageIdentifier: Sendable {
    func extractIdentifiers(from source: String, maxCount: Int) throws -> [String]
}
```

- `RegexLanguageIdentifier` (in `BarkCore`) — language-specific patterns, strips comments
  and string literals first, returns up to `maxCount` (default 500) distinct identifiers
  in source order. Always available.
- `SwiftSyntaxLanguageIdentifier` (in `BarkCleanupMLX`, gated by `#if CODE_INTELLIGENCE`) —
  uses `SwiftParser` to walk the AST and collect `IdentifierExprSyntax`,
  `FunctionDeclSyntax`, `ClassDeclSyntax`, etc. Higher precision; available when the
  MLX build flag is on.

The lean build uses regex for all languages. The MLX build uses SwiftSyntax for Swift
and regex for everything else. The pipeline depends only on the protocol.

### 3. File-read consent is per-app-per-language (US5)

Reading the focused file to build the symbol index is a meaningful privacy expansion over
today's Bark. The new behaviour needs explicit per-app-per-language opt-in the first time
the heuristic would read a file in a given app+language combination. The consent list is
persisted in `Settings.codeIntelligence.fileReadConsents` (keyed by
`"\(bundleID)/\(language)"`); the user can change their mind via Settings ▸ Code ▸
File-read consent.

The first-time default is **"Allow once"** (not "Never") because the worst case is a one-time
read with no persistence; "Never" as the default would require explicit choice every time
the user encounters a new app+language, which is high friction. The v1 default is documented
and can be flipped to "Never" if the adversarial review flags it as a leak.

### 4. Conventional Commits formatting is a heuristic + LLM

A multi-signal `CommitBoxDetector` heuristic (known app list, AX role, first-line length,
surrounding AX labels) decides whether the focused field is a commit-message box. On
detection, the dictated text is rewritten by the LLM with a system prompt that gives the
Conventional Commits output structure (subject `<type>(<scope>):`, body, optional
`BREAKING CHANGE:` footer, 72-char wrap). The lean build skips the formatting and inserts
the dictated text as-is.

A confidence threshold (≥ 0.7) means the heuristic only auto-formats when it's sure. Below
the threshold, the user sees a one-time per-app toast: *"Not sure this is a commit-message
box — formatting anyway? [Yes / No / Don't ask again]"*. The choice is remembered per-app.

### 5. Identifier preservation: the LLM is given context, not constraints

The system prompt for code comments fences the symbol list as `<symbols>` (user data, not
instruction) and the dictated text as `<transcript>` (also user data). The LLM is instructed
to use the symbols verbatim when the dictated prose semantically references them. This is
*influence*, not a hard constraint — the LLM is allowed to drop symbols that don't fit the
rewritten comment. The constraint is the user's mental model: "if I said viewDidLoad, it
should appear verbatim in the output."

`OutputValidator` gains a new rule: flag identifiers in the rewrite that don't appear in
the symbol index and aren't standard library symbols. This is best-effort (a reference to
an imported type from another module is valid but won't be in the index). The validator
doesn't reject — it surfaces a warning in the history record so the user can review.

### 6. Lean-build fallback is graceful, not absent

- US1 (comment prefix) works in every build.
- US2 (identifier preservation) requires the LLM; lean build skips it, comment is
  prefix-only.
- US3 (Conventional Commits) requires the LLM; lean build skips it, dictated text is
  inserted as-is.

The user is informed in Settings ▸ Code: *"Full identifier preservation and Conventional
Commits formatting require the MLX build. The lean build formats comments with the
language prefix only."*

### 7. STRIDE update

`docs/SECURITY.md` gains a "File read for code intelligence" section. Honest residuals:
SwiftSyntax reads the file's content; the LLM is given the symbol list; the consent dialog
can be bypassed by a user who clicks "Always allow" and we never re-prompt; the regex
extractor on non-Swift files can include false positives.

## Consequences

- **Lean build unchanged in dependencies.** All new code is in `BarkCore` (no deps) plus
  `BarkCleanupMLX` (already pulls MLX). The SwiftSyntax-backed identifier extractor
  is gated by a new `#if CODE_INTELLIGENCE` flag, mirroring the existing pattern.
- **Privacy posture is explicit.** The file read is a meaningful expansion; the per-app-
  per-language consent flow names the app by name + bundle ID, the file by name, and
  the language by extension + display name.
- **The protocol contract holds.** `LanguageIdentifier` is a new protocol; `STTEngine`,
  `TextCleaner`, `TextInjector` are unchanged. The controller composition root grows
  by one dependency (`CodeIntelligenceCoordinator`).
- **Wedge for the dev audience.** This is the feature that makes Bark the dev's choice.
  Combined with the voice-driven revision surface (ADR-007) and the offline posture
  (constitution I), it gives Bark a unique position in the dictation category for
  developers specifically.
- **No new network events.** The file read is local. The symbol index is local. The LLM
  call uses the existing on-device `MLXTextCleaner`.

## Alternatives considered

- **Always read the file without consent.** Rejected: violates constitution IV. The
  privacy expansion is too meaningful to skip explicit consent.
- **Default to "Never" for the consent dialog.** Rejected: too much friction. The
  "Allow once" default is the least surprising — the user sees the dialog, makes a
  choice, and we're done. "Never" can be set explicitly.
- **Project-wide symbol index.** Rejected: too expensive (would need to index every
  file in the project) and out of scope per spec.
- **Read the staged diff for commit messages.** Rejected as v1 scope: requires running
  `git diff --staged` from the focused app's working directory, which is a separate
  substantial feature. Tracked as a follow-up.
- **Inline code generation from comments (the reverse direction).** Rejected as out of
  scope: this is a code-generation task, not a comment task. Arguably more dangerous
  (it injects runnable code). Separate spec.

## Verification

- `swift build` clean (lean + MLX). `swift test` — 102 → ~127 tests, all green.
- Tests cover: language table lookup for all v1 languages, regex extractor happy paths
  + comment/string stripping + cap behaviour, SwiftSyntax extractor happy paths (MLX
  build), Conventional Commits formatter (types, scope, breaking-change footer, 72-char
  wrap), consent dialog UI state, lean-build fallback paths.
- Manual: dictate into Swift / Python / HTML files in Xcode, VS Code, TextEdit, and
  verify the prefix is correct. Open a commit-message box in Tower / VS Code and
  verify the format. Lean-build smoke: prefix works, identifier preservation skipped,
  Conventional Commits skipped.
- SECURITY.md ☐ → ☑ for the new file-read surface.

## Related

- `specs/010-inline-code-dictation/spec.md` — the user stories, acceptance criteria,
  success criteria, and out-of-scope calls.
- `specs/010-inline-code-dictation/plan.md` — implementation approach, files, risks.
- `specs/010-inline-code-dictation/tasks.md` — 11 phases, ~50 tasks.
- `docs/SECURITY.md` — STRIDE addition for the file-read surface.
- `docs/COMPETITIVE_ANALYSIS.md` — gap analysis that ranked this #2.
- ADR-007 — voice-driven revision (the #1 feature). Composes with this spec; both are
  dev-wedge features.