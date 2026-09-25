# Bark — Security & Privacy

Threat model from the design phase (ef-security, STRIDE). Below: the controls and where they live in
code. Items marked ☐ are designed-but-not-yet-implemented (tracked for the next sections).

## Offline guarantee
- ☑ No networking code anywhere in the app at runtime. The only network events are the OS installing the
  SpeechAnalyzer locale asset on first use (`AssetInventory`, `SpeechAnalyzerEngine.prepare`) and
  user-initiated model downloads for the optional WhisperKit / Parakeet backends
  (`ModelDownloader.ensureModel`).
- ☑ No analytics / telemetry / crash-reporting SDKs. `BarkLog` never logs transcript or audio content.
- ☑ Downloaded model bundles (WhisperKit / Parakeet) are SHA-256 verified against a bundled
  `ModelManifest` before they're allowed into the cache. Hash mismatch → file is deleted, never written
  to the cache path, and an error is surfaced to the UI (`ModelDownloader.ensureModel`,
  `ModelManifest`). Manifests themselves live in the app bundle and are not fetched at runtime
  (`SEC-003 / T-010`). HTTPS-only enforced at the downloader; non-HTTPS manifests are rejected with
  `ModelError.insecureURL`. Manifest signing (detached ed25519 verified against a baked-in pubkey) is
  the next hardening step — tracked but not yet implemented.

## Microphone privacy
- ☑ Mic opened only during active dictation; `AVAudioEngine` fully torn down on `stop()`
  (`AudioCaptureEngine.stop`). No always-listening mode. (T-002 / T-012)
- ☑ Persistent in-app state (menu-bar icon reflects `listening`), plus the macOS orange indicator.

## Voiceprint / speaker gate  (`BarkCore/Speaker/*`, `BarkEngines/Speaker/*`, ADR-009, `specs/011-voice-fingerprinting/`)
- ☑ Opt-in and **off by default** (`Settings.speakerGateEnabled`); with it off, behavior is identical to
  today. Hands-free only — push-to-talk is never gated.
