# Architecture Decision Records — Bark

Condensed from the design phase (ef-architect, cross-checked with Codex). Status: Accepted.

## ADR-001 — Native Swift / SwiftUI, single process
**Decision.** Native Swift 6 + SwiftUI `MenuBarExtra`, one process.
**Why.** The whole product is realtime audio + ANE speech + global hotkey + cross-app text
injection — all native Apple-Silicon APIs with first-class Swift bindings. Electron ships ~150 MB of
Chromium and still needs native shims for every privileged API; Python+Tauri adds a runtime and a
webview without solving the realtime/ANE path.
**Consequence.** macOS-only; Swift 6 strict concurrency (good — forces the actor isolation we want).
App Sandbox is **not** viable with a global `CGEventTap` + Accessibility injection → ship
**non-sandboxed, Developer-ID notarized** (not Mac App Store). See ARCH-006.

## ADR-002 — Swappable `STTEngine` protocol
**Decision.** `protocol STTEngine` with `SpeechAnalyzerEngine` (Apple, macOS 26) as the day-1 default;
`ParakeetEngine` / `WhisperKitEngine` drop in later behind the same protocol.
**Why.** ef-ai-ml picks Apple SpeechAnalyzer for speed (≈55–60 ms latency, ANE, zero bundled model
weight, fully offline after the locale asset installs) with Parakeet TDT-0.6b-v3 (25 languages) as the
multilingual fallback. The pipeline must not be coupled to either.
**Consequence.** A stable `AudioFrames` / `STTResult` contract; per-engine asset/download semantics
hidden behind `prepare()`.

## ADR-003 — LLM cleanup via MLX-Swift, behind `TextCleaner`
**Decision.** `protocol TextCleaner` with two impls: `BasicTextCleaner` (deterministic, always on) and
`MLXTextCleaner` (Qwen3-4B-Instruct 4-bit via MLX-Swift, optional).
**Why.** MLX is Apple's blessed on-Silicon inference path; Qwen3-4B-4bit is the best rewrite quality at
~40–60 tok/s on M3 Pro. But the LLM stage costs ~0.7–1.2 s, so it must never block delivery.
**Consequence.** Deterministic text is produced first and always; the LLM only runs for LLM-modes,
is timeout-bounded and cancellable, and falls back to deterministic output on any failure (ARCH-004).
LLM is a build-time opt-in so the core stays fast/offline/verifiable (see README).

## ADR-004 — Text injection strategy
**Decision.** Default `PasteboardInjector` (snapshot full clipboard → set text → ⌘V → restore);
automatic `KeystrokeInjector` fallback for terminals / when paste is rejected.
**Why.** Pasteboard+⌘V is fast and Unicode/emoji/IME-safe in one shot; per-character synthesis is the
fragile fallback.
**Consequence (mandatory controls).** Refuse secure/password fields and when Secure Input is active;
never synthesize Return/Enter; snapshot **all** pasteboard types (string-only restore is data loss);
guard restore with `changeCount`; re-verify focused window before injecting (ARCH-001/005, SEC-002/004/005/007).

## ADR-005 — Packaging & model distribution
**Decision.** Ship an Xcode/SwiftPM-built `.app`, Developer-ID signed + hardened-runtime + notarized,
outside the Mac App Store. Speech models are **not bundled** — the OS installs the SpeechAnalyzer
locale asset on first use; any future downloaded model is sha256-verified.
**Why.** A menu-bar app needs `LSUIElement`, usage strings, entitlements; models are large and update
independently. CGEventTap + Accessibility forbid the MAS sandbox.
**Consequence.** A notarization step (`scripts/make-app.sh` + `notarytool`); first-run asset install is
the only network event; offline thereafter.

