# Implementation Plan: Inline code comment + commit-message dictation

**Branch**: `010-inline-code-dictation` | **Date**: 2026-06-19 | **Spec**: ./spec.md

## Summary

Add developer-specific dictation behaviour: file-aware comment prefixing, identifier preservation
from the focused file's symbol index, Conventional Commits message formatting for commit-message
boxes, and a per-app-per-language file-read consent flow. The comment-prefix table lives in
`BarkCore` and works in every build; the LLM-backed identifier preservation and Conventional
Commits formatting work in the MLX build, with the lean build degrading gracefully to
prefix-only / no-op.

## Technical Context

**Language/Version**: Swift 6.0 (toolchain 6.3.2), SwiftUI / AppKit
**Primary Dependencies**:
- **Lean build**: none added. Regex-based language detection and comment-prefix table in `BarkCore`.
- **MLX build** (only): `SwiftSyntax` for the Swift symbol extractor. The framework is on the
  system (no `Package.swift` change required) — the new flag `#if CODE_INTELLIGENCE` enables
  the SwiftSyntax-backed path; `#else` falls back to regex.

**Storage**:
- `Settings.codeIntelligence: CodeIntelligenceSettings` — master toggle + per-language toggles +
  per-app-per-language consent list.
- `CodeIntelligenceSettings.fileReadConsents: [String: FileReadConsent]` — keyed by
  `"\(bundleID)/\(language)"` (e.g. `"com.microsoft.VSCode/swift"`).
- The consent list is small (< 50 entries typical); UserDefaults JSON-encoded like other settings.

**Testing**: XCTest. New `BarkCodeIntelligenceTests` target (or new test files in `BarkCoreTests`):
language prefix table, regex-based symbol extractor, SwiftSyntax-backed symbol extractor
(MLX build only), Conventional Commits formatter, consent dialog UI state, lean-build fallback.

**Target Platform**: macOS 26+, Apple Silicon

**Project Type**: native desktop menu-bar app

**Performance Goals**:
- Comment prefix application: < 5 ms (pure table lookup).
- Symbol extraction (Swift, MLX build): < 50 ms for a 100 KB file.
- Symbol extraction (regex, other languages): < 20 ms for a 100 KB file.
- LLM rewrite with symbol context: bounded by existing `cleanupDeadline` (8 s).

**Constraints**:
- Offline-only at runtime. No new network events.
- The file read is a privacy expansion — explicit per-app-per-language consent (US5).
- Lean build unchanged in dependencies.

## Constitution Check

- **I (Offline):** no new network events. The file read is local. The LLM call uses the
  existing on-device `MLXTextCleaner`. PASS.
- **II (Evidence):** every task ends with a build + test command and its output. PASS.
- **III (Protocols):** new `LanguageIdentifier` protocol (extracts symbol list from file
  content); two impls — `RegexLanguageIdentifier` (BarkCore, all languages, regex-based) and
  `SwiftSyntaxLanguageIdentifier` (BarkCleanupMLX, Swift only, AST-based). The pipeline
  depends only on the protocol. PASS.
- **IV (Least privilege):** the file read is gated by the per-app-per-language consent
  dialog (US5). The user explicitly opts in. Lean build: no read. MLX build: read only after
  consent. PASS.
- **V (Speed / non-blocking):** the prefix application is synchronous and fast. The symbol
  extraction is bounded (1 MB cap, 50 ms timeout). The LLM rewrite is bounded by the existing
  `cleanupDeadline`. On miss, the deterministic fallback (prefix-only) is used. PASS.

## Approach

### 1. Language-prefix table (`BarkCore/Code/LanguageCommentPrefix.swift`)

Pure data. A static table mapping file extension → `(singleLine: String?, blockOpen: String?,
blockClose: String?, displayName: String, identifierExtractor: IdentifierExtractorKind)`.

```swift
public struct LanguageCommentSpec: Sendable, Equatable {
    public let singleLinePrefix: String?       // e.g. "//" for Swift
    public let blockOpen: String?              // e.g. "/*" for Swift
    public let blockClose: String?             // e.g. "*/" for Swift
    public let displayName: String             // "Swift", shown in Settings
    public let identifierExtractor: IdentifierExtractorKind  // .swiftSyntax | .regex(...)
}

public enum IdentifierExtractorKind: Sendable, Equatable {
    case swiftSyntax   // MLX build only
    case regex(RegexLanguagePattern)
}

public enum CommentKind: Sendable, Equatable {
    case refuse(reason: String)               // e.g. .json / .toml
    case prose                              // e.g. .md (no prefix)
    case singleLine(prefix: String)
    case block(open: String, close: String)
}

public enum LanguageCommentTable {
    public static func spec(forExtension ext: String) -> LanguageCommentSpec?
    public static func kind(forExtension ext: String) -> CommentKind
}
```

### 2. Identifier extraction protocols (`BarkCore/Code/LanguageIdentifier.swift`)

