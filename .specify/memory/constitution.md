# Bark Constitution

## Core Principles

### I. Offline-First, Privacy by Construction
Audio and transcripts never leave the device. No analytics, telemetry, accounts, or content-bearing
crash reports. The only permitted network event is a user-initiated, integrity-verified model/asset
download. Any feature that would transmit user content is rejected, not configured.

### II. Evidence or It Didn't Happen
Every "done"/"passing" claim is backed by the command run and its output, a `file:line`, or a
screenshot. No asserted results. "Built" means it compiled and its tests passed here.

### III. Swappable Engines Behind Protocols
STT, cleanup, and injection are protocols (`STTEngine`, `TextCleaner`, `TextInjector`). Concrete
backends (SpeechAnalyzer, Parakeet, MLX, pasteboard/keystroke) are interchangeable; the pipeline and
UI depend only on the protocols. Pure logic lives in `BarkCore` with zero third-party dependencies.

### IV. Least Privilege & Safe Injection (NON-NEGOTIABLE)
Request only the permissions truly needed, just-in-time. Never synthesize Return/Enter. Refuse
secure/password fields. Sanitize control/escape/bidi characters. Snapshot+restore the clipboard.
Re-verify focus before injecting. Document residual limitations honestly — never overclaim a control.

### V. Speed-First, Non-Blocking
Raw dictation must feel instant (sub-second). The LLM rewrite never blocks delivery: deterministic
text is always produced; the LLM runs under a hard deadline with a deterministic fallback.

## Quality Gates
- `swift build` clean; `swift test` green (output shown).
- Pure logic is unit-tested; orchestration is tested with injected fakes. Runtime OS-adapter behavior
  whose effectiveness can't be unit-tested is documented as best-effort with named residuals.
- No secrets in source. Transcripts, if persisted, are encrypted at rest and opt-in.
- Static-analysis/lints clean where tooling exists; dependencies' licenses recorded (SBOM).

## Development Workflow
Spec-driven (Spec Kit): constitution → spec → plan → tasks → implement. Each user story is an
independently shippable slice. Adversarial review (Codex + ef-adversary) on the diff before delivery;
flagged correctness/security bugs are fixed or explicitly documented as accepted limitations.

## Governance
This constitution supersedes convenience. Complexity must be justified against these principles.
Security controls and the offline guarantee are non-negotiable; weakening either requires an explicit,
documented decision (ADR) and user sign-off.

**Version**: 1.0.0 | **Ratified**: 2026-06-18 | **Last Amended**: 2026-06-18
