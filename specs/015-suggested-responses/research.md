# Research & Design Decisions: Suggested Responses (015)

Decisions verified against the codebase (file:line where load-bearing). Format follows 013's research.md.

## R1 — New `SuggestionController`, not more `DictationController`

**Decision**: All suggestion orchestration lives in a new `@MainActor @Observable SuggestionController`; `DictationController` is not edited for the MVP story.

**Rationale**: `DictationController` (~1300 lines) already orchestrates three flows. The suggestion flow needs zero private state from it — everything it consumes is public: `phase`, `handsFreeActive`, `prepareLLM()`, `llmStatus`, `startHandsFree()`, `stopHandsFree()`, settings accessors. Injectors are stateless public classes constructed in `CompositionRoot`, so the new controller instantiates its own set (same pattern as `reinsert`, DictationController.swift:438-461). Keeps the highest-risk file untouched.

**Alternative rejected**: folding into `DictationController` — compounds an already-large orchestrator and forces its tests to cover an unrelated flow.

## R2 — New `SuggestionEngine` protocol; MLX conformance shares the cleaner's model

**Decision**: `protocol SuggestionEngine` (`isAvailable`, `prepare(progress:)`, `suggest(_:) -> [String]`, `unload()`) in BarkCore. `MLXTextCleaner` gains a conformance extension sharing its loaded `ModelContainer` (MLXTextCleaner.swift:25) — one ~2.5 GB residency serves cleanup and suggestions; warm/idle-unload lifecycle (DictationController.swift:276-298) is reused via `dictation.prepareLLM()` at hotkey time so load overlaps capture.

**Rationale**: `TextCleaner`'s contract is "faithful rewrite, never invent" (TextCleaner.swift:16) with growth-bound output validation; suggestions are generative with list-shaped validation. Separate protocols keep both contracts honest and testable.

**Alternative rejected**: widening `TextCleaner` — muddies the rewrite contract every existing conformance and test depends on.

## R3 — Overlay: key-accepting non-activating panel; spike-gated with tap fallback

**Decision**: `NSPanel` with `[.nonactivatingPanel, .borderless]` and `canBecomeKeyWindow = true`; `makeKeyAndOrderFront` for keyboard input; dismiss on `resignKey`/Escape. Positioned near the caret via `FocusProbe.focusedCaretRect()` + `HUDPlacement.underCaret` (pattern: RecordingHUDController.swift:50-66).

**Rationale**: A non-activating key panel receives keys while the owning app never activates, so `NSWorkspace.frontmostApplication` still names the target app and `FocusGuard.targetUnchanged` (InjectionPlan.swift:63) passes at injection with no restore dance. Decisive argument against tap-based key consumption: if the CGEventTap is disabled under load (a real, self-healed failure mode — HotkeyManager.swift:112-115), pressed keys leak into the target app — a stray Return in a terminal executes. With the panel, a mis-key lands harmlessly in our UI. Mouse clicks work on non-activating panels either way.

**Risk control**: Phase-2 spike validates key routing + frontmost stability + AX focused-element stability on macOS 26 before overlay build-out. Documented fallback: non-key panel + keys consumed via the proven HotkeyManager tap path.

**Spike result (2026-07-16)**: implemented per design — `NSPanel(.nonactivatingPanel)` overriding `canBecomeKeyWindow`, `makeKeyAndOrderFront` on show, `orderOut` + settle delay before injection so AX focus returns to the target. AppKit documents that a nonactivating panel receives key status without activating its owning app, so `NSWorkspace.frontmostApplication` (what `FocusGuard` compares) keeps naming the target. One consequence handled in code: while the panel is key, the system-wide AX focused element is the panel, so injection preflight runs only AFTER the panel is dismissed. Runtime keyboard-routing validation is part of the T041 manual QA matrix (this implementation session was headless); the event-tap fallback remains documented if QA falsifies the design.

## R4 — One JSON-array generation at temperature 0, not N sampled runs

**Decision**: Single generation asking for a JSON array of 3–4 materially-different single-line options; `SuggestionResponseParser` extracts the first `[`…last `]`, decodes, then falls back to a bullet/numbered-line salvage pass; hard validation (1–4 items, 1–160 chars, single-line, deduped).

