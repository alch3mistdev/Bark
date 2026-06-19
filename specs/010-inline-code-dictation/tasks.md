# Tasks: Inline code comment + commit-message dictation

**Input**: ./spec.md, ./plan.md, ../../docs/constitution.md
**Tests**: included (Principle II + US1/US2/US5 require them).

## Phase 1 — Setup
- [ ] T001 Spec Kit artifacts (spec, plan, tasks, quickstart) — this phase.

## Phase 2 — Foundational: language table + identifier protocol (BarkCore, no deps)

- [ ] T010 [BarkCore] `LanguageCommentSpec` + `IdentifierExtractorKind` value types
      (`Sources/BarkCore/Code/LanguageCommentPrefix.swift`).
- [ ] T011 [BarkCore] Static table for v1 languages: swift, python, typescript, tsx, javascript,
      jsx, go, rust, java, kotlin, ruby, c, cc, cpp, h, hpp, m, mm, sh, bash, zsh, sql, html,
      css, scss, yaml, yml, toml, json, md. Each entry: single-line / block / refuse / prose.
- [ ] T012 [BarkCore] `CommentKind` enum (refuse / prose / singleLine / block) + `LanguageCommentTable`
      lookup helpers (`spec(forExtension:)`, `kind(forExtension:)`).
- [ ] T013 [BarkCore] `LanguageIdentifier` protocol — extract identifiers from source, capped.
- [ ] T014 [BarkCore] `RegexLanguageIdentifier` — language-specific patterns. Strips comments and
      string literals first; runs regex for function / class / var / const / enum names. Returns
      up to `maxCount` distinct identifiers in source order.
- [ ] T015 [BarkCore] `BarkCoreTests` — language table lookup happy paths (each v1 language),
      missing-extension fallback, refuse for json/toml, prose for md, block open/close
      balanced, regex extractor happy paths + comment/string stripping + cap behaviour.

## Phase 3 — Foundational: settings + consent

- [ ] T020 [BarkCore] `FileReadConsent` + `FileReadConsentDecision` types
      (`.allow | .allowOnce | .never`) — Codable, Sendable, Equatable.
- [ ] T021 [BarkCore] `CodeIntelligenceSettings` struct — master toggle, per-language toggles
      (Swift / Python / JS / TS / Go / Rust / Java / Kotlin / Ruby / C-family / Shell / SQL /
      HTML / CSS / YAML / Markdown), preserve-identifiers, conventional-commits,
      fileReadConsents dictionary. Codable + tolerant decode.
- [ ] T022 [BarkCore] `Settings` extended with `codeIntelligence: CodeIntelligenceSettings`,
      default `enabled: true, preserveIdentifiers: true, conventionalCommits: true, all language
      toggles on, fileReadConsents: [:]`.
- [ ] T023 [BarkCore] `Settings` round-trip tests — encode → decode → equal; tolerant decode
      with missing field fills default.

## Phase 4 — US1: comment prefix application (no LLM)

- [ ] T030 [Bark] `CommentPrefixApplier` (in `BarkCore/Code/`) — pure function:
      `(text: String, commentKind: CommentKind) -> String`. Applies prefix, capitalises first
      letter, terminates with single `.`, strips trailing whitespace.
- [ ] T031 [Bark] Wire into the existing `BasicTextCleaner` or a new `CodeCommentCleaner` that
      runs *before* the LLM. The Code mode's basic-cleaner pass applies the prefix without an
      LLM call.
- [ ] T032 [BarkAppTests] Tests for US1 happy paths per language (Swift, Python, HTML, MD, JSON
      refuse).

## Phase 5 — US5: file-read consent (UI + settings)

- [ ] T040 [Bark/UI] `FileReadConsentView` — SwiftUI sheet with the three buttons + one-line
      explainer. Shows the app by name + bundle ID; the language by extension + display name.
- [ ] T041 [Bark] `FileReadConsentCoordinator` actor — wraps the consent lookup / decision /
      prompt flow. Composed in `CompositionRoot`. Exposes `requestConsent(for: app, language:)
      async -> FileReadConsentDecision` (with a 60 s timeout; on timeout, default to
      `.allowOnce` and proceed).
- [ ] T042 [Bark/UI] `CodePane` in `SettingsView` — master toggle, per-language toggles, link
      to the file-read consent sheet.
- [ ] T043 [Bark/UI] `FileReadConsentSettingsView` — lists all `app/language` entries from
      `Settings.codeIntelligence.fileReadConsents` with Allow / Never / Reset controls.
- [ ] T044 [BarkAppTests] Tests for consent lookup: prior consent returns immediately; first
      encounter returns `.pending`; "Never" entries are blocklisted.

## Phase 6 — US2: identifier preservation (MLX build)

- [ ] T050 [BarkCleanupMLX] `SwiftSyntaxLanguageIdentifier` — uses `SwiftParser` to walk the
      AST, collect `IdentifierExprSyntax`, `FunctionDeclSyntax`, `ClassDeclSyntax`,
      `EnumCaseDeclSyntax`, `VariableDeclSyntax` bindings, etc. Cap at `maxCount` (default 500).
      Gated by `#if CODE_INTELLIGENCE`.
