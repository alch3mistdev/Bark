# Implementation Plan: In-session voice refinement (hold-to-refine)

**Branch**: `012-staged-refinement` | **Date**: 2026-06-23 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/012-staged-refinement/spec.md`

## Summary

Add an optional **second transform stage** to push-to-talk dictation. While **fn** is held, holding
the **left-option** key opens a *refinement turn*: the speech captured during the hold is a spoken
instruction that the LLM applies to the running draft. The gesture is repeatable and chains (each
turn builds on the prior result); speech with option **not** held appends to the draft as more
dictation; an **empty** option turn is a one-step **undo**; releasing **fn** injects the final draft
through the existing safe-injection path. The feature is gated on an available LLM and a default-on
"Enable hold-to-refine" setting; without the LLM it is a silent no-op and base dictation is
unchanged (fail-open). The instruction is treated as untrusted data (prompt-injection fence reused
from the cleanup path).

The technical heart is a **pure `RefineSession`** model in `BarkCore` (draft + snapshot stack +
context) plus a **pure `RefineKeyDecoder`** for left-vs-right option discrimination; the
`DictationController` push-to-talk path is reworked to a single-mic, multi-segment capture loop
modeled on the proven `runHandsFree` seam (one open mic, cycle `STTEngine.beginStream/finishStream`
per segment). Refinement runs via a new `TextCleaner.refine(_:instruction:mode:)` capability,
deterministic cleaners declining it so the lean build degrades cleanly.

## Technical Context

**Language/Version**: Swift 6 (strict concurrency)

**Primary Dependencies**: None new in the lean build. Refinement uses the existing optional
`MLXCleanup` build (`MLXTextCleaner` / Qwen3-4B) — no new dependency, no SBOM delta.

**Storage**: One new `UserDefaults` field (`holdToRefineEnabled`) via the existing tolerant
`Settings` codec. No new at-rest data; the running draft and per-turn audio are in-memory only and
discarded at fn-release.

**Testing**: XCTest. Pure logic (`RefineSession`, `RefineKeyDecoder`, refine prompt) unit-tested in
`BarkCoreTests` (lean build). Session orchestration tested in `BarkAppTests` with the existing
`FakeSTTEngine` / `ScriptedAudioCapture` / `FakeCleaner` / `FakeInjector` fakes (extend `FakeCleaner`
with a canned `refine`).

**Target Platform**: macOS 26+, Apple Silicon. Menu-bar desktop app.

**Project Type**: Desktop app — single SwiftPM package, three-layer split (`BarkCore` pure /
`BarkEngines` OS+ML adapters / `Bark` app).

**Performance Goals**: When the user never presses left-option, base dictation is byte-identical to
today and adds **no** measurable delay (SC-002/003). Each refine turn is bounded by the existing
`cleanupDeadline` (8 s) with a deterministic keep-prior-draft fallback (SC-006).

**Constraints**: Offline at runtime (no new network path). Injection happens only at fn-release
through the unchanged secure-field / focus-guard / sanitizer / no-Return controls. The mic stays open
for the fn hold; the draft and per-turn audio never leave the device and are dropped at session end.

**Scale/Scope**: Single user, single in-flight session. ~5 new source files + focused edits to
`HotkeyManager`, `DictationController`, `MLXTextCleaner`, `Mode`, `PromptTemplate`, `TextCleaner`,
`Settings`, and the HUD + Settings UI.

## Constitution Check

*GATE: must pass before Phase 0. Re-checked after Phase 1 design.*

| Principle | Status | How this plan satisfies it |
|---|---|---|
| **I. Offline-First, Privacy by Construction** | ✅ Pass | Refinement reuses the on-device LLM; no new network path, no telemetry. Draft + per-turn audio are in-memory, discarded at fn-release; nothing new persisted except a boolean toggle. |
| **II. Evidence or It Didn't Happen** | ✅ Pass | `RefineSession` (apply/undo/append/empty) and `RefineKeyDecoder` (left vs right, fn-gating) are pure and unit-tested; the three spec examples + chaining + fail-open are integration-tested with injected fakes. The OS key-decode is documented best-effort with the pure decoder carrying the logic (a named residual). |
| **III. Swappable Engines Behind Protocols** | ✅ Pass | Refine is a new `TextCleaner.refine` capability (deterministic cleaner declines; LLM cleaner implements). All decision logic is pure `BarkCore` with zero third-party deps; the pipeline depends on the protocol, not MLX. |
| **IV. Least Privilege & Safe Injection (NON-NEGOTIABLE)** | ✅ Pass | No new permission (reuses the fn hotkey + mic already granted). Injection occurs only at fn-release via the **unchanged** `performInjection` (secure-field refusal, focus re-check, sanitizer, never Return/Enter). The instruction is fenced as untrusted data; refine output passes `OutputValidator`. Undo and intermediate drafts never inject. |
| **V. Speed-First, Non-Blocking** | ✅ Pass | The base (no-option) path is unchanged and never blocked. Each refine turn runs off the MainActor under `cleanupDeadline`; on timeout/error the prior draft is preserved (fail-open). fn-release awaits at most one in-flight turn, bounded by the deadline. |

**Quality gates**: no new permission; SBOM unchanged (MLX already recorded); pure logic unit-tested,
OS hotkey adapter documented best-effort with the pure `RefineKeyDecoder` as the tested seam.

**Result**: No violations. The one notable complexity — reworking the push-to-talk capture into a
single-mic multi-segment loop — is justified below and does not change the no-option output.

## Project Structure

### Documentation (this feature)

```text
specs/012-staged-refinement/
├── plan.md              # This file
├── research.md          # Phase 0: capture-loop vs transcript-slicing, left-option decode, refine prompt
├── data-model.md        # Phase 1: RefineSession, RefineContext, RefineActivity, Mode.revisionPrompt, Settings
├── quickstart.md        # Phase 1: build (MLX) + reproduce the three example interactions end-to-end
├── contracts/
│   ├── refine-session.md          # Pure RefineSession state machine (apply/append/undo/flush)
│   ├── refine-key-decoder.md       # Pure left-option detection contract (keycode 58, fn-gated)
│   └── text-cleaner-refine.md      # TextCleaner.refine + refine PromptTemplate fence
└── checklists/requirements.md      # (from /speckit-specify, re-validated by /speckit-clarify)
```

### Source Code (repository root)

```text
Sources/
├── BarkCore/Refine/                          # NEW — pure, zero-dependency, unit-tested
│   ├── RefineSession.swift                   # draft + snapshot stack + context; apply/append/undo/flush (pure)
│   └── RefineKeyDecoder.swift                # (flags, keycode, fnHeld, auxHeld) → RefineKeyEvent? (left=58 only)
├── BarkCore/Cleanup/
│   ├── Mode.swift                            # EDIT — add optional `revisionPrompt: String?` (shared with 009)
│   ├── PromptTemplate.swift                  # EDIT — add refineSystem(for:) + refineUser(draft:instruction:)
│   └── TextCleaner.swift                     # EDIT — add refine(_:instruction:mode:) default-throws .modelUnavailable
├── BarkCore/Settings/Settings.swift          # EDIT — add holdToRefineEnabled (default true, tolerant decode)
├── BarkEngines/Hotkey/HotkeyManager.swift    # EDIT — onRefineStart/onRefineEnd via RefineKeyDecoder; never consume
├── BarkCleanupMLX/MLXTextCleaner.swift       # EDIT — implement refine() using the refine PromptTemplate + OutputValidator
└── Bark/
    ├── DictationController.swift             # EDIT — single-mic multi-segment loop; refine state; new observables; gating
    ├── UI/RecordingHUDView.swift             # EDIT — render refineActivity + currentDraft
    └── UI/SettingsView.swift                 # EDIT — "Enable hold-to-refine" toggle (shown when LLM present)