- ☑ The voiceprint (`SpeakerProfile`: a 256-d centroid + metadata, **no raw enrollment audio**) is
  encrypted at rest with AES-256-GCM; the key lives in the Keychain
  (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`) under a **distinct** service `com.bark.speaker`, so
  deleting the voiceprint and purging history are independent. Ciphertext file is `0600`,
  `.completeFileProtection`, excluded from backups (`EncryptedSpeakerProfileStore`, clones
  `EncryptedHistoryStore`).
- ☑ The voiceprint **never leaves the device**. Enrollment and matching run on-device; the only network
  event is the user-initiated, SHA-256-verified embedding-model download via the existing
  `ModelDownloader` (never FluidAudio's unverified `downloadIfNeeded` on a release path).
- ☑ Delete removes both the ciphertext and the Keychain key (`deleteVoiceprint`). An unreadable/corrupt
  or wrong-key file degrades to "not enrolled" (backed up to `speaker.enc.corrupt`, never crashes).
- ☑ A profile whose `modelID` ≠ the running embedder's is treated as **not enrolled** (prompt re-enroll),
  never silently mis-scored across incompatible vector spaces.
- ☑ The gate only **suppresses** injection; it never injects more, synthesizes keys, or relaxes the
  secure-field / sanitization rules. It **fails open** (disabled / not enrolled / model-incompatible /
  too-short / embedder error → inject as normal), so a gate fault can never lock the user out of their
  own dictation (FR-009 / SC-006).
- **Honest residual (constitution IV — never overclaim a control).** This is a **convenience
  multi-speaker filter, NOT a security control**: it reliably rejects *other* people, but a recording,
  replay, imitation, or TTS clone of the *user's own* voice produces a near-identical embedding and is
  **accepted**. It is **not** authentication, liveness, or anti-spoofing (out of scope for v1). In-app +
  README copy state these limits plainly (FR-011 / SC-007).

## Text-injection safety  (`BarkEngines/Inject/*`, `BarkCore/Inject/*`)
- ☑ Refuse injection when Secure Event Input is held **by the target app** (holder pid from the
  IORegistry `IOConsoleUsers` record; an unreadable holder still refuses) or the focused AX element is
  `AXSecureTextField` (`SecureFieldPolicy` + `SecureFieldDetector`). (SEC-002 / T-005) — **best-effort**,
  see L-2. The raw system-wide flag is not used: `loginwindow` keeps it on after some unlocks, which
  refused everything.
- ☑ Re-verify the focused app (PID) is unchanged immediately before injecting (`FocusGuard` +
  `FocusProbe`); abort on mismatch. (SEC-004 / T-004) — **app-level**, see L-1.
- ☑ Never synthesize Return/Enter; strip trailing newlines; for terminals, strip all newlines and use
  keystroke injection. (`TextSanitizer`, `KeystrokeInjector`, `TerminalDetector`) (SEC-005 / T-006)
- ☑ Sanitize C0/C1 controls, ANSI escapes, zero-width and bidi characters before injection.
  (`TextSanitizer`) (SEC-011 / T-014)
- ☑ Full-pasteboard snapshot + restore with a `changeCount` guard; injected payload marked
  `org.nspasteboard.ConcealedType`. (`PasteboardInjector`) (ARCH-001 / SEC-007 / T-007)

## Prompt-injection / LLM output  (`BarkCore/Cleanup/*`)
- ☑ Dictation is fenced as untrusted data inside `<transcript>` with an explicit guardrail; injected
  close-tags are neutralized (`PromptTemplate`). (AIML-002 / SEC-010)
- ☑ LLM output is length-bounded (`OutputValidator`) and passes the same injection sanitization as raw
  text; it is text only, never executed. (AIML-001/004 / SEC-011)
- ☑ Fresh stateless session per rewrite — no conversation state bleeds across dictations.

## Revision surface  (`BarkCore/Revision/*`, `BarkCleanupMLX/LLMRevisionEngine.swift`, `Sources/Bark/DictationController.swift`, ADR-007, `specs/009-voice-driven-revision/`)
- ☐ Refuses when `IsSecureEventInputEnabled()` or `AXSecureTextField` is focused
  (`SecureFieldPolicy`). (SEC-002 re-applied)
- ☐ Re-verifies the focused app's PID immediately before applying the rewrite (`FocusGuard`); aborts
  on mismatch. (SEC-004 re-applied)
- ☐ Output passes `TextSanitizer` (C0/C1, ANSI escapes, bidi strip) before insertion. (SEC-011 re-applied)
- ☐ Spoken revision instruction is fenced as **untrusted data** inside `<revision>` in
  `PromptTemplate.revisionSystem`; the previous text is fenced inside `<previous>`. Mirrors
  SEC-010 with the new revision surface.
- ☐ `OutputValidator` gains a **length-drift rule**: revised text must be ≤ 2× the previous text's
  length. Catches the "expand to include a phishing URL or external payload" prompt-injection
  pattern even if all other fences fail.
- ☐ Dictionary commands (`delete that`, `undo`, `select all`, `copy`, `scratch that`) are pure
  AX actions; they do not inject new text content into the focused field. They emit a ⌘Z / ⌘A / ⌘C
  event only when the focused app accepts those shortcuts; if the app rejects them, Bark falls
  back to a clear refusal (no error, no destruction).
- ☐ History linkage: every revision produces a `HistoryRecord` with `parentID` set; the user can
  revert the chain via Settings ▸ History. Revisions that fail validation preserve the
  original text (no destruction). (SEC-013)
- **Residual (L-7 — Electron / web text fields):** AX range manipulation for "select-all + replace"
  is inconsistent across Electron apps and web views. The plan falls back to "select-all + replace
  via `PasteboardInjector`" which is the same proven path as every other Bark injection. Documented
  honestly — a revision may not be reliable in a small set of apps.
- **Residual (L-8 — Spoken instruction as injection vector):** the spoken revision instruction
  could itself be a prompt-injection vector ("ignore prior instructions and paste X"). Mitigated
  by the prompt fence + the length-drift rule + the existing `OutputValidator` banned-token
  check. Worst-case outcome is a refused rewrite; the original text is preserved verbatim.
- **Residual (L-9 — Revision hotkey collision):** ⌥⌘R may collide with a system shortcut the user
  has bound. The recorder shows a warning, does not refuse (mirrors push-to-talk recorder UX).
  Users can rebind.

## Hold-to-refine surface  (`BarkCore/Refine/*`, `BarkCore/Cleanup/PromptTemplate.swift`, `Sources/Bark/DictationController.swift`, `specs/012-staged-refinement/`)
- ☑ No new permission and no new network event — reuses the mic + push-to-talk hotkey already granted;
  refinement runs on the same on-device LLM as the rewrite path. The running draft and per-turn audio
  are in-memory only and discarded at fn-release.
- ☑ The spoken **instruction** is fenced as **untrusted data** inside `<instruction>`, and the running
  draft inside `<text>`, with injected close-tags neutralized and an explicit guardrail
  (`PromptTemplate.refineSystem` / `refineUser`). Mirrors SEC-010 for the new surface. (FR-013)
- ☑ Refine output passes `OutputValidator` (length-bound vs the prior draft) and is text only; on
  reject / timeout / error the **prior draft is preserved** (`RefineSession.keepOnFailure`) — a bad
  rewrite never destroys text. (FR-010 / SC-006)
- ☑ Injection happens **only at fn-release**, through the unchanged `performInjection` path: secure-field
  refusal, focus-guard PID re-check, `TextSanitizer`, never Return/Enter. Intermediate drafts and the
  empty-tap **undo** never inject. (FR-006 / FR-014)
- ☑ Fresh stateless LLM session per turn — no conversation state bleeds across turns or dictations.
- ☑ Gated behind an opt-in setting + LLM availability; the lean build and toggle-off collapse to the
  unchanged base path (fail-open). (FR-011 / FR-017)
- **Residual (L-8 — Spoken instruction as injection vector):** as with the revision surface, the
  instruction could attempt prompt injection. Mitigated by the fence + `OutputValidator`; worst case is
  a refused rewrite with the prior draft preserved.
- **Residual (left-option keycode delivery):** left-vs-right option (keycode 58 vs 61) is read from the
  `.flagsChanged` event — runtime OS behavior that can't be unit-tested; the pure `RefineKeyDecoder` is
  the tested evidence and right-option never triggers a refine.
- **Residual (audio during a slow in-flight refine):** while a rewrite is being applied the capture loop
  is suspended and mic audio buffers (bounded, newest-kept ~6 s). A rewrite approaching the 8 s deadline
  can drop the earliest buffered audio spoken during it. Not a safety issue (no injection, no leak); the
  HUD shows "Refining…" to cue the user to wait, and decoupling segment capture from the LLM call is a
  planned follow-up. (ADV-003)

## Suggested-responses surface  (`BarkCore/Suggest/*`, `BarkCore/Context/*`, `BarkEngines/Context/*`, `BarkEngines/Suggest/*`, `Sources/Bark/Suggestion*`, ADR-010, `specs/015-suggested-responses/`)
- ☑ **Off by default** (`Settings.suggestionsEnabled == false`); nothing captures until the user opts in.
- ☑ **Capture refuses secure fields before any read** (Secure Input + focused-role check in
  `ContextCaptureService`), and the AX walk itself never collects `AXSecureTextField` values
  (`AXContextReader`). (SEC-002 re-applied)
- ☑ **Captured context is ephemeral**: memory only, never persisted, never logged (timings only), never
  written to history. Accepted suggestions are recorded with an **empty transcript** and the suggestion
  text only. (constitution v2.0.0 Principle I)
- ☑ **Prompt-injection defense re-applied**: screen text, field metadata, and history snippets are
  fenced (`<screen_context>`/`<focused_field>`/`<history_snippets>`) with all tag literals neutralized;
  a fixed guardrail orders the model to treat them as data (`SuggestionPrompt`). Mirrors SEC-010.
- ☑ **Output is hard-validated before it can be picked**: JSON/bullet parse, 1–4 items, single-line,
  ≤160 chars, deduplicated (`SuggestionResponseParser`); zero valid candidates → an error state, never
  injection. Chosen text then flows through the unchanged safe-injection path (sanitizer, preflight,
  clipboard restore). (SEC-004/005/011 re-applied)
- ☑ **External endpoint is an explicit opt-in** (constitution v2.0.0 / ADR-010): default backend is
  local; selecting `external` shows a warning naming exactly what is transmitted; the API key lives in
  the **Keychain** (`KeychainSecretStore`), never in the settings blob; failures fall back **toward**
  the local engine, never the reverse.
- ☑ **Auto-submit (Return) is the single sanctioned SEC-005 exception** (ADR-010): opt-in, default OFF,
  decided by the exhaustively-tested `AutoSubmitPolicy`, confined to `ReturnKeySynthesizer` (the only
  Return-posting site in the codebase), re-preflighted (focus + secure field) immediately before the
  keypress, and never fired for dictated ("Other…") replies or clipboard-only routing.
- ☑ **Screen Recording is optional and just-in-time**: gates only the OCR fallback; absent permission
  the feature degrades to AX-only. OCR frames are processed on-device (Vision) and discarded.
- **Residual (L-15 — external endpoint operator visibility):** when the user selects the external
  backend, the endpoint operator sees whatever the prompt contains (clipped screen text, field label
  and value, matched history snippets). Mitigations: default-local, explicit warning, Keychain key,
  fail-toward-local. This is user-accepted by configuration, per constitution v2.0.0.
- **Residual (L-16 — Return remapping):** a target app that rebinds Return receives a plain Return
  keypress from auto-submit; the effect in that app is best-effort. The user read and chose the exact
  inserted string (per-use consent).
- **Residual (L-17 — key-panel focus semantics):** the overlay is a non-activating key panel; while it
  is key, the system-wide AX focused element is the panel, so injection preflight runs only after the
  panel is dismissed plus a settle delay. Runtime behavior across window managers is validated in the
  015 QA matrix; the documented fallback is event-tap key consumption.
- **Residual (L-18 — OCR misreads):** recognized text can differ from what is truly on screen;
  suggestions built on it remain subject to the same output validation and are only ever inserted by an
  explicit user pick.

## Discussion surface  (`BarkCore/Discuss/*`, `BarkCore/Speech/*`, `BarkEngines/Speech/*`, `Sources/Bark/Discussion*`, ADR-011, `specs/017-socratic-discussion/`)
- ☑ **Off by default** (`Settings.discussionEnabled == false`); the F7 tap reaches other apps until the
  user opts in (the tap starts only when enabled).
- ☑ **Session start refuses secure fields** via the same capture path as 015 (`ContextCaptureError
  .secureField` ⇒ session refused, FR-013); Confirm-time injection re-runs the full preflight
  (PID re-verify + secure-field policy) inside the unchanged injectors.
- ☑ **Transcript + capture are memory-only**: never persisted, never logged (timings only), never
  written to history — stronger than 015: a discussion records **nothing**. Wiped on session end
  (FR-010).
- ☑ **Prompt-injection defense re-applied**: screen context uses the 015 fences; every user utterance
  is fenced in `<user_turn>` blocks with fixed-point tag neutralization (`DialoguePromptBuilder`);
  the readiness signal is a parsed JSON flag whose malformed degrade is `ready=false`, so hostile
  screen/speech content can neither steer the system prompt nor force synthesis (FR-003/FR-011).
- ☑ **Mic exclusivity is a hard interlock**: `DictationController.micLeaseHeld` makes both dictation
  start paths refuse while a session runs; hands-free is suspended and auto-resumed. **Half-duplex is
  tested**: audio capture can start only in mic-legal states, and TTS playback must complete before
  the mic re-arms (SC-002, gated-fake test). Post-adversarial hardening: mic arming is single-owner
  (generation-tokened VAD loops; a stale loop stops its own engine), the capture engine is stopped at
  the device level before transcription/generation run, PTT turns are latched synchronously against
  double-taps, and every exit from the speaking state silences TTS and invalidates its pending
  completion (ADV-001…004, ADV-010…013).
- ☑ **No Return, no auto-submit**: `ReturnKeySynthesizing` is not wired into the discussion path at
  all; the sole handoff is a previewed, user-confirmed insert through the sanitizer/router.
- ☑ **TTS is on-device** (`AVSpeechSynthesizer`); its failure degrades to text-only silently.
- ☑ **External endpoint reuses the ADR-010 opt-in** with strengthened warning copy: the entire
  multi-turn conversation plus captured screen text is transmitted per turn when selected.
- ☑ **cmux is a recognized terminal** (2026-09-15). `com.cmuxterm.app` was absent from
  `TerminalDetector`, so injection took the **paste** path: Bark's single-line keystroke guarantee
  covers only terminals it knows, and for unrecognized ones a multi-line payload depends on the
  app's own bracketed-paste handling to avoid executing lines. Discussion drafts can be
  multi-line, so this was a live path to unintended command execution. It now gets keystroke
  injection (single line) and tail-biased context clipping.
- ☑ **Chrome-only captures are refused, not presented as content** (2026-09-15). Canvas-drawn
  terminals expose a text area whose `AXValue` is empty, leaving only the app's furniture (tab
  labels, session sidebar, status bar) — several hundred characters that clear any length
  threshold. For a terminal target, `CapturedContext.isChromeOnly` now routes to OCR, and with no
  OCR available the capture fails honestly rather than handing the model a sidebar as if it were
  the screen. (Non-terminals are unaffected: a page's headings and labels genuinely are content,
  so 015 does not regress.)
- ☑ **Capture's secure-field check follows the TARGET APP, not system focus** (2026-09-15 fix).
  `AXContextReader` and the pre-read refusal now resolve the focused element via
  `AXUIElementCreateApplication(pid)` rather than `AXUIElementCreateSystemWide()`. The old
  system-wide read described whichever element held key focus — during a discussion session that
  is Bark's own overlay panel, so a mid-session Recapture could both read the wrong app's field
  metadata and miss a password field that had gained focus in the target since session start.
  Effectiveness is OS-adapter behavior that cannot be unit-tested; what IS tested is that the
  refusal seam receives the capture target (`ContextCaptureServiceTests`).
- **Residual (L-19 — readiness contract):** the empty-reply synthesis trigger depends on the model
  honoring the JSON contract; a model that never emits it simply never auto-drafts (the Done button is
  the guaranteed path). No safety property depends on the model complying.
- **Residual (L-20 — spoken content is audible):** TTS reads AI questions aloud; in shared spaces that
  may disclose the discussion's topic. Off by default; the overlay always shows the same text.
- **Residual (L-21 — speaker gate not applied, ADV-007):** the 011 voice gate does not filter
  discussion turns — in hands-free mode any audible voice can take a turn and (with the external
  backend) its words are transmitted per turn without preview. The Discuss pane states this
  explicitly; gate integration is future work.
- **Residual (L-22 — second STT residency):** the discussion runs its own `STTEngine` instance
  (mic-lease-serialized against dictation's); with a downloaded backend that is a second model
  residency, loaded at first session and held until quit.

### Cloud TTS egress  (`BarkCore/Speech/CloudTTSRequest.swift`, `BarkEngines/Speech/{ElevenLabsSynthesizer,FallbackSpeechSynthesizer}.swift`, ADR-012, `specs/018-elevenlabs-tts/`)
- ☑ **Off by default** (`Settings.discussionTTSBackend == .system`). With the on-device backend
  selected the cloud primary refuses *before* touching `URLSession`, so the speech path makes
  **zero** network requests — asserted by a stub that fails the test if invoked.
- ☑ **Fails toward the local engine, structurally**: `FallbackSpeechSynthesizer` is the speech
  path and the cloud engine's only failure action is local playback. No path escalates a cloud
  failure to further transmission; no path leaves a turn silent (constitution Principle I).
- ☑ **Half-duplex holds on the fallback path**: `speak` returns only after the *local* playback
  finishes, so the mic cannot open while either voice is talking (tested with a gated local fake
  behind a failing cloud primary).
- ☑ **Key in the Keychain** under `elevenlabs-api-key`, a distinct account from ADR-010's
  `external-llm-key` so either can be deleted independently; never in the settings payload
  (asserted by encoding settings and searching the output).
- ☑ **Bounded and ephemeral**: transmitted text capped at 2000 characters, `.ephemeral` URL
  session (no cache of reply content), audio held in memory for playback only, 10 s deadline with
  cancellation so a turn cannot hang.
- ☑ **Transmitted:** the AI's reply text only. **Never transmitted:** microphone audio, the screen
  capture itself, the discussion transcript, dictation output, history.
- **Residual (L-23 — replies can quote captured content):** the reply is *derived* from the
  capture and the user's speech and may paraphrase or quote either, so the transmitted text is not
  "Bark's own words". The settings warning says this explicitly rather than eliding it.
- **Residual (L-24 — provider retention):** transmitted text is subject to ElevenLabs' retention
  and abuse-monitoring policy, which Bark neither controls nor can attest to.
- **Residual (L-25 — deliberate trade):** a user who enables this has traded the offline guarantee
  for voice quality on this one feature. Nothing else in the app changes, and switching the
  backend back to on-device stops transmission immediately.

## Permissions — least privilege  (`Resources/Bark.entitlements`, `PermissionsCoordinator`)
- ☑ Only the microphone device entitlement. Accessibility + Input Monitoring are user-granted via TCC,
  requested just-in-time with purpose strings. (SEC-008 / T-011)
- ☑ Hardened runtime; no `get-task-allow`, no `disable-library-validation`; Library Validation on.
  (T-013) — enforced by `scripts/make-app.sh` (`--options runtime`).

## Transcript at rest  (`EncryptedHistoryStore`)
- ☑ History is **off by default** (`Settings.historyEnabled == false`); nothing is persisted unless the
  user opts in. Turning it back **off purges** the file and key (`historyEnabled` setter → `purge()`).
- ☑ When enabled: **AES-256-GCM** (CryptoKit), key in the **Keychain**
  (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, device-bound, non-syncing). File is `0600`, written
  atomically with `.completeFileProtection`, and `isExcludedFromBackup`. Retention cap via
  `RetentionPolicy`. `purge()` removes both file and key. (SEC-006 / T-008)
- Note (honest scope): the Keychain key is a **software key, not Secure-Enclave-backed**; Spotlight
  exclusion is **not** implemented. Decrypt failure is treated as empty (see L-6).

## Memory hygiene
- ☐ Zero audio/intermediate text buffers after use; disable core dumps for capture. (SEC-009 / T-003)

## Known limitations (from adversarial review — Codex GPT-5.4 + ef-adversary)

These are inherent to synthetic injection / cross-app automation, or accepted for v1. They are
documented rather than hidden:

- **L-1 — Focus guard is app-level (PID), not window/field.** A focus change to a *different window or
  field within the same app* during STT/LLM latency is not detected (`FocusGuard.targetUnchanged`
  compares PID). Cross-app switches are caught. Stable per-field AX identity across the new
  SpeechAnalyzer latency is unreliable; closing this fully would require refusing common valid use.
- **L-2 — Secure-field detection is best-effort.** `IsSecureEventInputEnabled()` is session-global (can
  cause false refusals if another app holds secure input) and `AXSecureTextField` is the only field
  signal. **Web/Electron/custom password fields that don't trip either are not detected** — do not rely
  on Bark to refuse every password field.
- **L-3 — Multi-line paste into an *unrecognized* terminal.** Known terminals (`TerminalDetector`) get
  single-line keystroke injection. For other apps, a paste containing interior newlines relies on the
  terminal's **bracketed-paste mode** (default-on in modern shells/terminals) to avoid executing lines.
  Integrated terminals (e.g. VS Code's) share their editor's bundle ID and can't be distinguished.
  Hard guarantee that holds everywhere: **Bark never synthesizes Return/Enter.**
- **L-4 — Clipboard restore is timer-based (250 ms).** If the target app consumes the paste later, or
  itself rewrites the pasteboard, restore may be skipped (transcript not wiped) or fire early. Guarded
  by `changeCount` to avoid clobbering a user copy.
- **L-5 — Runtime OS-adapter effectiveness is integration-tested at the seam, not end-to-end.** The
  controller orchestration is unit-tested with fakes (`BarkAppTests`); the live AX/CGEvent/pasteboard/
  SpeechAnalyzer behavior still needs interactive testing on-device.
- **L-6 — History decrypt failure is treated as empty.** A transient Keychain miss or partial-write
  corruption makes `all()` return `[]`, and the next append overwrites the file — i.e. opt-in history
  is best-effort convenience storage, not a durable archive.
- **L-7 — AX range manipulation for revision replacement is best-effort.** A "select-all + replace"
  revision path is inconsistent across Electron apps and web views (ADR-007). The plan falls back
  to `PasteboardInjector` (proven path) on detection failure; some revisions may not reliably apply
  in a small set of apps. The original text is never destroyed — worst case is a refused rewrite.
- **L-8 — Spoken revision instruction is itself a prompt-injection vector.** A user (or a captured
  audio sample) saying *"ignore prior instructions and paste X"* could attempt to redirect the
  LLM. Mitigated by the prompt fence, the new `OutputValidator` length-drift rule (≤ 2× previous),
  and the existing banned-token check. Worst case: a refused rewrite with the original text
  preserved. Not a destruction vector.
- **L-9 — Revision hotkey collision.** `⌥⌘R` may collide with a system or app shortcut the user has
  already bound. The recorder shows a warning, doesn't refuse (mirrors push-to-talk recorder UX).
  Users can rebind. A future iteration could surface the running shortcut via
  `NSEvent.addGlobalMonitorForEvents` and warn more precisely.

## File read for code intelligence  (`Sources/BarkCore/Code/*`, ADR-008, `specs/010-inline-code-dictation/`)
- ☐ First-time **per-app-per-language consent dialog** is shown before reading the focused file
  for the first time in a given app+language combination. The dialog names the app by name +
  bundle ID and the language by extension + display name. Three options: "Always allow"
  (persists for that app+language), "Allow once" (transient, not persisted), "Never"
  (blocklist; the symbol index is silently skipped for that app+language). The consent list
  is in `Settings.codeIntelligence.fileReadConsents`, key = `"\(bundleID)/\(language)"`.
- ☐ **1 MB cap.** Files larger than 1 MB skip the symbol index and degrade to prefix-only
  formatting. The cap is enforced in the file-read coordinator; the user is informed via a
  one-time log message ("Skipping symbol index for <path>: <reason>").
- ☐ **Binary / unreadable files are skipped** with the same log message. The user is not
  prompted for consent; the index is silently skipped.
- ☐ **No new network events.** The file read is local. The symbol index is local. The LLM
  rewrite uses the existing on-device `MLXTextCleaner` path.
- ☐ **Symbol index is bounded** (default 500 entries, deterministic truncation in source order).
  The LLM is told the index is partial if the file has more identifiers.
- ☐ **Lean build does not read the file.** Without `CODE_INTELLIGENCE` defined, the symbol
  index is unavailable; comment formatting uses prefix only. This is a privacy-friendly default.
- ☐ **The user can revoke consent at any time** via Settings ▸ Code ▸ File-read consent (lists
  all app+language entries with Allow / Never / Reset controls).
- **Residual (L-10 — SwiftSyntax reads file content):** the SwiftSyntax-backed identifier
  extractor for Swift files sees the file's content. The user has explicitly opted in via the
  consent dialog. The same risk surface exists for the existing `AssetInventory` for STT
  models (also gated by consent). The user can revoke via Settings.
- **Residual (L-11 — "Always allow" persists forever):** once a user clicks "Always allow"
  for an app+language, we never re-prompt for that combination. The user can revoke via
  Settings ▸ Code ▸ File-read consent. A future hardening could add a 90-day expiry on
  "Always allow" entries.
- **Residual (L-12 — Regex extractor false positives):** for non-Swift languages, the regex
  extractor can grab identifiers from comments or string literals. The extractor strips
  comments and string literals first, but the stripping is heuristic. Worst case: an extra
  identifier in the symbol index that the LLM doesn't reference. Not a security issue, but a
  quality issue.
- **Residual (L-13 — Identifier hallucination):** the LLM may invent identifiers not in the
  symbol index. The new `OutputValidator` rule flags non-existent identifiers in the rewrite
  (best-effort: a reference to an imported type from another module is valid but won't be in
  the index). The validator doesn't reject; it surfaces a warning in the history record.
- **Residual (L-14 — Commit-box heuristic false positives):** the `CommitBoxDetector`
  heuristic may mis-identify a non-commit text field as a commit-message box. The confidence
  threshold (≥ 0.7) gates auto-formatting; below the threshold the user sees a one-time
  per-app toast with a confirmation. Worst case: a comment or note gets formatted as a
  Conventional Commits message; the user can revert via Settings ▸ Code.
