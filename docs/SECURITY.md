# Bark — Security & Privacy

Threat model from the design phase (ef-security, STRIDE). Below: the controls and where they live in
code. Items marked ☐ are designed-but-not-yet-implemented (tracked for the next sections).

## Offline guarantee
- ☑ No networking code anywhere in the app at runtime. The only network event is the OS installing the
  SpeechAnalyzer locale asset on first use (`AssetInventory`, `SpeechAnalyzerEngine.prepare`).
- ☑ No analytics / telemetry / crash-reporting SDKs. `BarkLog` never logs transcript or audio content.
- ☐ A future downloaded-model path (Parakeet/MLX weights) must sha256-verify against a signed manifest
  over TLS before load (SEC-003 / T-010).

## Microphone privacy
- ☑ Mic opened only during active dictation; `AVAudioEngine` fully torn down on `stop()`
  (`AudioCaptureEngine.stop`). No always-listening mode. (T-002 / T-012)
- ☑ Persistent in-app state (menu-bar icon reflects `listening`), plus the macOS orange indicator.

## Text-injection safety  (`BarkEngines/Inject/*`, `BarkCore/Inject/*`)
- ☑ Refuse injection when `IsSecureEventInputEnabled()` or the focused AX element is `AXSecureTextField`
  (`SecureFieldPolicy` + `SecureFieldDetector`). (SEC-002 / T-005) — **best-effort**, see L-2.
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

## Revision surface  (`Sources/Bark/Revision/*`, ADR-007, `specs/009-voice-driven-revision/`)
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
  AX actions; they never write to the focused field's text content. They emit a ⌘Z / ⌘A / ⌘C
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
