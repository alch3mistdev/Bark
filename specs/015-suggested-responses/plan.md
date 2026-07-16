# Implementation Plan: Suggested Responses

**Branch**: `015-suggested-responses` | **Date**: 2026-07-16 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/015-suggested-responses/spec.md`

## Summary

A third global flow beside push-to-talk and hands-free: a hotkey snapshots the frontmost app, captures on-screen context (AX tree first, on-device OCR fallback), asks a `SuggestionEngine` (local MLX sharing the cleaner's model residency, or a user-configured OpenAI-compatible endpoint) for 3–4 validated single-line candidates, and presents them in a key-accepting **non-activating** overlay panel. Selection injects through the untouched `InjectionRouter`/`TextInjector` pipeline; "Other…" hands off to a one-shot hands-free dictation; an opt-in auto-submit posts a single re-preflighted Return via the one new `ReturnKeySynthesizer` component (ADR-009). All new orchestration lives in a new `SuggestionController` — **zero edits to `DictationController` for the MVP story**. Captured context is ephemeral and prompt-fenced as untrusted input.

## Technical Context

**Language/Version**: Swift 6.1 (strict concurrency), macOS 26 per `Package.swift`

**Primary Dependencies**: SwiftUI + Observation (overlay, settings pane); ScreenCaptureKit + Vision (OCR fallback — system frameworks, BarkEngines only); URLSession (external backend); no new third-party dependencies (BarkCore stays dependency-free)

**Storage**: Existing `SettingsStore` (`com.bark.settings.v1`, lenient decode) for six new fields; Keychain generic-password item for the external API key (pattern: `EncryptedSpeakerProfileStore`); captured context: none, by contract

**Testing**: XCTest via `swift test` — BarkCoreTests for the seven new pure types; BarkAppTests flow tests with `FakeContextCapture`/`FakeSuggestionEngine`/`FakeInjector`; URLProtocol stubs for the HTTP client

**Target Platform**: macOS 26 menu-bar app, lean and MLX build configurations

**Project Type**: Desktop app — SwiftPM workspace (`BarkCore` pure, `BarkEngines` OS adapters, `BarkCleanupMLX` LLM engine, `Bark` app/UI)

**Performance Goals**: hotkey → overlay ≤ 6 s warm-local (SC-001); capture stage ≤ 1 s (AX walk depth ≤ 8, ≤ 200 elements, 0.25 s AX messaging timeout, off-main); generation under a 12 s hard deadline; overlay interaction at full frame rate

**Constraints**: context ephemeral (no disk/log/history); secure-field refusal at capture AND injection; external backend opt-in with warning, fail-toward-local only; Return synthesis confined to `ReturnKeySynthesizer`; feature disabled by default; lean build = external backend or honest unavailable

**Scale/Scope**: ~20 new source files + 6 modified, ~10 new test files; 6 new Settings fields; one new settings pane; one new permission kind (Screen Recording)

## Constitution Check

*GATE: gated against constitution v2.0.0 (amended this feature, ADR-009).*

| Principle | Status | Evidence |
|-----------|--------|----------|
| I. Offline-First (v2.0.0) | PASS | Default backend local; external endpoint is the explicit per-feature opt-in carved out in v2.0.0: off by default, warning names transmitted data, key in Keychain, fail-toward-local, context never persisted/logged (FR-005, FR-013, FR-014). Dictation paths untouched and fully offline. |
| II. Evidence or It Didn't Happen | PASS | Tests-first phases for every pure type; flow-test matrix for routing/auto-submit (SC-003/004); spike task produces a written result before overlay build-out; quickstart-style QA matrix in Polish phase. |
| III. Swappable Engines Behind Protocols | PASS | New `SuggestionEngine` + `ContextCapturing` protocols in BarkCore; MLX and OpenAI-compatible backends are interchangeable conformances; overlay/controller depend only on protocols. `TextCleaner`, `STTEngine`, `TextInjector` unchanged. |
| IV. Least Privilege & Safe Injection (v2.0.0) | PASS | Screen Recording requested just-in-time, degradable (FR-017). Secure-field refusal at capture and injection (FR-004, FR-010). Injectors keep their never-Return contract; the sole Return path is the opt-in, re-preflighted `ReturnKeySynthesizer` exception codified in v2.0.0 + ADR-009 (FR-012). Context fenced as untrusted (FR-008). |
| V. Speed-First, Non-Blocking | PASS | Suggestion flow is parallel to dictation and never touches its latency path; LLM warm reuses the existing lifecycle (FR-016); generation deadline-bounded with honest error states (FR-014); capture off-main. |

**Post-design re-check**: PASS — no Complexity Tracking entries; the one contentious mechanism (key-accepting non-activating panel) is gated behind a spike with a documented fallback.

## Project Structure

### Documentation (this feature)

```text
specs/015-suggested-responses/
├── spec.md              # Feature specification
├── plan.md              # This file
├── research.md          # R1–R11 design decisions + ACP deferral
└── tasks.md             # Phase 2 output (/speckit-tasks)
```

### Source Code (repository root)

```text
Sources/
├── BarkCore/
│   ├── Context/
│   │   ├── CapturedContext.swift        # NEW: context model + isThin + ContextBudget clip
│   │   └── ContextCapturing.swift       # NEW: capture protocol (impl in Engines, faked in tests)
│   └── Suggest/
│       ├── SuggestionSession.swift      # NEW: state machine (idle→capturing→generating→presenting→…)
│       ├── SuggestionEngine.swift       # NEW: engine protocol + SuggestionRequest + SuggestionBackendID + errors
│       ├── SuggestionPrompt.swift       # NEW: guardrailed, fenced prompt builders (mirrors PromptTemplate)
│       ├── SuggestionResponseParser.swift # NEW: JSON-array parse + bullet salvage + validation (1–4, ≤160, single-line)
│       ├── SuggestionKeyDecoder.swift   # NEW: keycode→event table (1-4/arrows/Return/Esc/o) — twin of RefineKeyDecoder
│       ├── HistoryRelevance.swift       # NEW: field-label keywords → top-3 clipped history snippets
│       └── AutoSubmitPolicy.swift       # NEW: decide(enabled:secureInput:focusChanged:routing:) — pure guard
├── BarkEngines/
│   ├── Context/
│   │   ├── AXContextReader.swift        # NEW: off-main AX walk (value/title/description/placeholder, DFS ≤8/≤200)
│   │   ├── WindowOCRReader.swift        # NEW: SCK one-frame capture + Vision RecognizeText
│   │   └── ContextCaptureService.swift  # NEW: ContextCapturing impl — AX first, OCR when thin
│   ├── Suggest/
│   │   ├── OpenAICompatClient.swift     # NEW: SuggestionEngine over URLSession chat-completions
│   │   └── KeychainSecretStore.swift    # NEW: API-key keychain wrapper (EncryptedSpeakerProfileStore pattern)
│   ├── Inject/ReturnKeySynthesizer.swift # NEW: sole Return-posting site, re-runs InjectionPreflight
│   └── Permissions/PermissionsCoordinator.swift  # MODIFIED: + .screenRecording kind
├── BarkCleanupMLX/
│   └── MLXTextCleaner+Suggest.swift     # NEW: SuggestionEngine conformance sharing ModelContainer; lean stub
└── Bark/
    ├── SuggestionController.swift       # NEW: @MainActor @Observable orchestrator (parallel to DictationController)
    ├── SuggestionOverlayController.swift # NEW: key-accepting non-activating NSPanel, caret placement, resignKey dismiss
    ├── UI/SuggestionOverlayView.swift   # NEW: candidate rows + Other… + loading/error states
    ├── UI/Settings/SuggestionsPane.swift # NEW: enable, hotkey, backend, endpoint/model/key, auto-submit + warnings
    ├── CompositionRoot.swift            # MODIFIED: 3rd HotkeyManager, capture service, engines, SuggestionController
    ├── BarkApp.swift                    # MODIFIED: activate controller; multiplex onPhaseChange (HUD + suggestions)
    └── UI/SettingsView.swift            # MODIFIED: + .suggestions pane case