## ADR-006 — Pluggable STT backends behind `STTEngineFactory`
**Decision.** Add WhisperKit and Parakeet TDT (via FluidAudio) as optional `STTEngine`
implementations, selected by `STTEngineFactory` from a persisted `Settings.sttBackend`. The
opt-in manifest `Package-stt-extras.swift` adds the SwiftPM dependencies and the `WHISPERKIT` /
`FLUIDAUDIO` flags; the lean build compiles stub implementations that throw a clear "not
compiled in this build" error so the pipeline stays runnable offline. Model downloads are
sha256-verified against a bundled `ModelManifest` (`ModelDownloader.ensureModel`); mismatch
deletes the file and never writes it to the cache (`SEC-003 / T-010`).
**Why.** ADR-002 named these adapters as a future extension; this closes that gap with the
smallest possible surface (one factory + one manifest schema + one downloader). It also closes
the SECURITY.md ☐ for downloaded-model integrity and gives WhisperKit users a clear path to
opt in without compromising the lean build's offline guarantees.
**Consequence.** Lean build is unchanged. Extras build adds two backends and a model
download path. Settings UI hides uncompiled backends. Stale settings from a future build can
never brick the app — the factory falls back to `SpeechAnalyzerEngine()` and logs a warning.
See `docs/ADR-006-stt-engine-selection.md` for the full record (alternatives, verification).

## ADR-007 — Voice-driven revision of the last injection
**Decision.** Add a second hotkey (`revisionHotkey`, default `⌥⌘R`) that revises the text Bark
just injected into the focused field. The revision pipeline sits behind a new `RevisionEngine`
protocol with two implementations: a `DeterministicRevisionEngine` in `BarkCore` (hard-coded
dictionary: *delete that*, *undo*, *select all*, *copy*, *scratch that* — works in the lean build,
no LLM) and an `LLMRevisionEngine` in `BarkCleanupMLX` gated by `MLXCleanup` (free-form revisions
via the existing `MLXTextCleaner`). `HistoryRecord` gains an optional `parentID: UUID?` for
revision linkage; `Mode` gains an optional `revisionPrompt` with a per-mode default table.
Revisions re-run every existing security control (`SecureFieldPolicy`, `FocusGuard`,
`TextSanitizer`) and `OutputValidator` gains a new length-drift rule (revised text must be ≤ 2×
previous length) to catch prompt-injection expansion. The spoken instruction is fenced as
`<revision>` in `PromptTemplate.revisionSystem` (mirrors SEC-010).
**Why.** Every dictation app competes on the speech→text leg; nobody operates on already-injected
text via voice. This is the #1-ranked gap from the 2026-06-19 competitive analysis and the single
highest-leverage move in the category: it transforms Bark from "dictation app" into "voice-controlled
text editor." The deterministic dictionary ensures the feature ships in every build, not just the
MLX build, so the lean build gets value without a model download.
**Consequence.** Lean build gains the dictionary path (no new deps, no new network). MLX build adds
the LLM path. `Settings` grows by `revisionHotkey` and `revisionEnabled` (default on). STRIDE in
`docs/SECURITY.md` gains a "Revision surface" section. ~18 new tests. Honest residual risks: AX
automation brittleness in Electron apps; spoken instruction as a prompt-injection vector (mitigated
by the length-drift rule + prompt fence). See `docs/ADR-007-revision-surface.md` for the full
record (alternatives, verification) and `specs/009-voice-driven-revision/` for the spec, plan, and
tasks.

