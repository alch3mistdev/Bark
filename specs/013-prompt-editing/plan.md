# Implementation Plan: Prompt Transparency & Editing

**Branch**: `013-prompt-editing` | **Date**: 2026-07-06 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/013-prompt-editing/spec.md`

## Summary

Expose the exact LLM prompts in Settings › Modes: every LLM mode shows its full assembled prompt (fixed safety guardrail + task instruction + refinement instruction). Built-in modes become editable via a **prompt override** stored per mode id in `Settings` — the shipped `Mode.builtInModes` constants are never mutated, so reset-to-default is just "delete the override" and future default updates flow through. Custom mode editing is extended to cover the refinement prompt. All prompt assembly stays in `PromptTemplate`; the guardrail remains a non-editable constant (Constitution IV).

## Technical Context

**Language/Version**: Swift 6.1 (strict concurrency), macOS 15+

**Primary Dependencies**: SwiftUI (settings UI), Observation framework; no new third-party dependencies (BarkCore stays dependency-free)

**Storage**: Existing `SettingsStore` — `Settings` JSON in `UserDefaults` (`com.bark.settings.v1`), lenient decode for forward/backward compat

**Testing**: XCTest via `swift test` (BarkCoreTests for pure logic, BarkAppTests with fakes for controller wiring)

**Target Platform**: macOS 15+ menu-bar app

**Project Type**: Desktop app — SwiftPM workspace (`BarkCore` pure logic, `Bark` app/UI, `BarkCleanupMLX` LLM engine)

**Performance Goals**: Settings UI interactions instant (<16ms frame); no impact on dictation latency (prompt assembly is string concat, unchanged)

**Constraints**: Offline-only; guardrail text immutable by user action; prompt fields bounded at 4,000 chars each; edits must not touch in-flight dictations

**Scale/Scope**: 6 built-in modes + unbounded custom modes; 2 editable prompt fields per mode; ~4 source files touched + 1 new file + tests

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Evidence |
|-----------|--------|----------|
| I. Offline-First | PASS | Feature is settings + string assembly only; no network surface. Prompt data persists in existing on-device `UserDefaults` blob. |
| II. Evidence or It Didn't Happen | PASS | Quickstart defines runnable validation; unit tests assert byte-identity of displayed vs sent prompts (SC-001). |
| III. Swappable Engines Behind Protocols | PASS | No protocol changes. `PromptTemplate` stays the single prompt-assembly point in `BarkCore`; MLX engine unchanged (`MLXTextCleaner` already calls `PromptTemplate.system(for:)` with whatever `Mode` it receives). |
| IV. Least Privilege & Safe Injection | PASS | Guardrail (`PromptTemplate.guardrail`, `refineGuardrail`) remains a compile-time constant — viewable in UI, never editable/persisted. User edits touch only `Mode.systemPrompt` / `Mode.revisionPrompt`, which were always mode-supplied data appended AFTER the guardrail. Injection defenses (fencing, tag-stripping, `OutputValidator`) untouched. |
| V. Speed-First, Non-Blocking | PASS | No pipeline changes; LLM stage semantics unchanged. |

**Post-Phase-1 re-check**: PASS — design adds one Codable struct + one Settings field + UI; no principle affected. No Complexity Tracking entries needed.

## Project Structure

### Documentation (this feature)

```text
specs/013-prompt-editing/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/
│   └── settings-schema.md   # Persisted Settings v1 additions + UI contract
└── tasks.md             # Phase 2 output (/speckit-tasks)
```

### Source Code (repository root)

```text
Sources/
├── BarkCore/
│   ├── Cleanup/
│   │   ├── Mode.swift               # + resolvedRevisionPrompt helper (display parity)
│   │   ├── PromptOverride.swift     # NEW: override struct + apply/limits/validation
│   │   └── PromptTemplate.swift     # unchanged assembly; source of displayed text
│   └── Settings/
│       └── Settings.swift           # + builtInPromptOverrides field, effectiveModes()
├── Bark/
│   ├── DictationController.swift    # modes uses effectiveModes(); override CRUD API
│   └── UI/
│       └── SettingsView.swift       # ModesPane: built-in rows open PromptEditor;
│                                    # unified editor w/ guardrail view, reset, limits
Tests/
├── BarkCoreTests/
│   ├── PromptOverrideTests.swift    # NEW: apply/reset/modified/limits/fallback/byte-identity
│   └── SettingsTests.swift          # + round-trip & lenient-decode for overrides
└── BarkAppTests/
    └── (controller override CRUD via existing fakes if needed)
```

**Structure Decision**: Existing SwiftPM layout. Pure override logic in `BarkCore` (unit-testable, zero deps); persistence via existing `Settings`/`SettingsStore`; UI in `Bark/UI/SettingsView.swift`. One new source file, one new test file.

## Design Decisions (summary — details in research.md)

1. **Overrides, not mutated built-ins**: `Settings.builtInPromptOverrides: [String: PromptOverride]` keyed by built-in mode id. `PromptOverride { systemPrompt: String?, revisionPrompt: String? }` — `nil` field = not overridden. Reset = remove key. "Modified" badge = key present with ≥1 non-nil field that differs from the shipped default (an override equal to the default is pruned on save).
2. **Single source of truth for effective modes**: `Settings.effectiveModes()` = built-ins with overrides applied + customModes. Used by `makeModeRegistry()` and `DictationController.modes` so UI, per-app resolution, and the pipeline all see the same prompts.
3. **Exact-prompt display**: the editor renders `PromptTemplate.guardrail` / `refineGuardrail` verbatim (read-only, locked style) above the editable task/refinement fields, plus the empty-field fallback notes — the same constants and functions the engine uses, so display ≡ sent (SC-001 tested by asserting `PromptTemplate.system(for: effectiveMode)` contains the override text and starts with the displayed guardrail).
4. **Validation in Core**: `PromptOverride.maxFieldLength = 4_000`; `validate()` rejects over-limit fields. UI enforces live (char count + disabled Save); `DictationController` guards again on write (defense in depth).
5. **Custom modes unchanged in shape**: still full `Mode` values in `customModes`; editor gains a refinement-prompt field and the same exact-prompt preview. No migration needed (`revisionPrompt` already optional/lenient).

## Complexity Tracking

No constitution violations — table not needed.
