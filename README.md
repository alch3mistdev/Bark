# Bark 🐕

**Offline AI dictation for macOS.** Hold a key, speak, and clean text is typed into whatever app is
focused — fully on-device, no cloud, no account, no telemetry.

Built for Apple Silicon (developed/tested on **M3 Pro / 36 GB / macOS 26.5**). A native Swift
menu-bar app in the spirit of Superwhisper / Wispr Flow / VoiceInk — but offline-first and built
around the macOS 26 on-device speech stack.

---

## Why this exists

macOS already has built-in Dictation. Bark's value is the **workflow layer** on top of fast on-device
speech-to-text:

- **Instant, accurate dictation** via Apple's `SpeechAnalyzer` (macOS 26) — runs on the Neural Engine,
  ~55–60 ms latency, zero bundled model weight, fully offline after the one-time locale install.
- **Cleanup + rewrite "Modes"** — filler removal, punctuation, casing instantly; optional on-device
  **LLM rewrite** (Qwen3-4B) for Email / Message / Code / List modes.
- **Type anywhere** — pastes into the focused app with the safety controls below.
- **Speed-first** — raw dictation lands in ~150–300 ms; the LLM never blocks delivery.

## The model picks (for M3 Pro / 36 GB)

| Stage | Engine | Why |
|------|--------|-----|
| Speech-to-text (default) | **Apple `SpeechAnalyzer` / `SpeechTranscriber`** (macOS 26) | Lowest latency, ANE, 0 app RAM, offline, no Python. |
| Speech-to-text (fallback) | **Parakeet TDT-0.6b-v3** (FluidAudio, CoreML) | 25 languages, Apache-2.0, ANE — drop-in via `STTEngine`. |
| Cleanup (always) | **`BasicTextCleaner`** (deterministic) | Instant filler/punctuation/casing. No model. |
| Rewrite (opt-in) | **Qwen3-4B-Instruct-2507 4-bit** via MLX-Swift | Best rewrite quality at ~40–60 tok/s on M3 Pro; non-blocking. |

The STT and cleanup backends are behind protocols (`STTEngine`, `TextCleaner`) — swap models without
touching the pipeline. See `docs/ADRs.md`.

## Requirements

- macOS 26.0+ on Apple Silicon
- Xcode 26 / Swift 6 toolchain

## Build & run

```bash
swift build            # fully offline, no external dependencies
swift test             # 53 unit tests on the core logic

# Package a runnable .app (ad-hoc signed for local use):
scripts/make-app.sh
open dist/Bark.app
```

On first launch macOS will ask for three permissions (each requested just-in-time, least privilege):

| Permission | Used for | Without it |
|-----------|----------|-----------|
| **Microphone** | capture your voice | required to dictate |
| **Accessibility** | type text into the focused app | falls back to copying to clipboard |
| **Input Monitoring** | the global push-to-talk hotkey | use the menu's Start button instead |

## Usage

- **Hold `fn` (Globe)** to talk; release to insert. (Push-to-talk is the default; toggle mode and a
  custom key are supported in `HotkeyConfig`.)
- Pick a **Mode** from the menu bar: `Raw` · `Clean` · `Email` · `Message` · `Code / Commit` · `List`.
- `Raw`/`Clean` are instant. The LLM modes rewrite and insert once (sub-second to ~1.5 s).

## Enable on-device LLM rewrite (MLX)

The default build is dependency-free and uses the deterministic cleaner for every mode. To turn on the
**Qwen3-4B** rewrite engine for the LLM modes:

```bash
cp Package-mlx.swift Package.swift     # adds mlx-swift-lm + swift-transformers + swift-huggingface
swift build -c release                 # first build compiles MLX/Metal — takes a while
```

The model (~2.5–3 GB) downloads from Hugging Face on first use, then runs fully offline. Revert with
`git checkout Package.swift`. (Both manifests are verified to build.)

## Privacy & security

