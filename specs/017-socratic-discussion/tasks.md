# Tasks: Socratic Discussion (pre-action prompt refinement)

**Input**: Design documents from `/specs/017-socratic-discussion/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: Included — the constitution's quality gates require them (pure logic unit-tested;
orchestration via injected fakes), and SC-002/SC-004/SC-005 name specific test deliverables.
Within each task: write the failing test first, then the implementation (repo TDD convention).

**Organization**: By user story. US1 = the whole dialogue→synthesis→inject loop (MVP);
US2 = TTS half-duplex; US3 = recapture + failure UX.

## Phase 1: Setup

- [X] T001 Record baseline: `swift build` clean and `swift test` green on branch
      `017-socratic-discussion` before any change (constitution II evidence; paste summary
      counts into the PR description later)

## Phase 2: Foundational (blocking prerequisites for all stories)

- [X] T002 [P] Define `DialogueRole`, `DialogueTurn`, `DialogueReply` (incl.
      `isSynthesisTrigger`), `DialogueError`, and the `DialogueEngine` protocol per
      `contracts/dialogue-engine.md` in `Sources/BarkCore/Discuss/DialogueEngine.swift`
- [X] T003 [P] Implement tolerant reply parsing (first-JSON-object extraction; fail-safe
      `ready=false` on any malformed input) in
      `Sources/BarkCore/Discuss/DialogueReplyParser.swift` with tests first in
      `Tests/BarkCoreTests/DialogueReplyParserTests.swift` (plain JSON, fenced/prose-wrapped
      JSON, empty-reply trigger shape, garbage, prompt-injection lookalikes)
- [X] T004 [P] Implement `DialoguePromptBuilder` (fixed guardrail; Socratic system prompt with
      the `{"reply","ready"}` output contract and the empty-reply-on-confirm rule; synthesis
      system prompt; fenced `<screen_context>`/`<focused_field>`/`<user_turn>` blocks with
      fixed-point `neutralize` copied from `SuggestionPrompt`) in
      `Sources/BarkCore/Discuss/DialoguePromptBuilder.swift` with tests first in
      `Tests/BarkCoreTests/DialoguePromptBuilderTests.swift` (fence-reassembly fixed point,
      context+turns assembly, no-context variant)
- [X] T005 Implement the `DiscussionSession` state machine exactly per `data-model.md`
      (states, events, transitions, invariants 2/3/5, illegal-pair no-ops) in
      `Sources/BarkCore/Discuss/DiscussionSession.swift` with tests first in
      `Tests/BarkCoreTests/DiscussionSessionTests.swift` (every legal transition,
      cancel-from-every-non-terminal, resume discards prompt, synthesis-failure counter,
      empty-transcript-final returns to `awaitingUser`)
- [X] T006 [P] Add `SpeechSynthesizing` protocol per `contracts/speech-synthesizer.md` in
      `Sources/BarkCore/Speech/SpeechSynthesizing.swift`
- [X] T007 [P] Add Settings fields `discussionEnabled=false`, `discussionHotkey` (F7/keyCode 98
      toggle), `discussionMicMode: DiscussionMicMode = .ptt`, `discussionTTSEnabled=false`
      with tolerant-decoder lines in `Sources/BarkCore/Settings/Settings.swift`; extend
      `Tests/BarkCoreTests/SettingsCodecTests.swift` (old-blob decode keeps defaults)
- [X] T008 [P] Conform `MLXTextCleaner` to `DialogueEngine` (fresh
      `ChatSession(container, instructions:, history:)` per call, maxTokens 256 reply /
      512 synthesize, temp 0; lean-build stub throws `engineUnavailable`) in
      `Sources/BarkCleanupMLX/MLXTextCleaner+Dialogue.swift`
- [X] T009 [P] Conform `OpenAICompatClient` to `DialogueEngine` (messages =
      `[system] + turns`; reuse existing wire types/session) in
      `Sources/BarkEngines/Suggest/OpenAICompatClient.swift`; extend
      `Tests/BarkAppTests/OpenAICompatClientTests.swift` (multi-turn body shape, role
      mapping, error mapping)
- [X] T010 [P] Add shared fakes `FakeDialogueEngine` (scripted replies/errors, records
      received turns) and `FakeSpeechSynthesizer` (gated `speak` suspension, `stop()`
      release, spoken log) in `Tests/BarkAppTests/Fakes.swift`
- [X] T011 Add the mic lease + 4-way hotkey guard: `micLeaseHeld` checked in
      `startDictation`/`startHandsFree` guards and the hotkey-collision checks extended to
      the discussion key in `Sources/Bark/DictationController.swift` and
      `Sources/Bark/SuggestionController.swift`; tests first in
      `Tests/BarkAppTests/DictationControllerTests.swift` additions (lease blocks both start
      paths; collision refusal both directions)

**Checkpoint**: `swift build` + `swift test` green — all seams exist, no UI yet.

## Phase 3: User Story 1 — dialogue loop → synthesis → inject (P1) 🎯 MVP

**Goal**: F7 opens a context-grounded Socratic session; voice turns refine the goal; Done or
engine readiness produces a previewed prompt; Confirm injects it safely into the origin app.

**Independent test** (spec US1): focus an editor, F7, 2–3 voice turns, Done, Confirm → prompt
lands at the cursor; nothing typed anywhere else.

- [X] T012 [US1] Create `DiscussionController` skeleton in
      `Sources/Bark/DiscussionController.swift`: injected seams (settings, dialogue engines
      local/external via factory closure, capture, audioFactory, STT factory, injectors,
      dictation controller for lease/suspend, synthesizer optional, settleDelay/deadlines),
      dedicated `HotkeyManager` (015 idiom), `handleHotkey()` → `begin()`: acquire mic lease,
      remember+suspend hands-free, snapshot `InjectionTarget`, run capture
      (`secureField` error ⇒ refuse session; other errors ⇒ contextless), dispatch session
      events, `cancel()`/teardown wipes transcript+context+prompt and releases lease,
      resuming hands-free if it was on. Flow tests first in
      `Tests/BarkAppTests/DiscussionControllerFlowTests.swift` (begin happy/refused/degraded,
      teardown wipe, lease+suspend/resume, disabled ⇒ hotkey no-op)
- [X] T013 [US1] Implement the user-turn capture loop in `DiscussionController`: PTT mode
      (key-down `beginStream`+feed, key-up `finishStream` under deadline) and VAD mode
      (mirror `runHandsFree`: preroll, onset/hangover, 30 s cap — but output = transcript
      only, no cleanup/injection); empty-final ⇒ `awaitingUser`. Tests with
      `ScriptedAudioCapture`/`ScriptedSTTEngine` in both modes
- [X] T014 [US1] Implement the engine loop in `DiscussionController`: opening question after
      capture; per-turn `reply` under 20 s deadline via prompt builder; parse via
      `DialogueReplyParser`; `isSynthesisTrigger` ⇒ synthesize; `ready=true` surfaced to UI
      state; `doneRequested` from any allowed state; `synthesize` under 30 s deadline with
      4 000-char bound + `retrySynthesis`; `engineFailed` ⇒ `turnFailed` with transcript
      retained. Tests with `FakeDialogueEngine` (scripted ready flow, trigger flow, failure,
      deadline via hanging engine)
- [X] T015 [US1] Implement preview + injection handoff in `DiscussionController`: Confirm ⇒
      settle delay → `TextSanitizer` (newlines allowed unless terminal) →
      `InjectionRouter.strategy(routing:isTerminal:)` → injector (preflight does PID
      re-verify + secure-field refusal); `injectionFailed` ⇒ back to `previewing` with
      reason + copy-to-clipboard affordance; Resume ⇒ discard prompt, continue; **no**
      `ReturnKeySynthesizing` anywhere in this file. Tests with `FakeInjector`
      (`focusChanged`, `secure`, success), no-Return assertion (fake synthesizer count
      stays 0), history store untouched
- [X] T016 [US1] Create `DiscussionOverlayController` + `DiscussionPanel` in
      `Sources/Bark/DiscussionOverlayController.swift` cloning the 015 panel pattern
      (non-activating borderless key panel; **not key during `capturing`**, key from
      `thinking` onward; `HUDPlacement.bottomCenter` + caret refine; resign-key ⇒ controller
      cancel unless self-hidden)
- [X] T017 [US1] Create `DiscussionOverlayView` in
      `Sources/Bark/UI/DiscussionOverlayView.swift`: scrolling transcript, prominent current
      AI question, state/"no context" indicators, Done/Cancel buttons, ready-highlighted
      Done, preview pane with Confirm/Resume/Cancel + failure reason + Copy prompt; key
      handling decoder in `Sources/BarkCore/Discuss/DiscussionKeyDecoder.swift` (Esc=cancel,
      Return=Confirm **only inside preview**, D=Done) with tests in
      `Tests/BarkCoreTests/DiscussionKeyDecoderTests.swift`
- [X] T018 [US1] Create the settings pane in
      `Sources/Bark/UI/Settings/DiscussionPane.swift` (enable, hotkey recorder, mic mode,
      TTS toggle, shared-backend note + strengthened ADR-010 privacy copy naming multi-turn
      transcripts) and add the `discussion` case to `Sources/Bark/UI/SettingsView.swift`;
      controller-side computed settings vars with collision-guard refusals in
      `DiscussionController`
- [X] T019 [US1] Wire production graph in `Sources/Bark/CompositionRoot.swift`
      (fourth `HotkeyManager`, local engine = `dictation.llmCleaner as? DialogueEngine`,
      external factory closure, `ContextCaptureService`, injectors, synthesizer) and
      activate + phase-multiplex in `Sources/Bark/BarkApp.swift`
- [X] T020 [US1] US1 checkpoint: end-to-end flow tests green in both mic modes
      (`DiscussionControllerFlowTests`), full `swift build` + `swift test` output captured,
      and existing 015/016/dictation suites unchanged (SC-003)

**Checkpoint**: US1 alone is a shippable, text-only discussion feature.

## Phase 4: User Story 2 — spoken replies without self-transcription (P2)

**Goal**: TTS reads AI replies; the mic is provably never open while speech plays; key-tap
skips playback.

**Independent test** (spec US2): TTS + hands-free, 3-turn session by the speakers → zero
AI-spoken words in user turns.

- [X] T021 [P] [US2] Implement `AVSpeechSynthesizerEngine`
      (delegate didFinish/didCancel → `CheckedContinuation`; system voice; `stop()`
      idempotent; failure ⇒ prompt return, log only) in
      `Sources/BarkEngines/Speech/AVSpeechSynthesizerEngine.swift`
- [X] T022 [US2] Wire TTS gating into `DiscussionController`: after presenting text, `await
      speak(reply)` when enabled, then dispatch `presentationFinished`; key-tap during
      playback ⇒ `stop()` (skip) and open the turn; mic arming allowed **only** in
      `awaitingUser`/`listening` (data-model invariant 1). Tests first: gated
      `FakeSpeechSynthesizer` proves no audio-capture start occurs while `speak` is
      suspended (SC-002), skip releases immediately, TTS-off path dispatches
      `presentationFinished` synchronously
- [X] T023 [US2] TTS degrade test in `DiscussionControllerFlowTests`: synthesizer that
      returns instantly (simulated failure) ⇒ session proceeds text-only, no error surfaced
      (US2/AS3)

**Checkpoint**: US1 + US2 = full spoken experience.

## Phase 5: User Story 3 — recapture + graceful engine failure (P3)

**Goal**: Mid-session context refresh; engine failures never lose the transcript.

**Independent test** (spec US3): change target window content, Recapture, "what do you see
now?" → grounded reply. Kill engine mid-session → retry/Done offered, transcript intact.

- [X] T024 [US3] Implement Recapture: overlay button (allowed in
      `awaitingUser`/`presenting`/`turnFailed`) → re-run capture against the session target,
      **replace** the snapshot on success, keep the previous snapshot with a notice on
      failure; subsequent prompts rebuild from the new snapshot (stateless per-turn build
      makes this free). Tests: `FakeContextCapture` swap changes the context block in the
      next `FakeDialogueEngine`-received prompt; failed recapture retains prior context
- [X] T025 [US3] Implement failure affordances end-to-end: `turnFailed` UI (Retry / Done /
      Cancel), `synthesisFailed` retry, second synthesis failure ⇒ "Copy transcript"
      (clipboard via `ClipboardInjector`, secure-field-guarded), injection-failure preview
      copy path. Tests: transcript-never-lost across every failure path (SC-004), twice-failed
      synthesis offers and performs the copy

**Checkpoint**: all three stories complete.

## Phase 6: Polish & cross-cutting

- [X] T026 [P] Lean-build verification: `cp Package-lean.swift Package.swift && swift build`
      — feature compiles to a disabled stub (engine unavailable ⇒ settings pane hides/greys
      the feature); restore manifest
- [X] T027 [P] Docs: README feature section (usage + honest limits), `docs/ADRs.md` entry
      (ADR-011: discussion privacy posture — memory-only transcript, shared external-endpoint
      opt-in, mic lease, no auto-submit), `docs/SECURITY.md` note (new surface: TTS output,
      discussion transcript lifecycle, unchanged injection controls)
- [X] T028 Final gate: `swift build` clean + full `swift test` green with output captured;
      tick all quickstart automated items; update spec Status → Implemented

## Dependencies & execution order

- Phase 2 blocks everything; within it T002 → (T003, T004, T005, T008, T009, T010) and
  T006/T007/T011 are independent of T002.
- US1 (T012→T020, sequential except T016/T017/T018 can proceed in parallel after T014).
- US2 needs US1's controller loop (T022 depends on T013/T014); T021 is independent [P].
- US3 needs US1 (T024 depends on T012/T014; T025 depends on T014/T015).
- Polish last.

Parallel opportunities: T002–T011 form two independent tracks (core types/tests vs
settings/conformers/fakes); T016+T017+T018 (UI) parallel to each other; T021 parallel to all
of US1; T026+T027 parallel.

## Implementation strategy

MVP = Phase 1–3 (US1): shippable text-only discussion. Then US2 (TTS), then US3 (robustness),
then polish. Each checkpoint runs the full suite; existing suites must stay green throughout
(SC-003).
