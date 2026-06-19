# Feature Specification: Inline code comment + commit-message dictation (developer-specific)

**Branch**: `010-inline-code-dictation` | **Created**: 2026-06-19 | **Status**: Draft
**Input**: Competitive analysis + product gap ranking (2026-06-19) — #2-ranked gap. Every dictation
app targets prose. Developers are a non-trivial share of macOS dictation users, and they currently
get a *worse* experience than email writers because "open the bracket function that takes a string
and returns an int" doesn't round-trip cleanly. This spec targets that audience directly.

## Problem

Developers use Bark today for two pain points: commit messages and code comments. Both work in
principle via the existing `Code / Commit` mode, but the experience is poor:

- **Code comments**: "this function handles the case where X is null" becomes the literal string
  `this function handles the case where X is null` — no comment prefix, no capitalisation, no
  sentence-termination. The user has to manually add `// ` and clean up.
- **Identifiers lost**: when the user dictates a comment that *should* reference `viewDidLoad`,
  `URLSession.shared.dataTask`, or `foo:bar:baz:`, the LLM rewrites it into prose, breaking
  references and the user's mental model of the file.
- **Commit messages**: long dictation is reformatted as paragraphs, not as Conventional Commit
  subjects + bodies. The user has to manually split and reformat.

Aqua Voice, Wispr Flow, Superwhisper, VoiceInk all treat code as a generic text field. None of
them do file-aware formatting, symbol extraction, or commit-message structuring. This is the
**dev-specific wedge** for Bark.

## User Scenarios & Testing *(mandatory)*

### US1 — Inline code comment dictation with language-aware prefix (Priority: P1)
While focused on a code file (any of `.swift`, `.py`, `.ts`, `.tsx`, `.js`, `.jsx`, `.go`,
`.rs`, `.java`, `.kt`, `.rb`, `.c`, `.cc`, `.cpp`, `.h`, `.hpp`, `.m`, `.mm`, `.sh`, `.bash`,
`.zsh`, `.sql`, `.html`, `.css`, `.scss`, `.yaml`, `.yml`, `.toml`, `.json`, `.md`), Bark's
`Code` mode wraps the dictated prose in the file's comment prefix and applies a code-aware
rewrite pass:

- Single-line languages (`//`, `#`, `--`): single-line comment with prefix + capitalise first
  letter + terminal punctuation stripped to a single `.`.
- Block-comment languages (`/* */`): wrap the rewrite in `/* ... */`, with line-continuation `*`
  for multi-sentence rewrites.
- HTML/XML: `<!-- ... -->`.
- Markdown (in `.md`): no prefix; treat as prose.
- `.json`/`.toml`: refuse with "Bark doesn't generate JSON via dictation — paste values directly."

**Why this priority**: This is the core feature — without file-aware formatting, the rest is
wasted potential.

**Independent Test**: Open `foo.swift`, focus the cursor on an empty line, hold the hotkey, say
"this function handles the case where the input is nil", release. The line is replaced with
`// This function handles the case where the input is nil.`

**Acceptance Scenarios**:
1. **Given** focus is in a `.swift` file, **When** the user dictates in `Code` mode, **Then** the
   output is prefixed with `// `, capitalised at the start, and terminated with a single `.`.
2. **Given** focus is in a `.py` file, **When** the user dictates, **Then** the prefix is `# `.
3. **Given** focus is in a `.html` file, **When** the user dictates, **Then** the prefix is
   `<!-- -->` with the content inside.
4. **Given** focus is in a `.json` file, **When** the user dictates, **Then** Bark refuses with
   a clear message rather than emitting invalid JSON.
5. **Given** focus is in a `.md` file, **When** the user dictates, **Then** no prefix is added
   (prose; same as the existing Clean mode behaviour).

### US2 — Identifier preservation from the focused file (Priority: P1)
The rewrite pass for code comments is given a **symbol index** of the focused file: a list of
identifiers (function names, class names, variable names, enum cases, constants) extracted from
the file's text. The LLM is instructed (via `PromptTemplate.code`) to use these identifiers
verbatim when the dictated prose references them.