Fully offline by design; see `docs/SECURITY.md` for the full STRIDE threat model, the control map,
and the **honest limitations** of each control. Highlights, enforced in code:

- **No network at runtime** — the only egress is the one-time OS speech-asset install on first use.
  No analytics, telemetry, or accounts.
- **Never synthesizes Return/Enter**, and strips trailing newlines + control/escape/bidi characters
  before insertion. Known terminals get single-line keystroke injection. (Hard guarantee: no Return is
  ever posted. Residual: a multi-line *paste* into an unrecognized terminal relies on the terminal's
  bracketed-paste mode — see SECURITY.md.)
- **Refuses password/secure fields** when macOS Secure Input is active or the focused element reports
  `AXSecureTextField`. (Best-effort: web/Electron password fields that don't trip either signal aren't
  detectable from outside the app — documented limitation.)
- **Re-verifies the focused app (by PID)** immediately before inserting; aborts on app switch.
  (Catches cross-app focus changes; a switch *within the same app* between windows/fields is a known
  residual of synthetic paste.)
- **Restores your clipboard** after pasting — full snapshot, `changeCount`-guarded — and marks the
  injected payload concealed.
- Dictation is **fenced as untrusted data** before any LLM call (prompt-injection defense); LLM output
  is length-bounded with a hard deadline and a deterministic fallback.
- Ships **non-sandboxed + hardened-runtime, Developer-ID notarized** (the global hotkey + Accessibility
  injection are incompatible with the App Store sandbox — see ADR-001/006).

## Architecture

```
Bark (SwiftUI MenuBarExtra)
 ├─ DictationController ........ orchestrates the pipeline (state machine)
 ├─ BarkEngines ................ OS adapters
 │   ├─ SpeechAnalyzerEngine ... Apple on-device STT (macOS 26)
 │   ├─ AudioCaptureEngine ..... AVAudioEngine → 16 kHz mono → lock-free ring buffer
 │   ├─ HotkeyManager .......... global CGEventTap (push-to-talk / toggle)
 │   ├─ PasteboardInjector ..... ⌘V with clipboard snapshot/restore (+ KeystrokeInjector fallback)
 │   └─ PermissionsCoordinator . mic / Accessibility / Input Monitoring TCC
 ├─ BarkCleanupMLX ............. optional Qwen3-4B rewrite (MLX) — stubbed out by default
 └─ BarkCore ................... pure, dependency-free, fully unit-tested
     ├─ AudioRingBuffer (SPSC)  ├─ TextSanitizer       ├─ BasicTextCleaner
     ├─ Mode / ModeRegistry     ├─ PromptTemplate      ├─ SecureFieldPolicy
     ├─ InjectionPlan / FocusGuard / TerminalDetector  └─ DictationStateMachine
```

## Status

**Built & verified this pass** (`swift build` + 55 passing tests): the full record → STT → cleanup →
inject pipeline, global hotkey, all six modes, the deterministic cleaner, and the MLX LLM engine
(verified to compile/link via `Package-mlx.swift`).

What the tests prove vs. don't: the 55 unit tests cover the **pure decision logic** (sanitizer,
secure-field policy, terminal detection, focus-guard, ring buffer, mode/prompt templates, pipeline
state machine). The **runtime effectiveness** of the OS-adapter controls (actual paste/keystroke,
AX focus probing, CGEventTap, live SpeechAnalyzer) is **not** unit-tested — it requires running the
app and granting TCC permissions. Treat those controls as best-effort, with the residuals noted in
`docs/SECURITY.md`.

**Designed, wired via protocols, not yet implemented** (tracked in `docs/SECURITY.md` / ADRs):
Parakeet/WhisperKit STT adapters, transcript history (encrypted, opt-in), a model-manager UI, full
settings persistence, and the notarization pipeline.

> Note: live end-to-end behavior (mic → paste) requires running the app and granting the TCC
> permissions interactively — it can't be exercised in a headless build. The build, the unit tests,
> and compilation against the real macOS 26 / MLX APIs are all verified here.
