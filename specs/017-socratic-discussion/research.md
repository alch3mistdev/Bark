# Phase 0 Research: Socratic Discussion (017)

All decisions below are grounded in the current codebase (file:line refs verified 2026-09-13).

## R1 — Multi-turn engine seam

**Decision**: New `DialogueEngine` protocol in `BarkCore/Discuss/` with a message-array request
(`[DialogueTurn]`), separate from `SuggestionEngine`.

**Rationale**: `SuggestionRequest` is a flat `{system, user}` pair
(`SuggestionEngine.swift:20–30`) — no multi-turn shape exists in BarkCore. Both concrete
backends already support message arrays natively: MLX's `ChatSession` accepts
`history: [Chat.Message]` (`mlx-swift-lm ChatSession.swift:109`), and `OpenAICompatClient`'s
wire type is already `messages: [Message]` (`OpenAICompatClient.swift:44–52`). Extending
`SuggestionRequest` would force a migration on a shipped protocol; a sibling protocol keeps
015/016 untouched (constitution III).

**Alternatives considered**: (a) widen `SuggestionRequest` with an optional `history` field —
rejected: churns a shipped seam, defaulted-protocol tricks hide the semantic difference.
(b) One generic "conversation" protocol replacing both — rejected as the approach-C refactor
already declined during brainstorming (YAGNI).

## R2 — MLX conformance: stateless rebuild per turn

**Decision**: `MLXTextCleaner+Dialogue.swift` builds a fresh
`ChatSession(container, instructions: system, history: turns)` per `reply` call and generates
one bounded response. No long-lived session object.

**Rationale**: `ChatSession` supports both a stateful KV-cache accumulation and prompt
re-hydration from `history` (`ChatSession.swift:109, 337–400, 493`). Stateless rebuild is
deterministic, trivially testable, and makes **Recapture** free (context lives in the system
prompt / first message; a new snapshot just changes the rebuilt prompt). Prefill of a few-KB
prompt on M3 Pro is far cheaper than decode; per-turn latency stays dominated by generation.
`MLXTextCleaner.container` is `internal` precisely so extensions share the single model
residency (`MLXTextCleaner.swift:25–27`) — same pattern as `+Suggest`.

**Alternatives considered**: long-lived `ChatSession` per discussion (cheapest prefill) —
rejected: stateful object complicates recapture (system prompt change forces rebuild anyway),
cancellation, and test isolation.

## R3 — Readiness signal: structured JSON reply

**Decision**: The dialogue system prompt instructs the model to answer **only** with
`{"reply": "<question or statement>", "ready": <bool>}`. A tolerant `DialogueReplyParser`
extracts the pair; any parse failure degrades to `reply = full text, ready = false`.

**Rationale**: FR-003 forbids free text driving control flow. 015 set the precedent of a JSON
output contract + tolerant parser (`SuggestionPrompt.system(maxCandidates:)`,
`SuggestionResponseParser`). Fail-safe direction matters: a malformed reply must never *force*
synthesis, so the degrade is `ready = false`.

**Alternatives considered**: sentinel token (`[READY]`) — rejected: collides with natural text,
no fail-safe parse story. Tool/function calling — not supported uniformly across both backends.

## R4 — User-turn STT: own loop over existing protocol seams

**Decision**: `DiscussionController` runs its own turn capture over the injected seams
`audioFactory: () -> AudioCapturing` + `STTEngine` + `VoiceActivityDetector` — mirroring
`DictationController.runHandsFree` (`DictationController.swift:1185–1308`) but stopping at the
final transcript (no cleanup, no injection). PTT mode skips the VAD: key-down starts
`beginStream`/feed, key-up calls `finishStream` under `withThrowingDeadline`.

**Rationale**: There is no "run one STT turn" public API on `DictationController`, and 015's
one-shot trick (`startHandsFree()` + phase latch, `SuggestionController.swift:433–474`)
injects the utterance through the dictation pipeline — wrong for a discussion turn, which must
land in the transcript, not the target app. The STT protocol
(`STTEngine.swift:34–50`: `beginStream/feed/finishStream/cancel`) supports an independent
consumer cleanly, and `ScriptedSTTEngine`/`ScriptedAudioCapture` fakes already exist for
multi-turn tests (`Fakes.swift:99, 212`).

**Alternatives considered**: add a "capture-only mode" flag to `DictationController` —
rejected: grows the largest controller in the app with a mode that changes its output contract;
the discussion loop's turn-taking (half-duplex gating, TTS skip) doesn't map onto dictation
phases anyway.

## R5 — Mic exclusivity: explicit lease on DictationController

**Decision**: Add a minimal interlock: `DictationController.micLeaseHeld: Bool` (internal,
MainActor). `startDictation` and `startHandsFree` extend their existing guards with
`!micLeaseHeld`; `DiscussionController` sets it for the session lifetime, and suspends/resumes
hands-free around the session (`stopHandsFree()` on start if active + remember; conditional
`startHandsFree()` on end).

**Rationale**: Mic exclusivity today is advisory reads only
(`DictationController.swift:588, 1152`; `SuggestionController.swift:192`) — nothing stops a
second controller opening its own `AudioCaptureEngine`. The spec's edge cases (discussion owns
the mic; F5 suspended and resumed) need a real interlock. A one-flag lease is the smallest
seam that makes the guarantee testable; a global mic-arbiter actor is over-design for two
parties.

**Alternatives considered**: shared arbiter actor over `audioFactory` — rejected (YAGNI, three
call sites); relying on advisory reads — rejected (race, untestable guarantee).