Sources/BarkCore/Settings/Settings.swift # MODIFIED: 6 new fields, lenient decode, 3-way hotkey collision domain
Tests/
├── BarkCoreTests/  # NEW: SuggestionSession/Prompt/Parser/KeyDecoder/HistoryRelevance/ContextBudget/AutoSubmitPolicy + Settings additions
└── BarkAppTests/   # NEW: SuggestionControllerFlowTests, OpenAICompatClientTests (URLProtocol), KeychainSecretStoreTests; Fakes.swift additions
```

## Settings additions (`Settings.swift`, all lenient-decoded with defaults)

```swift
public var suggestionsEnabled: Bool = false
public var suggestionsHotkey: HotkeySetting  // keyToggle, keyCode 97 (F6); F5=96 is hands-free
public var suggestionBackend: SuggestionBackendID = .local
public var externalLLMEndpoint: String = ""                     // e.g. http://localhost:11434/v1
public var externalLLMModel: String = ""
public var suggestionAutoSubmit: Bool = false                   // ADR-009 exception, warning copy in UI
```

API key: Keychain only (`KeychainSecretStore`, service `com.bark.external-llm`). Context char budget is a `ContextBudget` constant (4000), not a setting. The hotkey setter extends the existing pairwise collision guard to a 3-way check.

## Design decisions

Numbered rationale lives in [research.md](research.md) (R1–R11). Load-bearing ones:

- **R1** New `SuggestionController` parallel to `DictationController` (zero-edit MVP goal for the ~1300-line orchestrator; consumes only its public seams: `phase`, `prepareLLM()`, `llmStatus`, `startHandsFree()`, `stopHandsFree()`).
- **R2** New `SuggestionEngine` protocol rather than widening `TextCleaner`; the MLX actor conforms to both and shares one `ModelContainer` residency + the existing warm/idle-unload lifecycle.
- **R3** Overlay = key-accepting **non-activating** panel (`.nonactivatingPanel` + `canBecomeKeyWindow`) so the owning app never activates and `FocusGuard.targetUnchanged` passes with no focus-restore dance. Gated by a spike; fallback = event-tap key consumption (HotkeyManager pattern).
- **R4** One JSON-array generation at temperature 0 (not N sampled runs): 3–4× cheaper on the 4B model, better JSON adherence; diversity is prompt-driven; lenient parser + hard validation.
- **R6** Auto-submit is a post-injection step in `ReturnKeySynthesizer`, not an `InjectionPlan` flag — the three injectors and their never-Return contract stay byte-identical.

## Complexity Tracking

None — no constitution violations to justify under v2.0.0; the amendment itself is governed by ADR-009 with user sign-off.