- Swift files: the symbol index is built via `SwiftSyntax` (system framework, on the OS).
- Other languages: a regex-based extractor (top-level `func`, `class`, `var`, `let`, `def`,
  `const`, `enum`, etc., depending on language).
- Index size capped (default: 500 identifiers) to keep the prompt bounded.

**Why this priority**: This is the wedge that makes Bark the dev's choice. Without it, the user
still loses identifiers to prose rewrite.

**Independent Test**: Open a Swift file containing `func viewDidLoad()`, focus a comment line,
dictate "called after the view loads", release. The comment becomes
`// Called after viewDidLoad() — runs once after the view loads.` (or similar — exact text is
LLM's call, but `viewDidLoad` appears verbatim).

**Acceptance Scenarios**:
1. **Given** a Swift file with `viewDidLoad` and `dataTask`, **When** the user dictates a
   comment that semantically references these functions, **Then** the identifiers appear in the
   output verbatim (case-sensitive).
2. **Given** a file with 1000+ identifiers, **When** the symbol index would exceed 500 entries,
   **Then** the index is truncated (deterministic — first 500 in source order) and the LLM
   is told the index is partial.
3. **Given** a file the user has not given Bark permission to read (e.g. an excluded path), **When**
   the user dictates, **Then** the rewrite proceeds without the symbol index (graceful
   degradation; the comment is still formatted with prefix + capitalisation but identifiers may
   be lost).
4. **Given** the focused file is binary, unreadable, or > 1 MB, **When** the user dictates, **Then**
   the symbol index is skipped and a one-time message is logged ("Skipping symbol index for
   <path>: <reason>"). Dictation still works.

### US3 — Conventional Commit message generation (Priority: P1)
When the focused context is a commit-message box (detected via AX: a multi-line text field in a
known app — Tower, Sourcetree, GitHub Desktop, GitKraken, VS Code's Source Control panel, the
terminal, or any app where the AX role + first-line content match a heuristic), Bark's `Commit`
mode generates a Conventional Commits message:

- Subject line: `<type>(<scope>): <summary>` where `<type>` is one of
  `feat | fix | docs | style | refactor | perf | test | build | ci | chore | revert` and
  `<scope>` is the primary symbol changed (best-guess from the staged diff if available,
  else from the focused file).
- Body: a wrapped paragraph(s) separated from the subject by a blank line, ≤ 72 chars per line.
- Optional footer: `BREAKING CHANGE: <note>` if the user dictated "this breaks" / "breaking
  change" / etc.

**Why this priority**: This is the other half of the dev wedge. Conventional Commits are
table-stakes for serious dev workflows.

**Independent Test**: In VS Code's Source Control panel, focus the commit-message box, hold the
hotkey, say "fix the memory leak in the cache by adding an LRU bound", release. The commit
message is:

```
fix(cache): add LRU bound to prevent memory leak

Add a size cap to the cache and evict least-recently-used entries
when the cap is exceeded.
```

**Acceptance Scenarios**:
1. **Given** the focused field is a commit-message box (heuristic-detected), **When** the user
   dictates, **Then** the output is a Conventional Commits-formatted message with a `<type>(<scope>)`
   subject and a wrapped body.
2. **Given** the user's dictation includes a "breaking change" cue, **When** the rewrite is
   applied, **Then** the footer `BREAKING CHANGE: <note>` is appended.
3. **Given** the focused field is a commit-message box but the user has switched to `Raw` mode,
   **When** the user dictates, **Then** no formatting is applied (Raw mode bypasses everything).
4. **Given** the heuristic can't confirm the focused field is a commit-message box, **When** the
   user dictates, **Then** the user sees a one-time toast "Not sure this is a commit-message box
   — formatting anyway? [Yes / No / Don't ask again]" and the choice is remembered per-app.

### US4 — Per-language settings (Priority: P2)
Settings ▸ Modes gains per-language toggles for the dev features:

- "Format Swift comments with `//` prefix" (default: on)
- "Format Python comments with `#` prefix" (default: on)
- "Preserve identifiers from focused file" (default: on)
- "Format commit messages as Conventional Commits" (default: on, when heuristic detects a
  commit-message box)

A master toggle "Enable inline code dictation" (default: on) gates the entire feature. When off,
Code mode behaves as it does today (raw STT output, no formatting).

**Why this priority**: Without UX, the feature is opt-out and some users will hate it. With
per-language toggles, the user can fine-tune.

**Independent Test**: Settings ▸ Modes shows the per-language toggles. Unchecking "Preserve
identifiers" causes US2 to be skipped; unchecking "Format Swift comments" causes Swift files to
use the default Clean-mode behaviour.

**Acceptance Scenarios**:
1. **Given** the master toggle is off, **When** the user dictates into a code file, **Then** the
   output is the same as today's Code mode (no formatting).
2. **Given** "Preserve identifiers" is unchecked, **When** the user dictates, **Then** no symbol
   index is built (the file is not read; the rewrite proceeds without symbol context).
3. **Given** per-language toggles are stored, **When** the user changes one, **Then** the change
   persists across relaunch.

### US5 — File-read safety: explicit user consent (Priority: P1)
Reading the focused file to build the symbol index is a privacy expansion over today's Bark:
Bark today reads the focused file's *title / AX role / field context* but not the file's
*content*. The new behaviour needs a per-app, per-language opt-in the first time the heuristic
would read a file in a given app+language combination.

- The first time Bark is about to read a file (e.g., `foo.swift` in VS Code), the user sees a
  one-time per-app-per-language consent: *"Bark wants to read the focused file to preserve
  identifiers. Allow for .swift files in Visual Studio Code? [Always allow / Allow once /
  Never]"*. The choice is remembered.
- "Never" sets a per-app-per-language blocklist; the symbol index is silently skipped.
- The default for the first encounter is "Allow once" — the prompt is shown, and the user can
  change the default in Settings.
- The consent list is per-app + per-language (not per-file), so changing files in the same app
  doesn't re-prompt.

**Why this priority**: Reading file content is a meaningful expansion of Bark's read surface.
Without explicit consent the feature would violate the constitution's "least privilege" rule.

**Independent Test**: First-time dictation in a Swift file in VS Code, the consent dialog
appears. Choose "Always allow for Swift in VS Code". Subsequent dictations in any Swift file
in VS Code don't prompt.

**Acceptance Scenarios**:
1. **Given** a first-time encounter (app + language), **When** Bark is about to read the file,
   **Then** the consent dialog is shown with the three options.
2. **Given** the user chose "Always allow", **When** the user dictates in the same app + same
   language, **Then** the consent dialog is not shown.
3. **Given** the user chose "Never", **When** the user dictates in the same app + same language,
   **Then** the symbol index is silently skipped and no consent dialog is shown again.
4. **Given** a change in app or language, **When** the new combination is encountered, **Then**
   a new consent prompt is shown (the consent list is per-app-per-language).
5. **Given** the user has set a preference, **When** they want to change it, **Then** Settings
   ▸ Privacy exposes a "File-read consent" section listing all app+language entries with
   "Allow / Never / Reset to default" controls.

### US6 — Lean-build fallback (Priority: P2)
The feature is opt-in: when the LLM is not compiled in (lean build, no `MLXCleanup`), the
identifier-extraction rewrite is unavailable. The feature degrades gracefully:

- US1 (language-aware comment prefix) is implemented in **BarkCore**, not the LLM. The lean
  build applies the prefix + capitalisation rule without an LLM call — same as the existing
  `BasicTextCleaner` does for prose.
- US2 (identifier preservation) requires the LLM. Lean build: skipped; comment is formatted
  with prefix only, no symbol protection.
- US3 (Conventional Commits formatting) requires the LLM. Lean build: skip; the dictated text
  is inserted as-is.

The user is informed in Settings ▸ Modes: *"Full identifier preservation and Conventional
Commits formatting require the MLX build. The lean build formats comments with the language
prefix only."*

**Why this priority**: This keeps the feature on-by-default in the lean build (US1 is genuinely
useful — `//` prefixing alone is a big UX win) without requiring the MLX build.

**Independent Test**: Lean build (`swift build` with `Package.swift`, not `Package-mlx.swift`),
dictate into a Swift file. The output gets the `// ` prefix and capitalisation, but identifiers
are not preserved (no symbol index, no LLM call). Dictate into a commit-message box: the text
is inserted as-is, no Conventional Commits formatting.

**Acceptance Scenarios**:
1. **Given** the lean build, **When** the user dictates into a code file, **Then** the comment
   prefix is applied (no LLM call).
2. **Given** the lean build, **When** the user dictates into a commit-message box, **Then** the
   text is inserted without Conventional Commits formatting.
3. **Given** the lean build, **When** the user opens Settings ▸ Modes, **Then** the disabled
   features are clearly marked and a one-line explainer points to the MLX build.

## Success Criteria *(mandatory)*

- `swift build` clean (lean + MLX); `swift test` green; new tests cover the language-prefix
  table, the SwiftSyntax symbol extractor, the identifier-preservation rewrite, the Conventional
  Commits formatter, the consent dialog, and the per-app-per-language consent list.
- US1 (comment prefix) works in **every** build.
- US2 + US3 work in **the MLX build**; the lean build degrades gracefully per US6.
- The file-read consent flow is documented in `docs/SECURITY.md` and `docs/CONSTITUTION.md`-aligned.
- Live end-to-end testing is on-device-only per the existing `L-5` residual; the seam tests use
  the same fakes pattern as the rest of Bark.
- No new network events. The file read is local. The symbol index is local. The LLM call uses
  the existing on-device `MLXTextCleaner` path.

## Out of Scope

- **Multi-file diff context for commit messages.** The commit-message heuristic operates on the
  user's dictation only. Reading the staged diff to inform scope / body would require running
  `git diff --staged` and is a separate (substantial) feature.
- **Refactor suggestions.** "make this function faster" → code rewrite. This is a code-generation
  task, not a comment task. Separate spec.
- **Inline code generation from comments (the reverse direction).** "Write a function that does
  X" → code block. Separate spec; arguably more dangerous (it injects runnable code).
- **Project-wide symbol lookup.** The index is per-file, not per-project. Cross-file references
  are best-effort.
- **Languages not in the comment-prefix table.** New languages are easy to add (one entry in
  the table) but v1 ships with the table in US1; the user can request additions.

## Risks

- **SwiftSyntax footprint.** `libSwiftSyntax` is a non-trivial system framework. The lean build
  is unchanged (SwiftSyntax lives behind `#if MLXCleanup` or a new `#if CODE_INTELLIGENCE`
  flag, similar to the existing pattern). Lean build uses regex extraction only.
- **Reading a file the user didn't intend to share.** Mitigated by the per-app-per-language
  consent dialog (US5). Default is "Allow once" so the user is in control.
- **LLM hallucinating identifiers.** The LLM is told which identifiers exist; the prompt
  instructs it to use them verbatim. But LLMs can still misremember. The `OutputValidator`
  gains a rule: if the rewrite contains an identifier that does not exist in the file (and
  is not a standard library symbol), flag it. (This is best-effort: a reference to an
  identifier *not* in the file isn't necessarily wrong — it could be an imported type.)
- **Regex extraction false positives.** For non-Swift languages, regex can grab comments and
  strings. The extractor strips comments and string literals before the regex runs (per
  language).
- **File size.** A 1 MB file would take seconds to tokenize. The cap is 1 MB; larger files
  skip the index and degrade to prefix-only.
- **Bark running in a different process from the focused app.** Bark is non-sandboxed and uses
  AX, so it can read the file via the focused app's path. The consent dialog names the app by
  name + bundle ID; the file is read via the focused app's NSWorkspace association.