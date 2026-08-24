# Implementation Plan: Streaming Suggested Responses

**Branch**: `016-streaming-suggestions` | **Date**: 2026-08-24 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/016-streaming-suggestions/spec.md`

## Summary

Cut time-to-first-candidate for Suggested Responses (015) by streaming: the engine's incremental output is parsed as it arrives, each candidate is validated and appended to the overlay the moment it completes, and selection of a shown candidate cancels the rest. Engine prewarm already overlaps context capture (015 R2) — this feature verifies and locks that behavior. Non-streaming backends degrade to today's all-at-once display through a protocol default, so no 015 behavior regresses.

## Technical Context

**Language/Version**: Swift 6 (Xcode 26 toolchain), strict concurrency

**Primary Dependencies**: MLX-Swift (local LLM, already streams internally via `streamDetails`), AppKit/SwiftUI overlay panel, no new third-party dependencies

**Storage**: N/A (captured context stays ephemeral; history usage unchanged)

**Testing**: XCTest via `swift test` — pure logic in `BarkCoreTests` (stream parser, session machine), orchestration in `BarkAppTests` with injected fakes (streaming fake engine, fake capture, fake injectors)

**Target Platform**: macOS 26+ on Apple Silicon

**Project Type**: Desktop menu-bar app (existing SwiftPM workspace: `BarkCore` pure logic, `BarkCleanupMLX` local engine, `BarkEngines` OS/network adapters, `Bark` app/UI)

**Performance Goals**: Median hotkey→first-selectable-candidate reduced ≥40% vs pre-streaming build (SC-001); overlay append is O(1) per candidate; no main-thread stalls during streaming

**Constraints**: Byte-parity — streaming must render exactly the candidates the batch parser would produce for the same raw output (SC-002); candidates immutable once shown; no partial text ever rendered or injectable; offline-first unchanged

**Scale/Scope**: 4 modules touched, ~6 source files + 4 test files; no settings schema change; no new permissions

## Constitution Check

*GATE: evaluated pre-Phase-0 and re-checked post-design — PASS (no violations, no Complexity Tracking entries).*

- **I. Offline-First, Privacy by Construction**: PASS. No new network paths. External endpoint continues non-streaming in v1 (research R1) — nothing new is transmitted. Streamed fragments are held in memory only, never logged (the 015 raw-output diagnostic was removed; streaming must not reintroduce it).
- **II. Evidence or It Didn't Happen**: PASS. Parity corpus test (SC-002), cancellation tests (SC-004), and degrade regression (SC-005 = all 015 scenarios) are named deliverables; TTFC baseline measured before merge.
- **III. Swappable Engines Behind Protocols**: PASS. Streaming lands as a defaulted `SuggestionEngine` extension point — existing conformers compile unchanged; the pipeline still depends only on the protocol. `BarkCore` stays dependency-free.
- **IV. Least Privilege & Safe Injection (NON-NEGOTIABLE)**: PASS. Injection, sanitization, secure-field refusal, auto-submit policy untouched. The overlay takes key only after capture completes (unchanged R3 constraint); early selection cancels generation *before* the injection path runs.
- **V. Speed-First, Non-Blocking**: PASS — this feature is Principle V applied to suggestions.

## Project Structure

### Documentation (this feature)

```text
specs/016-streaming-suggestions/
├── plan.md              # This file
├── research.md          # Phase 0
├── data-model.md        # Phase 1
├── quickstart.md        # Phase 1
├── contracts/
│   └── streaming-engine.md
└── tasks.md             # Phase 2 (/speckit-tasks)
```

### Source Code (repository root)

```text
Sources/
├── BarkCore/Suggest/
│   ├── SuggestionEngine.swift            # + suggestStream(_:) defaulted requirement (contract)
│   ├── SuggestionStreamParser.swift      # NEW — incremental candidate extraction (pure)
│   ├── SuggestionResponseParser.swift    # refactor: share validation with stream parser
│   └── SuggestionSession.swift           # incremental events, stable numbering, streaming flag
├── BarkCleanupMLX/
│   └── MLXTextCleaner+Suggest.swift      # native suggestStream over streamDetails chunks
├── Bark/
│   ├── SuggestionController.swift        # streaming loop, split generation task, cancel-on-select
│   ├── SuggestionOverlayController.swift # key panel from .generating; footer indicator sizing
│   └── UI/SuggestionOverlayView.swift    # progressive rows + generating footer + early Other…

Tests/
├── BarkCoreTests/
│   ├── SuggestionStreamParserTests.swift # NEW — incl. chunked parity corpus vs batch parser
│   └── SuggestionSessionTests.swift      # incremental-event transitions, highlight stability
└── BarkAppTests/
    ├── SuggestionStreamingFlowTests.swift# NEW — streaming fake engine end-to-end
    └── SuggestionControllerFlowTests.swift # updated for incremental events + degrade path
```

**Structure Decision**: Existing 015 module split is kept — pure streaming logic (parser, session) in `BarkCore`, engine conformance in `BarkCleanupMLX`, orchestration/UI in `Bark`. No new targets.
