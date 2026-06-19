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
