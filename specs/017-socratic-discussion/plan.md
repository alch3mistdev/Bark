# Implementation Plan: Socratic Discussion (pre-action prompt refinement)

**Branch**: `017-socratic-discussion` | **Date**: 2026-09-13 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/017-socratic-discussion/spec.md`

## Summary

Add a pre-action discussion phase: a hotkey (default F7) opens a floating overlay in which the
user and the on-device LLM hold a Socratic, multi-turn dialogue (user speaks via existing STT;
AI replies in the overlay, optionally spoken via on-device TTS) grounded in a snapshot of the
focused window (015 capture, plus manual Recapture). When the engine signals readiness or the
user presses Done, the engine synthesizes one final prompt, shown in a preview; Confirm injects
it into the original app through the existing safe-injection path. New seams: `DialogueEngine`
(message-array chat), `SpeechSynthesizing` (TTS), a mic lease for hard exclusivity, and a pure
`DiscussionSession` state machine. Everything else — STT, VAD, capture, injection, hotkeys,
settings — is reused behind existing protocols.

## Technical Context

**Language/Version**: Swift 6 (Xcode 26 toolchain), strict concurrency

**Primary Dependencies**: MLX-Swift `ChatSession` (multi-turn via `history:`), AVFoundation
`AVSpeechSynthesizer` (already linked; first use in repo), AppKit/SwiftUI overlay panel. No new
third-party dependencies.

**Storage**: None. Transcript + captured context are memory-only, never persisted, never in
history (FR-010).

**Testing**: XCTest via `swift test` — pure logic in `BarkCoreTests` (session machine, prompt
builder, reply parser), orchestration in `BarkAppTests` with injected fakes (dialogue engine,
TTS, scripted STT/audio, capture, injectors).

**Target Platform**: macOS 26+ on Apple Silicon

**Project Type**: Desktop menu-bar app (existing SwiftPM workspace: `BarkCore` pure logic,
`BarkCleanupMLX` local engine, `BarkEngines` OS adapters, `Bark` app/UI)

**Performance Goals**: Turn latency dominated by LLM generation (reply ≤ 256 tokens, temp 0);
per-turn deadline 20 s; UI updates on MainActor with no blocking work; TTS never delays text
presentation (text renders first, speech follows).

**Constraints**: Half-duplex invariant — mic is provably never armed while TTS plays or the
engine generates (SC-002, asserted by test); no partial/free text ever drives control flow
(FR-003); no auto-submit path exists; offline-first unchanged; lean build disables the feature
(dialogue requires an engine).

**Scale/Scope**: 4 modules touched; ~10 new source files + ~5 edited; 4 new Settings fields;
no new permissions (mic/AX/Input Monitoring already requested by existing features).

## Constitution Check

*GATE: evaluated pre-Phase-0 and re-checked post-design — PASS (no violations, no Complexity
Tracking entries).*

- **I. Offline-First, Privacy by Construction**: PASS. Default engine is on-device; TTS is
  on-device (`AVSpeechSynthesizer`). External endpoint reuses the existing ADR-010 opt-in with
  a strengthened warning naming multi-turn transcripts (research R8). Transcript + context are
  memory-only, wiped on session end, never in history or logs (FR-010).
- **II. Evidence or It Didn't Happen**: PASS. Named deliverables: half-duplex invariant test
  (SC-002), transcript-never-lost failure-path tests (SC-004), injection-safety parity tests
  (SC-005), unchanged existing suites (SC-003). `swift build` + `swift test` output shown.
- **III. Swappable Engines Behind Protocols**: PASS. `DialogueEngine` and `SpeechSynthesizing`
  are BarkCore protocols; MLX and OpenAI-compatible conformers live outside BarkCore; the
  controller depends only on the protocols. `BarkCore` stays dependency-free.
- **IV. Least Privilege & Safe Injection (NON-NEGOTIABLE)**: PASS. No new permissions. The
  discussion path never wires `ReturnKeySynthesizing`; injection reuses the existing
  preflighted injectors (PID re-verify, secure-field refusal, sanitizer, clipboard restore).
  Session start refuses secure fields (FR-013). Auto-submit does not exist here.
- **V. Speed-First, Non-Blocking**: PASS. Dictation paths untouched. Engine calls are
  deadline-bounded with explicit user-facing degradation (retry / Done / clipboard), never a
  silent stall.

## Project Structure

### Documentation (this feature)

```text
specs/017-socratic-discussion/
├── spec.md              # Feature specification (committed)
├── plan.md              # This file
├── research.md          # Phase 0
├── data-model.md        # Phase 1
├── quickstart.md        # Phase 1
├── contracts/
│   ├── dialogue-engine.md
│   └── speech-synthesizer.md
└── tasks.md             # Phase 2 (/speckit-tasks)
```

### Source Code (repository root)

```text
Sources/
├── BarkCore/Discuss/                        # NEW module dir — pure, dependency-free
│   ├── DialogueEngine.swift                 # protocol + DialogueTurn/DialogueReply/DialogueError
│   ├── DialogueReplyParser.swift            # tolerant {"reply","ready"} JSON extraction
│   ├── DialoguePromptBuilder.swift          # guardrail, fencing (fixed-point neutralize), prompts
│   └── DiscussionSession.swift              # pure state machine (events → state, transcript)
├── BarkCore/Speech/
│   └── SpeechSynthesizing.swift             # protocol: speak(_:) async, stop()
├── BarkCleanupMLX/
│   └── MLXTextCleaner+Dialogue.swift        # DialogueEngine via ChatSession(history:) per turn
├── BarkEngines/
│   ├── Speech/AVSpeechSynthesizerEngine.swift  # delegate→continuation bridge, system voice
│   └── Suggest/OpenAICompatClient.swift        # EDIT: + DialogueEngine conformance (messages array)
└── Bark/
    ├── DiscussionController.swift           # NEW — session orchestration, turn loop, mic lease,
    │                                        #   TTS gating, synthesis, preview, injection handoff
    ├── DiscussionOverlayController.swift    # NEW — panel lifecycle (015 pattern)
    ├── UI/DiscussionOverlayView.swift       # NEW — transcript, question, state, buttons, preview
    ├── UI/Settings/DiscussionPane.swift     # NEW — enable, hotkey, mic mode, TTS, privacy copy
    ├── DictationController.swift            # EDIT: micLeaseHeld guard; 4-way hotkey guard
    ├── SuggestionController.swift           # EDIT: 4-way hotkey guard
    ├── CompositionRoot.swift                # EDIT: wire DiscussionController + engines + hotkey
    ├── BarkApp.swift                        # EDIT: phase multiplex / activation
    └── UI/SettingsView.swift                # EDIT: add pane case
Sources/BarkCore/Settings/Settings.swift     # EDIT: 4 new fields (tolerant decoder)

Tests/
├── BarkCoreTests/
│   ├── DiscussionSessionTests.swift         # NEW — all transitions incl. resume/cancel-everywhere
│   ├── DialoguePromptBuilderTests.swift     # NEW — fencing fixed-point, prompt assembly
│   └── DialogueReplyParserTests.swift       # NEW — tolerant parse, fail-safe ready=false
└── BarkAppTests/
    ├── DiscussionControllerFlowTests.swift  # NEW — happy loop (PTT+VAD), half-duplex invariant,
    │                                        #   failures, PID-mismatch, secure-field, lease
    └── Fakes.swift                          # EDIT: FakeDialogueEngine, FakeSpeechSynthesizer
```

**Structure Decision**: Mirrors the 015/016 split — pure logic (session machine, prompts,
parser, protocols) in `BarkCore`; engine conformances in `BarkCleanupMLX` / `BarkEngines`;
orchestration + UI in `Bark`. No new targets, no new dependencies.

## Complexity Tracking

None — no constitution violations.
