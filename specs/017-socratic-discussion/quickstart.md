# Quickstart: Socratic Discussion (017)

## Build & automated validation

```bash
swift build            # must be clean (MLX build: first compile is slow)
swift test             # all suites green, incl. new Discussion* tests
```

Lean-build check (feature must compile out to a disabled stub):

```bash
cp Package-lean.swift Package.swift && swift build && git checkout Package.swift
```

What the new automated tests prove (see plan/tasks for file names):

- `BarkCoreTests`: every `DiscussionSession` transition (incl. cancel-from-everywhere,
  resume-from-preview, synthesis-failure counting); prompt fencing to a fixed point; tolerant
  reply parsing with fail-safe `ready=false`.
- `BarkAppTests`: full happy loop in both mic modes with scripted audio/STT; **half-duplex
  invariant** (mic never armed while fake TTS is mid-`speak` or engine mid-reply); engine
  failure → retry/Done with transcript intact; twice-failed synthesis → clipboard offer;
  PID-mismatch refusal at Confirm; secure-field refusal at start; hands-free suspend/resume
  around a session; 4-way hotkey collision guard.

## Manual validation (installed .app, TCC granted)

Prereqs: Settings ▸ Discussion → enable; model downloaded (LLM modes working); pick mic mode.

1. **Happy path (PTT)**: focus TextEdit, press F7 → overlay opens with a context-grounded
   opening question. Hold fn, answer, release; repeat 2–3 turns. Press Done → preview →
   Confirm → the prompt lands at the TextEdit cursor. Expected: no Return typed, clipboard
   restored.
2. **Hands-free + TTS**: enable both. Run a session near speakers — the transcript must never
   contain the AI's spoken words (half-duplex). Tap fn during speech → playback stops, your
   turn opens.
3. **Readiness flow**: converge quickly ("I want X, constraint Y") until the AI asks to draft;
   answer "yes" → synthesis without touching Done.
4. **Recapture**: mid-session, change the target window's visible content, press Recapture,
   ask "what changed?" → reply references new content.
5. **Refusals**: start over a password field → session refused. Switch apps before Confirm →
   injection refused, prompt still copyable.
6. **Failure degrade**: select external backend with a dead endpoint → turn fails with
   Retry/Done offered; transcript survives.
7. **Regression sweep**: ordinary dictation, hold-to-refine, hands-free (F5), and suggestions
   (015/016) all behave exactly as before; F5 auto-resumes after a discussion ends if it was
   on before.
