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
swift test             # 172 tests (core logic + controller orchestration + history crypto + STT backends + model inspector)

# Build a draggable installer (ad-hoc signed for personal use):
scripts/make-dmg.sh
open dist/Bark.dmg     # → drag Bark to Applications
```

First launch of an ad-hoc/unsigned build: right-click **Bark.app → Open** once (Gatekeeper), or
`xattr -dr com.apple.quarantine /Applications/Bark.app`. See `specs/001-daily-driver/quickstart.md`.

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
- **Per-app auto-mode** — map apps to modes in **Settings ▸ Per-app modes** (e.g. Terminal→Raw,
  Mail→Email). When you dictate into a mapped app, that mode is used automatically; everything else
  uses your manual selection.
- **Copy to clipboard instead of typing** — **Settings ▸ General ▸ Output ▸ "When dictation ends"**.
  Pick *Copy to clipboard* for apps where synthetic paste/keystrokes are unreliable; paste with ⌘V.
- **Re-use a past dictation** (needs history on) — the menu bar's **Re-insert recent** types a saved
  result into the app you're in; **Settings ▸ History** has a search box + per-row **Copy**.

## Enable on-device LLM rewrite (MLX)

The default build is dependency-free and uses the deterministic cleaner for every mode. To turn on the
**Qwen3-4B** rewrite engine for the LLM modes:

```bash
cp Package-mlx.swift Package.swift     # adds mlx-swift-lm + swift-transformers + swift-huggingface
swift build -c release                 # first build compiles MLX/Metal — takes a while
```

The model (~2.5–3 GB) downloads from Hugging Face on first use, then runs fully offline. Revert with
`git checkout Package.swift`. (Both manifests are verified to build.)

## Alternative STT backends (optional)

The default speech engine is **Apple SpeechAnalyzer** (on-device, macOS 26, no download). Two optional
backends drop in behind the same `STTEngine` — **WhisperKit (Argmax)** and **Parakeet (FluidAudio)** —
for broader language coverage. They are **opt-in at build time** so the lean build stays dependency-free
and fully offline:

```bash
cp Package-stt-extras.swift Package.swift   # adds WhisperKit + FluidAudio; sets WHISPERKIT / FLUIDAUDIO flags
swift build -c release
git checkout Package.swift                   # revert to the lean, dependency-free default
```

Without those flags the engines compile to thin stubs, so a stale setting can never brick the app —
the factory falls back to Apple and logs a warning.

- **Pick an engine** — **Settings ▸ General ▸ Speech ▸ Engine**. Only backends compiled into the
  running build are offered.
- **Model cache** — **Settings ▸ Models**: lists cached bundles in
  `~/Library/Application Support/Bark/models/`, with **Re-verify** (re-checks each bundle's SHA-256)
  and **Reveal in Finder**. Model downloads are **SHA-256-verified** against a bundled manifest before
  they enter the cache; a mismatch deletes the file and never caches it (SEC-003).

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
 │   ├─ SpeechAnalyzerEngine ... Apple on-device STT (macOS 26)  [default]
 │   ├─ WhisperKit/ParakeetEngine  optional STT backends (build flags) + STTEngineFactory
 │   ├─ ModelDownloader/Store/Inspector  SHA-256-verified model cache
 │   ├─ AudioCaptureEngine ..... AVAudioEngine → 16 kHz mono → lock-free ring buffer
 │   ├─ HotkeyManager .......... global CGEventTap (push-to-talk / toggle)
 │   ├─ PasteboardInjector ..... ⌘V with clipboard snapshot/restore (+ KeystrokeInjector fallback)
 │   ├─ ClipboardInjector ...... copy-to-clipboard output routing (secure-field-guarded)
 │   ├─ FocusProbe ............. frontmost target + best-effort caret rect (HUD anchor)
 │   └─ PermissionsCoordinator . mic / Accessibility / Input Monitoring TCC
 ├─ BarkCleanupMLX ............. optional Qwen3-4B rewrite (MLX) — stubbed out by default
 └─ BarkCore ................... pure, dependency-free, fully unit-tested
     ├─ AudioRingBuffer (SPSC)  ├─ TextSanitizer       ├─ BasicTextCleaner
     ├─ Mode / ModeRegistry     ├─ PromptTemplate      ├─ SecureFieldPolicy
     ├─ AppModeResolver         ├─ InjectionRouter / OutputRouting
     ├─ HistoryQuery            ├─ LevelMeter / HUDPlacement
     ├─ InjectionPlan / FocusGuard / TerminalDetector  └─ DictationStateMachine
```

## Daily-driver features

- **Settings open from the menu bar** (a real AppKit window — the SwiftUI `Settings` scene is
  unreliable in a menu-bar app, so Bark hosts its own and brings it to the front).