Tests/
├── BarkCoreTests/RefineSessionTests.swift            # NEW — apply/append/undo/empty/flush, snapshot stack
├── BarkCoreTests/RefineKeyDecoderTests.swift         # NEW — left(58) vs right(61), fn-held gating, edges
├── BarkCoreTests/PromptTemplateRefineTests.swift     # NEW — fence, closing-tag neutralization, per-mode vs generic
└── BarkAppTests/RefineSessionFlowTests.swift         # NEW — 3 examples, chaining, undo, fail-open, toggle-off (fakes)
```

**Structure Decision**: Reuse the three-layer split (constitution III). Everything decidable without
I/O — the draft/undo/append/flush logic and the left-option decode — is pure `BarkCore`. Only the
mic/STT cycling and the LLM call cross into engines, mirroring `runHandsFree` (the capture loop) and
`MLXTextCleaner` (the rewrite). The refine prompt mirrors the existing `PromptTemplate` fence.

## Design notes (informational; detail belongs in tasks.md)

- **Trigger.** `HotkeyManager` gains `onRefineStart`/`onRefineEnd`. While the push-to-talk modifier
  is held (`holding == true`), a `.flagsChanged` event whose keycode is **58** (left option) and whose
  alternate flag rose/fell fires the callbacks. Right option (61) and option-without-fn are ignored.
  The decision is delegated to the pure `RefineKeyDecoder`; the manager never consumes the event
  (`return false`), preserving today's behavior. Runtime keycode delivery is a documented best-effort
  residual; the decoder is unit-tested.
- **Capture.** Rework the push-to-talk path so one open mic feeds STT and segments cut on context
  changes — the same shape as `runHandsFree` (DictationController.swift:833): begin a stream, feed
  frames inline, `finishStream` at each boundary, `beginStream` for the next segment. With no
  left-option press the session is a single segment and the injected text is identical to today.
- **Session logic.** The pure `RefineSession` owns: `draft`, `snapshots: [String]` (undo stack),
  `context` (dictation | instruction). Boundary handlers call pure methods: `appendDictation(cleaned)`,
  `beginInstruction()`, and `applyOrUndo(instruction:rewrite:)` — empty instruction pops a snapshot
  (undo); non-empty pushes the old draft and adopts the validated rewrite; a failed rewrite keeps the
  draft and pushes nothing. Turns are serialized FIFO in the controller via a chained task; fn-release
  awaits the in-flight turn (≤ deadline) then injects `draft` through the unchanged `performInjection`.
- **Refine call.** `TextCleaner.refine(_:instruction:mode:)` defaults to throwing `.modelUnavailable`
  (deterministic cleaners). `MLXTextCleaner.refine` builds the prompt from `PromptTemplate.refineSystem`
  (`mode.revisionPrompt ?? generic`) + `refineUser(draft:instruction:)` (both fenced), runs under the
  deadline, and validates length with `OutputValidator`.
- **Gating (FR-011/FR-017).** Refinement is live only when `holdToRefineEnabled && llmAvailable &&
  llmEnabled && llm.isAvailable`. Otherwise `onRefineStart/End` are ignored and all speech stays
  dictation — base behavior unchanged.

## Complexity Tracking

> No constitution violations. The push-to-talk capture rework is the one notable complexity; it is
> justified because per-segment transcripts require controlled `beginStream/finishStream` boundaries,
> the no-option output is held identical by SC-002/SC-003 tests, and it reuses the already-shipped
> `runHandsFree` pattern rather than inventing a new mechanism. The lower-risk alternative
> (transcript-offset slicing over a single uninterrupted stream) is recorded in research.md as the
> fallback if the rework regresses the base path.