```swift
public protocol LanguageIdentifier: Sendable {
    /// Extract a list of identifiers from `source` (capped at `maxCount`).
    /// Used to build the symbol index passed to the LLM as context.
    func extractIdentifiers(from source: String, maxCount: Int) throws -> [String]
}
```

- `RegexLanguageIdentifier` (BarkCore) — uses language-specific regexes to extract function
  names, class names, variable names, etc. Strips comments and string literals first.
- `SwiftSyntaxLanguageIdentifier` (BarkCleanupMLX, gated by `#if CODE_INTELLIGENCE`) — uses
  SwiftSyntax's `SwiftParser` to walk the AST and collect `IdentifierExprSyntax`,
  `FunctionDeclSyntax`, `ClassDeclSyntax`, etc. Higher precision, AST-accurate.

Both impls are constructor-injected; the production code in `DictationController` selects based
on the focused file's language.

### 3. File-read consent (`BarkCore/Code/FileReadConsent.swift`, `Settings`)

```swift
public enum FileReadConsentDecision: String, Codable, Sendable {
    case allow            // "Always allow for this app+language"
    case allowOnce        // "Allow once" — transient, not persisted
    case never            // "Never" — blocklist
}

public struct FileReadConsent: Codable, Sendable, Equatable {
    public let bundleID: String
    public let language: String         // e.g. "swift", "python"
    public let decision: FileReadConsentDecision
    public let decidedAt: Date
}

public struct CodeIntelligenceSettings: Codable, Sendable, Equatable {
    public var enabled: Bool                          // master toggle
    public var preserveIdentifiers: Bool              // US2
    public var conventionalCommits: Bool               // US3
    public var swiftCommentPrefixEnabled: Bool
    public var pythonCommentPrefixEnabled: Bool
    // ... one per language in the table
    public var fileReadConsents: [String: FileReadConsent]  // key = "bundleID/language"
}
```

The consent dialog is a small SwiftUI sheet shown from `DictationController` when the heuristic
wants to read a file and no prior consent exists. The dialog's choice is stored in
`CodeIntelligenceSettings.fileReadConsents`.

### 4. Heuristic for "is this a commit-message box?" (`BarkCore/Code/CommitBoxDetector.swift`)

Multi-signal:
- AX role is `AXTextField` or `AXTextArea` and the field's app is in a known list (Tower,
  Sourcetree, GitHub Desktop, GitKraken, VS Code, terminal apps).
- The field's first line is empty or short (≤ 72 chars), suggesting a new commit subject.
- The field's surrounding AX hierarchy contains a "Source Control" or "Commit" label
  (best-effort, English-only).

The heuristic returns a `CommitBoxDetection { isCommitBox: Bool, confidence: Double, app:
String, reason: String }`. The controller uses the confidence to decide whether to format as
Conventional Commits.

### 5. Conventional Commits formatter (`BarkCore/Code/ConventionalCommitFormatter.swift`)

Pure, no model. Takes a dictated text + the focused file's extension and produces a formatted
commit message. The formatter:

- Detects a `<type>` from the dictation (the LLM in the MLX build is given the type list as
  context; the lean build skips this and produces a plain text insert).
- Detects a "breaking change" cue and appends the footer.
- Wraps the body at 72 chars.
- Splits subject from body with a blank line.

For the MLX build, the formatter's output becomes the system prompt's "shape" — the LLM is
asked to produce text that fits the formatter's output structure. For the lean build, the
formatter is a no-op and the dictated text is inserted as-is.

### 6. LLM prompt templates (`BarkCore/Cleanup/PromptTemplate.swift`)

Add two new templates:
- `codeCommentSystem(for: mode, language: String, symbols: [String])` — system prompt that
  fences the symbols as `<symbols>` and the dictated text as `<transcript>`, instructs
  preservation of identifiers verbatim, applies the language's comment prefix, capitalises
  the first letter, and terminates with a single `.`.
- `commitMessageSystem(for: mode, type: String, scope: String, breaking: Bool)` — system
  prompt for Conventional Commits, with `<transcript>` as the dictated intent and the type /
  scope / breaking-change flags as the formatter's output structure.

### 7. Settings UI (`Sources/Bark/UI/SettingsView.swift`)

- New pane: "Code" (between "Modes" and "Apps").
- Master toggle at the top.
- Per-language toggles (Swift, Python, JS/TS, etc. — one row per language in the table).
- "Preserve identifiers" toggle (subordinate to master).
- "Format commit messages as Conventional Commits" toggle.
- "File-read consent" link → a sheet listing all `app/language` entries with
  "Allow / Never / Reset" controls.

### 8. `DictationController` integration

- A new `CodeIntelligenceCoordinator` actor orchestrates the file-read + identifier-extraction
  + LLM-rewrite path. Composed in `CompositionRoot` only when `MLXCleanup` is defined (or via
  a new `CODE_INTELLIGENCE` flag for non-MLX opt-in).
