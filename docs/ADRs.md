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