- **Live recording HUD** — a floating, non-activating overlay shows state + the partial transcript
  while you dictate (never steals focus from the app you're typing into). An opt-in **Enhanced
  recording overlay** (Settings → General → Feedback) adds larger live text, a **mic-level meter**,
  and best-effort anchoring near the text cursor; the default compact strip is unchanged.
- **Per-app auto-mode** — Settings → Per-app modes: map a bundle ID to a rewrite mode; the focused
  app at dictation start picks the mode, falling back to your manual selection.
- **Output routing** — Settings → General → Output: insert into the app (default) or **copy to
  clipboard only** for apps where injection is unreliable. Clipboard copies still refuse secure fields.
- **History search + re-insert** — Settings → History: search past dictations (case/accent-insensitive)
  and **Copy** any row; the menu bar's **Re-insert recent** types a saved result back into the focused
  app (focus-snapshotted, serialized, secure-field-guarded).
- **Settings persist** (UserDefaults): selected mode, language, hotkey, custom modes, toggles.
- **Launch at login** (`SMAppService`) — toggle in Settings → General.
- **Configurable hotkey** — Settings → Hotkey: **Hold fn** (push-to-talk) or record a **function key**
  (F1–F20) to toggle. (Plain ⌘/⌥/⌃ holds aren't offered — they'd fire on every normal shortcut.)
- **Hands-free mode** — a separate toggle hotkey (default **F5**) turns on continuous, voice-activated
  dictation: it records when you speak and inserts when you pause, then keeps listening — no button.
  Adjustable sensitivity (Settings → Hotkey → Hands-free).
- **Speaker gate** (optional, hands-free only) — enroll your voice, and Bark types only utterances that
  match it, silently ignoring coworkers, the TV, or a bystander issuing commands. On-device, encrypted,
  opt-in, deletable. **Honest limit:** it's a convenience filter, *not* security — it does **not** stop a
  recording, imitation, or clone of *your own* voice, and is not authentication or liveness. It fails
  **open**: if matching can't run, your own dictation is always typed. Ships in the optional FluidAudio
  build (WeSpeaker v2); the lean build hides the controls. (Settings → Hotkey → Speaker gate.)
- **Menu shows the last result** with one-click Copy; subtle start/insert sounds (toggleable).
- **Custom modes** — add your own rewrite modes (name + system prompt) alongside the built-ins.
- **Encrypted, opt-in history** — off by default; when on, transcripts are AES-256-GCM encrypted
  (key in the Keychain). Turning it **off purges** the store.
- **First-run onboarding** — guided permission grants.
- **Installer** — `Bark.dmg` with drag-to-Applications; app icon generated by `scripts/make-icon.swift`.

## Status

**Built & verified** (`swift build` clean + **172 passing tests**): the full record → STT → cleanup →
inject pipeline, global hotkey (push-to-talk + consumed toggle), all six modes + custom modes,
deterministic cleaner, settings persistence, launch-at-login, encrypted opt-in history, onboarding,
and `.app`/DMG packaging. Shipped workflow features: **per-app auto-mode**, **output routing**
(copy-to-clipboard), **history search + re-insert**, an opt-in **enhanced overlay with mic-level
meter**, and **pluggable STT backends** (Apple default; WhisperKit/Parakeet opt-in) with a
SHA-256-verified model cache + Models pane. The MLX LLM engine is verified to compile/link via
`Package-mlx.swift`.

What the tests cover: pure decision logic (sanitizer, secure-field policy, terminal detection,
focus-guard, ring buffer, modes/prompt templates, state machine, settings codec, retention) **and**
controller orchestration via injected fakes (raw/LLM paths, LLM failure+timeout fallback,
secure-field refusal, empty-transcript, restart-after-failure) **and** the history crypto round-trip,
wrong-key, and no-clobber behavior (`BarkAppTests`).

**Designed, wired via protocols, not yet implemented**: the Developer-ID notarization pipeline
(`scripts/make-app.sh` documents the `notarytool` steps). The WhisperKit and Parakeet STT adapters
are wired (`Sources/BarkEngines/STT/{WhisperKitEngine,ParakeetEngine}.swift`) and gated behind
`Package-stt-extras.swift` — the engines themselves are still thin until the real transcription paths
are filled in, but the factory, settings, SHA-256-verified downloader, and **Models pane** (Settings ▸
Models: inspect / re-verify / reveal the cache) are built and tested; see ADR-006.

**Specs only (not yet built)**: `specs/009-voice-driven-revision` (revise the last injection by voice)
and `specs/010-inline-code-dictation` (file-aware code comments + commit messages) — spec/plan/ADRs
merged for review; no implementation yet.

> Note: live end-to-end behavior (mic → paste) and the SMAppService login item require running the
> installed `.app` and granting TCC permissions interactively — they can't be exercised in a headless
> build. Two reviews (Codex GPT-5.4 + an adversarial pass) ran on the diff; their findings were fixed
> or documented in `docs/SECURITY.md`.

## License

Bark's own source is released under the **MIT License** (see `LICENSE`). The optional on-device models
and dependencies are licensed separately and are **not** covered by this license — notably Apple
`SpeechAnalyzer` (OS), NVIDIA Parakeet (NVIDIA Open Model License / Apache-2.0), Qwen3-4B (Apache-2.0),
mlx-swift / swift-transformers (MIT), etc. Review each model/dependency's terms before redistribution.

> Status: experimental / personal project. Built spec-first (`specs/`, `docs/ADRs.md`,
> `docs/SECURITY.md`, `docs/constitution.md`).