## R6 — TTS: `SpeechSynthesizing` protocol + `AVSpeechSynthesizerEngine`

**Decision**: Protocol in BarkCore (`speak(_ text: String) async` — returns when playback
finishes or is stopped; `stop()`), conformer in BarkEngines wrapping `AVSpeechSynthesizer`
with a delegate → `CheckedContinuation` bridge; system default voice; no voice picker in v1.

**Rationale**: Repo has zero TTS today (grep-verified; only `NSSound` cues in `Feedback.swift`).
AVFoundation is already linked. An async-completion `speak` makes the half-duplex invariant
enforceable in one place: the turn loop simply does not re-arm the mic until `speak` returns
(or `stop()` is called by the key-tap skip). `AVSpeechSynthesizer` is on-device (constitution I;
macOS 26 always has at least one installed voice).

**Alternatives considered**: `NSSpeechSynthesizer` — legacy, deprecated posture;
delegate/callback surface instead of async — pushes gating complexity into the controller.

## R7 — Hotkey: fourth `HotkeyManager`, 4-way collision guard

**Decision**: Dedicated `HotkeyManager` instance for the discussion key (repo pattern: one
instance = one `CGEventTap`, `CompositionRoot.swift:21, 35–36`), default **F7 / keyCode 98**
(`Settings.swift:65`), `keyToggle` trigger with both `onStart`/`onStop` → `handleHotkey()`
(the 015 idiom, `SuggestionController.swift:166–177`), tap started only when the feature is
enabled. Collision guards extended from 3-way to 4-way at all sites:
`SuggestionController.swift:99–103, 117–122`, `DictationController.swift:1045–1052`, plus the
new symmetric guards in `DiscussionController`.

**Rationale**: established pattern; consumed keystrokes never reach the focused app.

## R8 — Engine/back-end selection: share the 015 configuration

**Decision**: Discussion uses the *same* backend selection and external-endpoint configuration
as suggestions: `Settings.suggestionBackend`, `externalLLMEndpoint`, `externalLLMModel`,
Keychain key `"external-llm-key"`. `OpenAICompatClient` gains a `DialogueEngine` conformance
(new method, same wire types — `messages` is already an array). The Discussion settings pane
repeats the ADR-010 privacy warning with strengthened copy (multi-turn transcripts).

**Rationale**: FR-012 says "reuse the 015 seam". One external-endpoint config for the app
avoids duplicate credentials handling (Keychain account, warning flows). Failing toward local
is *not* silent (spec edge case: explicit retry/Done degradation, no silent backend switch) —
consistent with constitution I ("failing toward the local engine" governs *transmission*, and
nothing is transmitted on failure).

**Alternatives considered**: per-feature backend fields — rejected: duplicate credential + UI
surface with no user story behind it.

## R9 — Overlay: clone the 015 panel pattern

**Decision**: `DiscussionPanel: NSPanel` modeled on `SuggestionPanel`
(`SuggestionOverlayController.swift:107–174`): `.nonactivatingPanel + .borderless`, floating,
all-spaces, `canBecomeKey = true`, `canBecomeMain = false`. Phase-dependent key-taking:
capture runs **before** the panel takes key (so the AX focused element and secure-field checks
still describe the target app), then the panel becomes key for the session. Placement:
`HUDPlacement.bottomCenter` immediate, caret-refined via `FocusProbe.focusedCaretRect()`.

**Rationale**: this is precisely the mechanism that lets Bark read keys while the target app
stays frontmost (`NSWorkspace.frontmostApplication` still names the target — required for the
Confirm-time PID re-verify).

## R10 — Injection & safety reuse

**Decision**: Confirm-time handoff copies the 015 injection sequence exactly
(`SuggestionController.injectChosen`, `:478–510`): settle delay → `TextSanitizer.sanitize`
(newlines allowed unless terminal) → `InjectionRouter.strategy(routing:isTerminal:)` →
`InjectionPlan` → injector. Preflight (PID re-verify via `FocusGuard.targetUnchanged` +
`SecureFieldPolicy.decide`) lives inside every injector (`PasteboardInjector.swift:6–24`) and
is inherited unchanged. `ReturnKeySynthesizing` is **not** wired into the discussion path at
all — no auto-submit exists (spec FR-007).

Session-start secure-field refusal (FR-013): `ContextCaptureService.capture` already throws
`ContextCaptureError.secureField` before any content is read
(`ContextCaptureService.swift:40–85`); `DiscussionController` treats that error as
session-refused, while other capture errors degrade to a contextless session.

## R11 — Prompt fencing

**Decision**: `DialoguePromptBuilder` follows `SuggestionPrompt` exactly
(`SuggestionPrompt.swift:9–84`): fixed non-editable guardrail; tagged blocks
(`<screen_context>`, `<focused_field>` reused; new `<user_turn>` per user message); fixed-point
`neutralize` applied to captured context **and every user speech turn**; documented as the only
path by which discussion content reaches an engine.

## R12 — Settings fields

**Decision**: Four new fields in the flat `Settings` struct (tolerant-decoder pattern,
`Settings.swift:164–193`): `discussionEnabled` (default `false`), `discussionHotkey` (default
F7 / keyCode 98 toggle), `discussionMicMode` (`ptt | handsFree`, default `ptt` — zero false
triggers out of the box), `discussionTTSEnabled` (default `false`). No history writes at all
for discussions (FR-010) — stronger than 015's empty-transcript records: nothing is recorded.
