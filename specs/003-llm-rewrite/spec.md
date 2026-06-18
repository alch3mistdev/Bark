# Feature Specification: On-device LLM rewrite (Qwen3-4B / MLX)

**Branch**: `003-llm-rewrite` | **Created**: 2026-06-18 | **Status**: Draft
**Input**: "I can't toggle/activate the LLM option" → ship the on-device LLM with a real
download + warm-up flow so the LLM modes actually rewrite.

## User Scenarios & Testing

### US1 — Enable the LLM (P1)
In Settings, the user enables "Use LLM rewrite". If the model isn't present, Bark downloads
Qwen3-4B (~2.5 GB) once with visible progress; when ready, LLM modes rewrite on-device, offline.

**Acceptance**:
1. Toggle is enabled in the shipped (MLX) build (not greyed out).
2. Turning it on with no model → shows "Downloading… N%", then "Ready".
3. After ready, an Email/Message/Code/List dictation is rewritten by the model; raw/clean stay instant.
4. Model load/download never trips the per-utterance timeout (download is separate from generation).

### US2 — Graceful states (P2)
Download failure → "Failed", clear message, modes fall back to the deterministic cleaner; no hang.
Disabling the toggle stops using the LLM. First LLM dictation before "Ready" falls back, no error.

## Success Criteria
- Shipped DMG includes the MLX engine; toggle works; modes rewrite once the model is ready.
- `swift test` (lean, offline) stays green; MLX target + MLX app build.
- Per-utterance generation stays bounded; download/warm-up is a separate, observable step.
