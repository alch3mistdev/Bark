# Bark — Inline Code Dictation (Quickstart)

## What this adds

Developer-specific dictation that knows about the file you're editing:

- **Language-aware comment prefix.** Dictate into a `.swift` file, get `// `. `.py`? `# `.
  `.html`? `<!-- -->`. `.json`? Refused (Bark won't generate JSON via dictation).
- **Identifier preservation.** The LLM is given the file's symbol list (functions, classes,
  variables) so when you dictate a comment that *should* reference `viewDidLoad`, the
  identifier appears verbatim in the rewrite.
- **Conventional Commits formatting.** Open a commit-message box in Tower / Sourcetree /
  GitHub Desktop / GitKraken / VS Code's Source Control panel, dictate your intent, get a
  `fix(cache): add LRU bound to prevent memory leak` subject + wrapped body + optional
  `BREAKING CHANGE:` footer.

Every feature is opt-in via Settings ▸ Code. The lean build supports the comment prefix
without an LLM; the MLX build adds identifier preservation and Conventional Commits formatting.

## Install (lean build — comment prefix only)

```bash
swift build            # fully offline, no external dependencies
swift test             # 102 → ~127 tests, all green
scripts/make-dmg.sh
open dist/Bark.dmg     # drag Bark to Applications
```

The lean build applies the comment prefix and capitalisation rules without an LLM call.
Identifier preservation and Conventional Commits formatting require the MLX build.

## Install (with code intelligence)

```bash
cp Package-mlx.swift Package.swift
# Optional: enable the SwiftSyntax-backed Swift identifier extractor.
# (Ensure SwiftSyntax is available in the MLX SwiftPM dependency graph; the
# build flag CODE_INTELLIGENCE is defined in a future #if.)
swift build -c release
```

The MLX build enables:
- Identifier preservation in code comments (Swift via SwiftSyntax; other languages via regex).
- Conventional Commits formatting for commit-message boxes.
- File-read consent dialog (the first time Bark wants to read a focused file, you choose
  Always allow / Allow once / Never for that app + language).

## Use (lean build)

1. Open a Swift file. Focus an empty line.
2. Hold `fn` and say: *"this function handles the case where the input is nil"*. Release.
3. The line becomes: `// This function handles the case where the input is nil.`

Same in Python: `# This function handles the case where the input is nil.`

## Use (MLX build)

1. **First-time consent.** The first time you dictate into a Swift file in Xcode (or any
   new app + language combination), a one-time consent dialog appears:
   - **"Bark wants to read `foo.swift` in Xcode to preserve identifiers. Allow for Swift files
     in Xcode?"**
   - Choose: **Always allow** (persisted for this app + language) / **Allow once** (this
     file only) / **Never** (blocklist; no further prompts for this app + language).
2. **Identifier preservation.** Hold `fn` and say: *"called after the view loads"*. Release.
   The comment becomes: `// Called after viewDidLoad() — runs once after the view loads.`
   (Exact text is the LLM's call, but `viewDidLoad` appears verbatim.)
3. **Conventional Commits.** Open a commit-message box in Tower / VS Code / GitHub Desktop.
   Hold `fn` and say: *"fix the memory leak in the cache by adding an LRU bound"*. Release.
   The message is:

   ```
   fix(cache): add LRU bound to prevent memory leak

   Add a size cap to the cache and evict least-recently-used entries
   when the cap is exceeded.
   ```

4. **Breaking change.** Dictate: *"this breaks the public API for the legacy client"*.
   Release. The footer is appended:

   ```
   refactor!: drop legacy v1 client support

   Move the v2 client forward; the v1 endpoints return 410 Gone.

   BREAKING CHANGE: the public v1 client API is removed.
   ```

## Settings ▸ Code

- **Master toggle** — disable to make Code mode behave like the existing Bark (raw STT
  output, no formatting).
- **Per-language prefix toggles** — turn off `//` prefixing for Swift if you want prose
  comments; turn off `#` for Python; etc. (Lean build: all prefix toggles work; the
  identifier and Conventional Commits toggles show as "Requires MLX build".)
- **Preserve identifiers** — turn off to skip the file read (the rewrite proceeds without
  symbol context).
- **Format commit messages as Conventional Commits** — turn off to skip the formatting for
  commit-message boxes.
- **File-read consent** — link to a sheet listing all `app/language` entries with Allow /
  Never / Reset controls. Useful when you change your mind later.

## What this does NOT do

- **Read the staged diff to inform scope / body.** The commit-message heuristic operates on
  the dictated text only. Reading `git diff --staged` is a separate feature.
- **Refactor / generate code from comments.** "Make this function faster" → code rewrite is
  a code-generation task, not a comment task. Separate spec.
- **Project-wide symbol lookup.** The index is per-file, not per-project. Cross-file
  references are best-effort.
- **Languages not in the prefix table.** v1 ships with the languages listed in US1. Adding
  a new language is one entry in the table; you can request additions in a follow-up.

## When Bark refuses

- **"Bark doesn't generate JSON via dictation — paste values directly."** — focused file is
  `.json` / `.toml` / similar. Paste the value manually.
- **"Not sure this is a commit-message box — formatting anyway? [Yes / No / Don't ask
  again]"** — the heuristic is uncertain. Confirm once, or set "Don't ask again" per-app.
- **"Skipping symbol index for `<path>`: `<reason>`"** — the file is unreadable, binary,
  or > 1 MB. The comment is still formatted with prefix only.
- **"Bark wants to read `<file>` in `<app>` to preserve identifiers. Allow?"** — the
  per-app-per-language consent dialog. The choice is remembered.

## Build flags

```bash
# Lean (comment prefix only, no LLM-backed features):
swift build -c release

# MLX (full code intelligence):
cp Package-mlx.swift Package.swift
swift build -c release
```

## Verification (manual, on-device only — see constitution L-5)

1. Open `foo.swift` in Xcode. Dictate a comment. Expect `// ` prefix.
2. Open `bar.py` in VS Code. Dictate a comment. Expect `# ` prefix.
3. Open `index.html` in TextEdit. Dictate. Expect `<!-- -->` wrap.
4. Open `config.json` in TextEdit. Dictate. Expect refusal.
5. Open a commit-message box in Tower. Dictate. Expect Conventional Commits format.
6. Toggle "Preserve identifiers" off. Dictate a comment that mentions `viewDidLoad`. Expect
   the identifier to be lost (rewritten as prose).
7. First-time consent: revoke "Always allow" in Settings ▸ Code ▸ File-read consent.
   Dictate again. Expect the consent dialog to re-appear for that same app+language
   combination because the prior consent entry was reset.

## Related

- Spec: `specs/010-inline-code-dictation/spec.md`
- Plan: `specs/010-inline-code-dictation/plan.md`
- Tasks: `specs/010-inline-code-dictation/tasks.md`
- ADR-008: `docs/ADR-008-code-intelligence.md` (after implementation)
- Security: `docs/SECURITY.md` (file-read surface)