**Rationale**: N sampled runs at temp>0 multiply latency 3–4× on a 4B local model and still converge to near-duplicates. Temp 0 maximizes JSON adherence on Qwen3-4B and matches house style (MLXTextCleaner.swift:100). Worst case is an honest "no suggestions" error state — never malformed injection.

## R5 — This is a flow, not a `Mode`

**Decision**: No `ModeRegistry` entry, no `AppModeResolver` involvement. Suggested Responses is a parallel flow like hands-free, with its own hotkey, session state machine, and UI.

**Rationale**: Modes shape transcript→text transformation. Adding a pseudo-mode would pollute the mode picker and per-app mode mapping with something that isn't selectable per-dictation.

## R6 — Auto-submit as a separate post-injection step

**Decision**: `ReturnKeySynthesizer` (BarkEngines) is the sole Return-posting site, called by `SuggestionController` only when `AutoSubmitPolicy` approves: setting ON ∧ a *selected* suggestion inserted successfully ∧ preflight re-passed (focus + secure field, after insertion, before keypress) ∧ ~150 ms settle delay. Not an `InjectionPlan` flag.

**Rationale**: The `TextInjector` contract ("never posts Return", TextInjector.swift:8; PasteboardInjector.swift:86) stays byte-identical; the ADR-010/SEC-005 exception is confined to one auditable file. Terminals deliberately allowed — the coding-agent scenario is the point; the user read and chose the exact string (per-use consent).

## R7 — Context is ephemeral and prompt-fenced

**Decision**: `CapturedContext` never touches disk, logs (lengths only), or history. Accepted suggestions are recorded in history as `transcript: ""`, `output: <suggestion>`, `modeID: "suggestion"` — recallable without persisting screen content. All context + history snippets enter the prompt fenced and tag-neutralized (`SuggestionPrompt`, mirroring `PromptTemplate`'s OWASP LLM01 posture, PromptTemplate.swift:35-48).

## R8 — External backend fails toward local, never the reverse

**Decision**: Endpoint unreachable/401/malformed → one retry on the local engine if enabled+available; otherwise a typed error in the overlay ("Check endpoint in Settings"). Local failure never silently escalates to the network.

**Rationale**: Failing *toward* privacy is the only direction consistent with Principle I even post-amendment.

## R9 — "Other" = one-shot hands-free

**Decision**: Dismiss panel → `dictation.startHandsFree()`; `BarkApp`'s `onPhaseChange` multiplex forwards phases to `SuggestionController`, which calls `stopHandsFree()` after the first `.completed`/`.failed` utterance.

**Rationale**: Reuses the whole VAD/finalize/inject path with zero `DictationController` changes. If UX feels off in QA, the one-line alternative is an overlay hint ("hold fn to dictate") + plain dismissal.

## R10 — Screen Recording permission: just-in-time, degradable

**Decision**: `PermissionsCoordinator` gains `.screenRecording` (`CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess`, deep link `Privacy_ScreenCapture`). No permission → OCR skipped silently; if AX was also thin, the overlay error offers the deep link. Mirrors the existing mic/AX degradation philosophy.

## R11 — ACP bridge to CLI agents: deferred

**Decision**: Out of scope for v1. The user floated "ACP to CLI (if possible)" — piping context to a local CLI coding agent (Agent Client Protocol, as used by Zed/Claude Code adapters) as a third backend.

**Assessment**: Feasible in principle (spawn agent process, JSON-RPC over stdio, session per suggestion request), but: (a) process lifecycle + auth per agent is a project in itself; (b) latency of agent cold-start defeats the ≤6 s target; (c) the OpenAI-compatible backend already covers "stronger model" — including local servers. Revisit as its own spec if demand materializes; `SuggestionEngine` is the seam a future `ACPSuggestionEngine` would implement.

## R12 — Local backend rides `llmEnabled` consent

**Decision**: The Suggestions pane requires the existing LLM toggle (model download consent, Settings.swift:81) for the local backend and links to the Models pane rather than duplicating consent UI. Lean build: local engine reports unavailable → external backend or honest unavailable state (SC-005).
