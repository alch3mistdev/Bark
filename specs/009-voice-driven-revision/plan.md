# Implementation Plan: Voice-driven revision of the last injection

**Branch**: `009-voice-driven-revision` | **Date**: 2026-06-19 | **Spec**: ./spec.md

## Summary

Add a revision surface to Bark: a second hotkey, a deterministic command dictionary that works
without the LLM, and an LLM-backed rewrite path that operates on the just-injected text in the
focused field. Every revision produces a `HistoryRecord` linked to its parent so users can revert.
The feature inherits and re-runs all existing security controls (US5).

## Technical Context

**Language/Version**: Swift 6.0 (toolchain 6.3.2), SwiftUI / AppKit
**Primary Dependencies**: none added to the default lean build. MLX (`Qwen3-4B`) is the existing
opt-in path; this spec uses the same `TextCleaner` plumbing.
**Storage**: existing `EncryptedHistoryStore` gains a `parentID: UUID?` field on `HistoryRecord`;
new `RevisionCommand` table in `BarkCore` (deterministic dictionary).
**Testing**: XCTest. New tests in `BarkAppTests` covering the revision pipeline, the dictionary,
the history linkage, and the secure-field re-check.
**Target Platform**: macOS 26+, Apple Silicon
**Project Type**: native desktop menu-bar app
**Performance Goals**: revision latency bounded by the existing `cleanupDeadline` (default 8 s);
the recording HUD responds as fast as the existing push-to-talk pipeline (sub-100 ms).
**Constraints**: offline-only at runtime; lean build must support the deterministic command path
without the LLM.

## Constitution Check

- **I (Offline):** No new network events. The deterministic command dictionary needs no model;
  the LLM-backed path uses the existing on-device `MLXTextCleaner`. PASS.
- **II (Evidence):** Every task ends with a build + test command and its output. PASS.
- **III (Protocols):** The revision pipeline sits behind a new `RevisionEngine` protocol with
  two implementations (`DeterministicRevisionEngine`, `LLMRevisionEngine`). The controller depends
  only on the protocol. Pure logic (dictionary lookup, history linkage rules) lives in `BarkCore`
  with zero external deps. PASS.
- **IV (Least privilege / injection safety):** Revisions re-run `SecureFieldPolicy`, `FocusGuard`,
  `TextSanitizer`. The revision prompt is system; the spoken instruction is user-data, fenced in
  `<revision>`. `OutputValidator` checks for length drift, control chars, banned tokens. PASS.
- **V (Speed / non-blocking):** Revision is bounded by the existing per-utterance deadline; on
  miss, the original text is preserved (no destruction). PASS.

## Approach

### 1. New `RevisionEngine` protocol (`BarkCore/Revision/RevisionEngine.swift`)

```swift
public protocol RevisionEngine: Sendable {
    /// Interpret the spoken instruction against the previous text and return
    /// the revised text. Throws `RevisionError` on unrecoverable failures
    /// (timeout, validation, focus drift). Deterministic engines (the
    /// dictionary) return the same result for the same instruction + previous.
    func revise(previous: String, instruction: String, mode: Mode) async throws -> RevisionOutcome
}

public enum RevisionError: Error, Sendable, Equatable {
    case dictionaryMiss(instruction: String)
    case llmUnavailable
    case timedOut
    case validationFailed(reason: String)
    case focusChanged
    case secureFieldBlocked
}
```

### 2. `DeterministicRevisionEngine` (`BarkCore/Revision/DeterministicRevisionEngine.swift`)

Pure, no model. A hard-coded dictionary (currently `delete that`, `undo`, `select all`, `copy`,
`scratch that`) maps to AX actions or special return values (e.g. `.deleteSelection`,
`.systemUndo`, `.selectAll`, `.copy`, `.deleteSelection`). The engine returns a `RevisionOutcome`
discriminating between "text rewrite" and "AX action" — the controller applies one or the other.

```swift
public enum RevisionOutcome: Sendable, Equatable {
    case text(String)             // rewrite the previous text with this new text
    case action(RevisionAction)   // perform an AX action on the focused field
    case miss(String)             // not a known command; ask the LLM
}

public enum RevisionAction: Sendable, Equatable {
    case deleteSelection
    case systemUndo
    case selectAll
    case copy
}
```

### 3. `LLMRevisionEngine` (`BarkCleanupMLX/LLMRevisionEngine.swift`)

Thin wrapper over the existing `MLXTextCleaner` with a revision-specific prompt template. Uses the
same `PromptTemplate.system(for: mode)` infrastructure, extended with a `.revision` companion:

```swift
extension PromptTemplate {
    /// System prompt for the revision call. The previous text is fenced as
    /// untrusted data inside <previous>; the user's spoken instruction is
    /// fenced inside <revision>. This mirrors SEC-010's prompt-injection fence.
    static func revisionSystem(for mode: Mode) -> String
}
```

Built only when `MLXCleanup` is defined; mirrors the existing `MLXTextCleaner` stub pattern.

### 4. `DictationController.reviseLastInjection()` (`Sources/Bark/DictationController.swift`)

The new entry point. Wires the revision hotkey → `VoiceActivityDetector`-gated capture → instruction
text → revision engine → outcome application:

1. Reject if `phase.isActive` (don't overlap a dictation).
2. Reject if `secureFieldBlocked` / focus drift (existing `SecureFieldPolicy`).
3. Capture the spoken instruction (same `AudioCaptureEngine` → STT → transcript path; can reuse
   the existing pipeline since the hotkey is a separate `HotkeyManager` instance, just like
   hands-free).
4. Resolve the last `HistoryRecord` (in-memory, not disk-read on the hot path) and its
   `output`.
5. Call `revisionEngine.revise(previous:output, instruction:, mode:)` — either the
   `DeterministicRevisionEngine` first (fast path) or the `LLMRevisionEngine` for free-form.
6. Apply the `RevisionOutcome`:
   - `.text(revised)` → overwrite the focused field's range (use AX range manipulation OR — more
     safely — read the entire field, replace, and reinject via the existing `PasteboardInjector`).
   - `.action(undo)` → ⌘Z
   - `.action(copy)` → ⌘C
   - `.action(deleteSelection)` → select-all + delete
   - `.action(selectAll)` → ⌘A
7. Append a new `HistoryRecord` with `parentID = lastRecord.id`.

### 5. History linkage (`BarkCore/History/HistoryRecord.swift`, `HistoryStore` protocol)

Add an optional `parentID: UUID?` field to `HistoryRecord` (tolerant decode fills nil for old
records). The encrypted store migrates by re-reading the file with the new schema. The History pane
shows a "child of previous" badge when `parentID != nil`.

### 6. Per-mode revision prompts (`BarkCore/Cleanup/Mode.swift`)

`Mode` gains an optional `revisionPrompt: String?` field. The default per-mode revision prompts
ship in code:

```swift
extension Mode {
    public var defaultRevisionPrompt: String { ... }
}
```

For built-in modes: Raw → Clean prompt, Clean → Clean prompt, Email → Email register prompt,
Code → identifier-preserving prompt, etc. Custom modes use their own `revisionPrompt` if set,
else fall back to Clean's.

### 7. Settings UI (`Sources/Bark/UI/SettingsView.swift`)

- General (or Hotkey?) pane gains "Revision hotkey" recorder row (separate from push-to-talk).
- General pane gains "Enable voice-driven revision" toggle (default on).
- History pane renders the parent badge.

### 8. Constitution §IV: STRIDE addition

Add a new control to `docs/SECURITY.md`: revision surface re-runs secure-field refusal, focus-guard,
and `TextSanitizer`. Document the residual risks (AX automation brittleness in Electron apps,
prompt injection in the spoken instruction) honestly.

## Files

```
Sources/BarkCore/Revision/RevisionEngine.swift              (new — protocol + errors)
Sources/BarkCore/Revision/DeterministicRevisionEngine.swift (new — pure, in BarkCore)
Sources/BarkCore/Revision/RevisionAction.swift              (new — AX action enum)
Sources/BarkCore/Cleanup/Mode.swift                         (extend — revisionPrompt + defaultRevisionPrompt)
Sources/BarkCore/Cleanup/PromptTemplate.swift               (extend — revisionSystem(for:))
Sources/BarkCore/History/HistoryRecord.swift                (extend — parentID: UUID?)
Sources/BarkCleanupMLX/LLMRevisionEngine.swift               (new — gated by MLXCleanup, mirrors MLXTextCleaner stub pattern)
Sources/Bark/DictationController.swift                      (extend — reviseLastInjection, second hotkey)
Sources/Bark/CompositionRoot.swift                         (extend — wire RevisionEngine composition)
Sources/Bark/UI/SettingsView.swift                          (extend — revision hotkey recorder, toggle, history badge)
docs/SECURITY.md                                            (extend — ☐ → ☑ for revision surface)
docs/ADRs.md                                                (extend — new ADR for revision surface)
specs/009-voice-driven-revision/                            (this spec + plan + tasks + quickstart)
```

## Risks

- **AX range manipulation is brittle.** Some apps expose their content as a single AXValue
  without subrange support. The plan falls back to "select-all + replace via the existing
  `PasteboardInjector`" which is the same technique the rest of Bark uses — proven on Apple apps,
  best-effort on Electron. Document as residual risk.
- **Spoken instruction is itself a prompt-injection vector.** Mitigated by the existing
  `PromptTemplate` fence and `OutputValidator`. New: the validation rule "revised text length
  must not exceed 2× previous length" catches the "expand to include a phishing URL" pattern.
- **History migration.** Existing records (pre-009) have no `parentID`. The encrypted store
  tolerantly decodes them with `parentID = nil`. No data loss; old records render as "no parent"
  in the History pane. Forward-compatible.
- **Revision hotkey collision.** Users may already have ⌥⌘R bound globally. The recorder shows
  a warning if the key is currently bound to a system shortcut, but does not refuse (consistent
  with the existing push-to-talk recorder behaviour). Documented as a known UX rough edge.

## Verification

- `swift build` clean (lean) and `swift build` clean (MLX). `swift test` green; new tests cover:
  - `DeterministicRevisionEngine` happy paths (`delete that` → `.action(.deleteSelection)`,
    `undo` → `.action(.systemUndo)`, unknown phrase → `.miss(...)`)
  - `LLMRevisionEngine` validation: length drift, control chars, banned tokens, prompt-injection
    attempt
  - `HistoryRecord` parent linkage round-trip (codable, tolerant decode)
  - `DictationController.reviseLastInjection` end-to-end with `FakeSTTEngine` + `FakeInjector`:
    secure-field refusal, focus-guard re-check miss → text preserved
- Manual: dictate into TextEdit, revise via "more formal", revise via "shorter", verify history
  tree. With the lean build (no LLM), verify dictionary commands work end-to-end.
- SECURITY.md ☐ → ☑ for the revision surface.