## ADR-008 — Inline code comment + commit-message dictation (developer-specific)
**Decision.** Add file-aware code dictation: a static `LanguageCommentTable` in `BarkCore`
maps file extension → comment style (`//`, `#`, `<!-- -->` etc.); an LLM-backed rewrite pass
for code comments is given a per-file symbol index (extracted via `LanguageIdentifier`
protocol — `RegexLanguageIdentifier` in `BarkCore`, `SwiftSyntaxLanguageIdentifier` in
`BarkCleanupMLX` gated by `#if CODE_INTELLIGENCE`); Conventional Commits formatting is
applied to commit-message boxes (detected by `CommitBoxDetector` heuristic + a one-time
per-app toast for uncertain cases). Reading the focused file to build the symbol index
is a privacy expansion — gated by a per-app-per-language consent dialog (default "Allow
once"; user-configurable in Settings ▸ Code). The lean build degrades gracefully: comment
prefix works without an LLM; identifier preservation and Conventional Commits formatting
are skipped.
**Why.** Every dictation app targets prose. Developers are a non-trivial share of macOS
dictation users, and they currently get a *worse* experience than email writers. This is
the #2-ranked gap from the 2026-06-19 competitive analysis and the dev-specific wedge for
Bark: combined with the voice-driven revision surface (ADR-007) and the offline posture
(constitution I), it gives Bark a unique position in the dictation category for developers.
**Consequence.** Lean build gains the comment prefix and language table (no new deps, no
new network). MLX build adds identifier preservation and Conventional Commits formatting.
`Settings` grows by `codeIntelligence: CodeIntelligenceSettings` (master toggle + per-
language toggles + per-app-per-language file-read consents). STRIDE in `docs/SECURITY.md`
gains a "File read for code intelligence" section. ~25 new tests. Honest residual risks:
SwiftSyntax reads the file's content; the consent dialog can be bypassed by "Always allow";
the regex extractor on non-Swift files can include false positives. See
`docs/ADR-008-code-intelligence.md` for the full record (alternatives, verification) and
`specs/010-inline-code-dictation/` for the spec, plan, and tasks.

## ADR-009 — Voice fingerprinting (speaker gate for hands-free)
**Decision.** Add an opt-in, on-device **speaker gate** to hands-free dictation: per completed
utterance, extract a 256-d speaker embedding (FluidAudio WeSpeaker v2, behind the existing
`FLUIDAUDIO` flag — no new dependency, no SBOM delta) and compare it by **cosine similarity** to an
enrolled centroid; inject only on a match, otherwise suppress with a faint cue and keep listening.
The seam is a `SpeakerEmbedder` protocol in `BarkCore`; all decision math (`SpeakerEmbedding`,
`SpeakerVerifier`, `SpeakerVerificationSensitivity`) is pure and unit-tested, with a throwing
`Noop` embedder in the lean build (callers fail open, so dictation is unaffected). The voiceprint
(`SpeakerProfile`) is persisted by `EncryptedSpeakerProfileStore` — AES-256-GCM, key in the Keychain
under a **distinct** service (`com.bark.speaker`) so it deletes independently of history. The gate
**fails open** everywhere: disabled, not enrolled, model-incompatible, utterance too short (<1.0 s
voiced), or any embedder error → the user's own dictation is injected as normal. Push-to-talk is
untouched (already deliberate intent).
**Why.** In shared/noisy rooms, continuous dictation acts on every speaker. A per-utterance voice
filter stops coworkers, the TV, and bystander commands from being typed — real value for hands-free.
Framed **honestly** as a convenience filter, **not** anti-spoofing or authentication: a recording or
voice-clone of the user yields a near-identical embedding and is accepted (research D4). Reusing the
already-approved FluidAudio model keeps the dependency/SBOM surface flat.
**Consequence.** `Settings` grows two tolerant-decoded fields (`speakerGateEnabled` off by default,
`speakerSensitivity` default medium). `DictationController.runHandsFree` accumulates the utterance
audio and runs the gate before injection, overlapping the ANE embed with cleanup so no perceptible
delay is added (SC-004). `SpeakerEnrollmentController` drives a guided 5-phrase enrollment; new cue
`Feedback.declined()`. STRIDE in `docs/SECURITY.md` gains a "Voiceprint / speaker gate" section.
~40 new tests (lean build, fake embedder). Honest residual risks: replay/clone accepted; short
utterances bypass the gate (fail-open by design); starting thresholds (0.40/0.50/0.62) are calibrated
on real captures before release. See `specs/011-voice-fingerprinting/` for the spec, plan, research,
and contracts.

## ADR-011 — Socratic discussion (pre-action prompt refinement)

**Decision.** Add an opt-in, hotkey-driven (default F7) multi-turn dialogue phase before text is
produced: the user and the LLM refine a goal by voice (overlay text + optional on-device
`AVSpeechSynthesizer` speech), grounded in a 015-style window capture, and the engine then
synthesizes one final prompt that is previewed and injected through the existing safe-injection
path. New `BarkCore` seams: `DialogueEngine` (message-array chat, conformers `MLXTextCleaner` and
`OpenAICompatClient`), `SpeechSynthesizing` (TTS), and the pure `DiscussionSession` machine.
Control flow never rides free text: replies carry a parsed `{"reply","ready"}` contract whose
malformed degrade is `ready=false`.
**Why.** Dictation turns speech into text; 015 answers what's on screen; neither helps the user
*decide what to say*. A short Socratic loop before generation improves the final prompt where it
matters (coding agents, email, docs) while reusing every hard primitive Bark already has.
**Privacy/safety posture.** Transcript + capture are memory-only, wiped on session end, never in
history (stronger than 015's empty-transcript records: nothing is recorded). External-endpoint use
reuses the ADR-010 opt-in but the Discuss pane warns that a *whole conversation* is transmitted
per turn. The mic is hard-leased: `DictationController.micLeaseHeld` makes both dictation start
paths refuse while a session runs (advisory phase reads were racy), and hands-free is suspended
and resumed around the session. Half-duplex is an invariant, not a hope: audio may start only in
`awaitingUser`/`listening`, and leaving `presenting` requires `speak()` to have returned — tested
with a gated TTS fake (SC-002). No auto-submit exists on this path; `ReturnKeySynthesizing` is not
wired. The hotkey collision guard extends to 4-way.
**Consequence.** `Settings` grows four tolerant-decoded fields; the settings window gains a 9th
tab. The in-session turn key is the discussion hotkey itself (tap-to-talk toggle; tap skips TTS) —
a refinement over the spec's original fn-hold idea, avoiding cross-controller event interception.
~25 new tests (session machine, prompt fencing, parser, flow, TTS gating, recapture). Residuals:
the readiness contract depends on model JSON discipline (degrade: Done button always works);
per-turn stateless `ChatSession` rebuild trades prefill cost for recapture simplicity and
testability. See `specs/017-socratic-discussion/`.

## ADR-012 — Opt-in cloud TTS for spoken discussion replies

**Decision.** Add an opt-in `SpeechSynthesizing` conformer that speaks discussion replies via the
ElevenLabs API (default `eleven_flash_v2_5`), with the on-device system voice as the default
backend and as the structural failure direction (`FallbackSpeechSynthesizer`). Full rationale,
controls, and the honest data-flow statement: `docs/ADR-012-cloud-tts-privacy-exception.md`.
**Why.** 017's speech had two problems. One was a bug — no voice was ever set, so a stock Mac used
a *compact* voice (measured: 180 voices installed, zero Enhanced/Premium) — and that is fixed
on-device by `VoiceSelector`. The other is a ceiling: no local model closes the gap for *this*
feature. Kokoro-82M, the best Apache-2.0 candidate, renders `?` and `!` acoustically identically
to `.` (hexgrad/kokoro #78/#194/#264, open, reproduced), which is disqualifying for a Socratic
questioner. Permitting non-commercial weights changed nothing material: only Breeze TTS 2 (3B)
clearly wins on short lines, and it has no streaming Swift path and runs slower than real time on
an M3 Pro while contending with the resident Qwen3-4B for Metal.
**Consequence.** A Principle I carve-out on ADR-010's exact terms, with user sign-off: default
off; selecting on-device makes provably zero requests; failure falls back locally and never
escalates; the half-duplex invariant holds on the fallback path too; the key lives in the Keychain
under its own account and never in the settings payload; transmitted text is bounded at 2000
chars; the session is ephemeral; requests are deadline-bounded at 10 s; errors surface once per
configuration, not per turn. The warning states plainly that the reply can paraphrase or quote
what Bark read or heard — it does not claim only Bark-authored text is sent. Streaming deferred.
See `specs/018-elevenlabs-tts/` and SECURITY residuals L-23…L-25.
