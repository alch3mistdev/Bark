# ADR-009 — Suggested Responses: external LLM endpoint & opt-in auto-submit (constitution v2.0.0 exceptions)

**Status:** Accepted (user sign-off in the 015 clarification session, 2026-07-16)
**Date:** 2026-07-16
**Context:** `specs/015-suggested-responses/spec.md`
**Amends:** Constitution Principles I and IV (v1.0.0 → v2.0.0); SEC-005 / T-006 (never synthesize Return)

## Context

Feature 015 adds a second flow beside dictation: a hotkey captures the frontmost app's on-screen
context (a coding agent's pending question, a labeled form field), an LLM generates 3–4 probable
responses, and a floating overlay lets the user pick one (or dictate their own) for injection through
the existing routing pipeline.

Two capabilities the user explicitly requested conflict with constitution v1.0.0:

1. **External LLM backend.** The local Qwen3-4B model may be too weak for long coding-agent
   preambles. The user wants an optional OpenAI-compatible endpoint (covers Ollama on another
   machine, LM Studio, or a cloud provider). Principle I permitted no content-bearing network events.
2. **Auto-submit.** After inserting a chosen suggestion, optionally press Return so the response is
   submitted (e.g. answering a coding agent in a terminal). Principle IV said "Never synthesize
   Return/Enter" (also SEC-005/T-006; all three injectors refuse Return by contract,
   `TextInjector.swift:8`).

## Decision

### 1. External endpoint — opt-in, warn, fail-toward-local

- New `SuggestionEngine` backend `external`: OpenAI-compatible `POST {base}/chat/completions` via
  URLSession. Backend selection is per-user, **default `local`**.
- Settings UI shows a privacy warning naming exactly what leaves the device when `external` is
  selected: the captured screen context (clipped), focused-field metadata, and history snippets
  included in the prompt. Nothing is sent until the user selects the backend and enters an endpoint.
- API key is stored in the **Keychain** (device-only, when-unlocked), never in the Settings JSON.
- Failure policy is asymmetric by design: external errors (unreachable, 401, bad JSON) **fall back to
  the local engine** when available; local failures never silently escalate to the network.
- Captured context is **ephemeral** — memory only, never persisted, never logged (lengths only in
  debug), never written to history. Dictation/cleanup paths remain fully offline; the carve-out is
  scoped to suggestion generation.
- ACP (Agent Client Protocol) bridge to local CLI agents was considered as a third backend and
  **deferred** — see research.md R11.

### 2. Auto-submit — opt-in, re-preflighted, confined

- New setting `suggestionAutoSubmit`, **default OFF**, with warning copy beside the toggle.
- Return synthesis lives in exactly one new component, `ReturnKeySynthesizer` (BarkEngines). The
  `TextInjector` implementations remain byte-identical to their "never posts Return" contract.
- Guards, all mandatory: fires only after a suggestion the user explicitly selected was successfully
  inserted; re-runs injection preflight (focus unchanged + secure-field refusal + Secure Input check)
  immediately before posting; short settle delay between insertion and keypress; never fires for the
  "Other"/dictation path in v1.
- Terminals are deliberately allowed — the coding-agent scenario is the point. Justification: the
  user read and chose the exact string; the Return is per-use consent, not ambient automation.

## Consequences

- Constitution bumped to **v2.0.0** (two principle redefinitions = MAJOR). Both carve-outs are
  written into Principles I and IV directly so future specs gate against the amended text.
- SECURITY.md must document the residuals when 015 is implemented: target app may remap Return
  (auto-submit is best-effort); an external endpoint operator sees whatever the prompt contains —
  mitigations are the warning, opt-in default, and fail-toward-local policy.
- The overlay/injection path inherits all existing controls unchanged: secure-field refusal (capture
  AND inject), clipboard snapshot/restore, focus re-verification, sanitization.