- The controller's existing `produceText` pipeline is extended: when the mode is `Code` (or a
  custom mode flagged `usesCodeIntelligence`) and the focused context is a code file, the
  coordinator is invoked after the basic cleaner and before the LLM cleaner.
- The consent dialog is presented via the existing `onOpenSettings`-like callback pattern;
  the controller awaits the user's choice (with a 60 s timeout — on timeout, default to
  "Allow once" and proceed).

### 9. STRIDE update

Add a new section to `docs/SECURITY.md`: "File read for code intelligence (US5/US2)". Honest
residuals: the SwiftSyntax extractor sees the file's content (same risk surface as the existing
`AssetInventory` for STT models); the regex extractor on non-Swift files is best-effort and
can include false positives in some edge cases; the consent dialog is opt-out-able by app
default ("Allow once" is the first-time default), but a determined user can grant
"Always allow" and we never re-prompt.

## Files

```
Sources/BarkCore/Code/LanguageCommentPrefix.swift          (new — static table)
Sources/BarkCore/Code/LanguageCommentTable.swift           (new — lookup helpers)
Sources/BarkCore/Code/CommentKind.swift                    (new — enum)
Sources/BarkCore/Code/LanguageIdentifier.swift             (new — protocol)
Sources/BarkCore/Code/RegexLanguageIdentifier.swift        (new — regex impl, in BarkCore)
Sources/BarkCore/Code/CommitBoxDetector.swift              (new — heuristic)
Sources/BarkCore/Code/ConventionalCommitFormatter.swift    (new — pure, no model)
Sources/BarkCore/Code/FileReadConsent.swift                (new — settings type)
Sources/BarkCore/Code/CodeIntelligenceSettings.swift       (new — settings struct)
Sources/BarkCore/Code/CodeIntelligenceCoordinator.swift    (new — actor; orchestrates)
Sources/BarkCore/Cleanup/PromptTemplate.swift              (extend — codeCommentSystem, commitMessageSystem)
Sources/BarkCleanupMLX/SwiftSyntaxLanguageIdentifier.swift (new — gated by CODE_INTELLIGENCE)
Sources/Bark/SettingsStore.swift                           (extend — codeIntelligence field)
Sources/Bark/DictationController.swift                     (extend — invoke coordinator, present consent sheet)
Sources/Bark/CompositionRoot.swift                         (extend — compose coordinator)
Sources/Bark/UI/SettingsView.swift                         (extend — Code pane + file-read consent sheet)
docs/SECURITY.md                                            (extend — file-read surface)
docs/ADRs.md                                                (extend — ADR-008)
```

## Risks

- **SwiftSyntax API surface shift.** SwiftSyntax's API is reasonably stable but has had
  breaking changes between macOS releases. The extractor is small and focused; if the API
  shifts, only the extractor needs updating. Documented in the file.
- **Per-app-per-language consent UX.** The dialog is small (one line + three buttons), but the
  per-app language detection is heuristic. If the heuristic gives a wrong app+language, the
  user may accidentally grant consent for a different combination. Mitigated by showing the
  app by name + bundle ID, and the language by extension + display name.
- **The "Allow once" default.** The first time the user encounters an app+language, the
  default is "Allow once" — the dialog is shown. If the user closes the dialog (Esc / X), the
  default kicks in and the file IS read once. This is the *least* surprising default but it
  means a user who doesn't engage with the dialog will still have their file read once. The
  path forward: make the default "Never" with a one-line explainer, and require explicit
  choice. v1 ships with "Allow once" as the default; can be flipped to "Never" if the
  adversarial review flags it. Documented.
- **Identifier hallucination.** The LLM may invent identifiers. Mitigated by the symbol
  index as context + an `OutputValidator` rule that flags non-existent identifiers (best-effort;
  false positives on imported types).

## Verification

- `swift build` clean (lean + MLX). `swift test` — ~25 new tests covering:
  - `LanguageCommentTable.spec(forExtension:)` for all v1 languages
  - `RegexLanguageIdentifier` happy paths + comment/string stripping
  - `SwiftSyntaxLanguageIdentifier` happy paths (MLX build)
  - `CommitBoxDetector` heuristic + known-app list
  - `ConventionalCommitFormatter` types, scope, breaking-change footer, 72-char wrap
  - `FileReadConsent` codable round-trip
  - `CodeIntelligenceSettings` round-trip
  - `DictationController` end-to-end with the new coordinator (fakes; consent dialog mocked)
  - Lean-build fallback: no identifier preservation, no Conventional Commits formatting
- Manual: dictate into Swift / Python / HTML files in Xcode, VS Code, TextEdit, and verify
  the prefix is correct. Open a commit-message box in Tower / VS Code and verify the format.
- `docs/SECURITY.md` ☐ → ☑ for the new file-read surface.
- ADR-008 added.