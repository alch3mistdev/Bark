# Implementation Plan: Context-aware reply options (Smart Replies)

**Branch**: `009-context-prompt-options` | **Spec**: ./spec.md

## Approach

Add a **third swappable on-device skill** alongside STT and cleanup, following the exact
deterministic-first / LLM-optional pattern of `TextCleaner` (ADR-003).

- **Read context behind a protocol.** New `ContextProvider` (BarkCore) returns a
  `ConversationContext { lastMessage, appBundleID }` for the focused app. The runtime
  implementation `AccessibilityContextReader` (BarkEngines) reads the focused window's accessible
  text best-effort (AX, with a short messaging timeout, bounded traversal). It reads **content**,
  unlike the existing `FocusProbe` which reads only bounds — so it is gated by the Smart Replies
  opt-in and documented as best-effort.

- **Suggest behind a protocol.** New `BranchSuggester` (BarkCore) mirrors `TextCleaner`:
  `isAvailable`, `prepare(progress:)` (default no-op), `suggest(for:maxOptions:) -> [BranchOption]`.
  - `BasicBranchSuggester` (pure, always available): `QuestionClassifier` detects yes/no →
    `Yes`/`No`; otherwise a small generic set. Fully unit-tested.
  - `MLXBranchSuggester` (BarkCleanupMLX): uses the **same model** as cleanup via a shared
    `MLXModelHost`, so enabling the LLM downloads/loads Qwen3-4B **once** for both skills.
    `BranchPromptTemplate` fences the context as untrusted data and parses/bounds the model's
    line-per-reply output into `[BranchOption]`.

- **Share the model container.** Introduce `MLXModelHost` (actor) that owns the `ModelContainer`
  and exposes `prepare` / `isLoaded` / `respond(instructions:to:)`. Refactor `MLXTextCleaner` to
  use it and add `MLXBranchSuggester` on top — no second download, no double GPU memory. The lean
  build keeps no-op stubs for both, so default `swift test` stays offline.

- **Controller orchestration (no pipeline changes).** This is a parallel flow, like re-insert — it
  does **not** touch the `DictationStateMachine`. On menu open: `prepareBranchContext()` snapshots
  the target (reusing `snapshotReinsertTarget`, which already filters out Bark's own pid) and reads
  context, then publishes deterministic `branchOptions`. `requestLLMSuggestions()` replaces them
  with model output under `withThrowingDeadline`, falling back on failure. `chooseBranch(_:)`
  injects the payload through the **existing** targeted-insert path (extracted from `reinsert`) —
  sanitized, focus-re-verified, secure-field-guarded, **no Return**.

- **UI.** A "Smart Replies" section in the menu popover (shown only when enabled & idle): a
  `.task` runs `prepareBranchContext()`, options render as buttons → `chooseBranch`, an
  "AI suggestions" button calls `requestLLMSuggestions()` (enabled only when the model is ready), and
  a "Dictate a custom reply" affordance dismisses and defers to the hotkey. A Settings toggle
  (`smartRepliesEnabled`, default false) + a Privacy note.

## Constitution Check

- **I (Offline/Privacy):** context is read on-device and fed only to the on-device model; nothing
  transmitted; not persisted. Reading other-app content is opt-in (default off). PASS.
- **III (Protocols):** `ContextProvider` + `BranchSuggester` are protocols in `BarkCore`; concrete
  AX/MLX backends are swappable; pure logic has zero deps and is unit-tested. PASS.
- **IV (Safe injection, NON-NEGOTIABLE):** picks reuse the existing injection guards; **Return is
  never synthesized** (auto-submit explicitly out of scope); untrusted context is fenced. PASS.
- **V (Speed/non-blocking):** deterministic quick replies are instant; LLM runs under the hard
  deadline with a deterministic fallback. PASS.

## Files

```
Sources/BarkCore/Context/ConversationContext.swift     (new: context + BranchOption + ContextProvider)
Sources/BarkCore/Context/BranchSuggester.swift         (new: protocol + default prepare)
Sources/BarkCore/Context/BasicBranchSuggester.swift    (new: yes/no + generic, pure)
Sources/BarkCore/Context/QuestionClassifier.swift      (new: yes/no detection, pure)
Sources/BarkCore/Context/BranchPromptTemplate.swift    (new: injection-safe prompt + parse/bound)
Sources/BarkCore/Settings/Settings.swift               (+ smartRepliesEnabled, default false)
Sources/BarkEngines/Context/AccessibilityContextReader.swift  (new: AX read, best-effort)
Sources/BarkCleanupMLX/MLXModelHost.swift              (new: shared container; stub in lean build)
Sources/BarkCleanupMLX/MLXTextCleaner.swift            (refactor to use MLXModelHost)
Sources/BarkCleanupMLX/MLXBranchSuggester.swift        (new: LLM suggester; stub in lean build)
Sources/Bark/DictationController.swift                 (branch state + orchestration; extract insert)
Sources/Bark/CompositionRoot.swift                     (wire reader + shared host + suggester)
Sources/Bark/UI/MenuContentView.swift                  (Smart Replies section)
Sources/Bark/UI/SettingsView.swift                     (toggle + privacy note)
Tests/BarkCoreTests/BranchSuggestionTests.swift        (new: classifier, basic, prompt parse)
Tests/BarkAppTests/Fakes.swift                         (+ FakeContextProvider, FakeBranchSuggester)
Tests/BarkAppTests/SmartRepliesTests.swift             (new: controller orchestration)
```

## Risks / Residuals

- **AX content read is best-effort and OS-runtime-dependent** (cannot be unit-tested): different
  apps/Electron/web views expose their text differently, and "the latest message" is heuristic
  (tail of the focused window's accessible text, bounded). Documented as a named residual; the
  feature degrades to "No reply context found" rather than misbehaving.
- **This Linux environment cannot build/run the macOS-26 targets** (no Swift toolchain; AppKit /
  Speech / MLX unavailable). Per Principle II, `swift build` / `swift test` and MLX-target
  compilation are listed as verification tasks to be run on macOS — **not** claimed green here.
- `MLXTextCleaner` refactor changes its initializer (now `init(host:)`); the only caller is
  `CompositionRoot` (under `#if MLXCleanup`). Lean build is unaffected (stubs).