- [ ] T051 [BarkCore] `PromptTemplate.codeCommentSystem(for: mode, language: String, symbols:
      [String])` — system prompt that fences the symbols as `<symbols>` and the dictated text
      as `<transcript>`, instructs preservation of identifiers verbatim, applies the language's
      comment prefix, capitalises the first letter, terminates with a single `.`. The system
      prompt is built once per utterance (cheap).
- [ ] T052 [Bark] `CodeIntelligenceCoordinator` — orchestrates: ask for consent → if granted,
      read the focused file's content (capped at 1 MB; rejected if larger) → extract
      identifiers (SwiftSyntax on Swift, regex on other languages) → call into the LLM cleaner
      with the system prompt containing the symbol list → run `OutputValidator` (new rule:
      flag identifiers in the rewrite that don't appear in the symbol index and aren't standard
      library symbols).
- [ ] T053 [Bark] Wire into `DictationController.produceText` — when mode is `Code` and the
      focused context is a code file (heuristic: AX role + file extension), invoke the
      coordinator after the basic cleaner and before the LLM cleaner. On coordinator failure
      (no consent, file unreadable, identifier extraction fails, validator rejects), fall back
      to the existing Code-mode behaviour.
- [ ] T054 [BarkAppTests] Tests for US2 happy paths with fakes; consent denial; lean-build
      fallback; identifier-preservation integration with the existing `MLXTextCleaner` mock.

## Phase 7 — US3: Conventional Commits formatting

- [ ] T060 [BarkCore] `CommitBoxDetector` — multi-signal heuristic: known app list (Tower,
      Sourcetree, GitHub Desktop, GitKraken, VS Code, terminal apps), AX role, first-line
      length, surrounding AX labels. Returns `CommitBoxDetection { isCommitBox, confidence,
      app, reason }`.
- [ ] T061 [BarkCore] `ConventionalCommitFormatter` — pure, no model. Takes dictated text +
      extension + (MLX) a type from the LLM. Splits subject from body, applies `<type>(<scope>)`
      prefix, wraps body at 72 chars, appends `BREAKING CHANGE: <note>` if a breaking cue is
      detected ("this breaks", "breaking change", etc.).
- [ ] T062 [BarkCore] `PromptTemplate.commitMessageSystem(for: mode, type: String, scope: String,
      breaking: Bool)` — system prompt for Conventional Commits; gives the LLM the formatter's
      output structure to fill in.
- [ ] T063 [Bark] Wire into the controller: when the focused field is a commit-message box
      (heuristic) and the mode is `Commit` (or the user explicitly opted in for this app),
      format as Conventional Commits. Lean build: skip the formatting, insert as-is.
- [ ] T064 [BarkAppTests] Tests for US3 happy paths: detected commit box + Conventional Commits
      formatting; non-commit-box context (no formatting); breaking-change cue → footer;
      72-char wrap; lean-build fallback (no-op).

## Phase 8 — US4: per-language settings

- [ ] T070 [Bark/UI] `CodePane` (continued from T042) — per-language toggles bound to
      `controller.codeIntelligence.{language}CommentPrefixEnabled`.
- [ ] T071 [Bark/UI] Per-language rows dynamically generated from the language table.
- [ ] T072 [BarkAppTests] Settings round-trip per language toggle (covered by Phase 2 T023).

## Phase 9 — US6: lean-build fallback

- [ ] T080 [BarkCore] `CodeIntelligenceCoordinator` is no-op when `CODE_INTELLIGENCE` is not
      defined. The controller's call site handles the no-op gracefully (prefix-only via
      `CommentPrefixApplier`).
- [ ] T081 [Bark/UI] Code pane shows disabled features clearly when the lean build is in use
      (detected via a runtime check on the LLM's presence).
- [ ] T082 [BarkAppTests] Lean-build tests: identifier preservation is skipped, Conventional
      Commits is skipped, prefix is applied.

## Phase 10 — STRIDE + ADR

- [ ] T090 [docs/SECURITY.md] Add a "File read for code intelligence" section: per-app-per-
      language consent, 1 MB cap, opt-out defaults, residuals. Honest residual: SwiftSyntax
      reads the file's content; the LLM is given a symbol index; the consent dialog can be
      bypassed by a user who clicks "Always allow" and we never re-prompt.
- [ ] T091 [docs/ADRs.md] Append ADR-008 for the code intelligence surface.

## Phase 11 — Verification

- [ ] T100 [Bark] `swift build` clean (lean + MLX).
- [ ] T101 [Bark] `swift test` — 102 → ~127 tests, all green.
- [ ] T102 [Bark] Manual smoke (documented in quickstart.md): dictate into Swift / Python /
      HTML files in Xcode, VS Code, TextEdit, and verify the prefix is correct. Open a
      commit-message box in Tower / VS Code and verify the format. Lean-build smoke: prefix
      works, identifier preservation skipped, Conventional Commits skipped.