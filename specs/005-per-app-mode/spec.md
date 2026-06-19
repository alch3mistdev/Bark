# Feature Specification: Per-app auto-mode

**Branch**: `005-per-app-mode` | **Created**: 2026-06-19 | **Status**: Draft
**Input**: Auto-pick the rewrite Mode based on the focused app (roadmap plan, scope "top 3 quick wins").

## User Scenarios

### US1 — Auto-select mode by app (P1)
The user maps apps to modes (e.g. Terminal→Raw, Mail→Email). When dictating into a mapped app, that mode
is used automatically; unmapped apps use the manually selected mode.

**Acceptance**:
1. Map Terminal→Raw and Mail→Email; dictating into Terminal uses Raw, into Mail uses Email, into anything
   else uses the manual selection.
2. A mapping to a mode that was since deleted falls back to the manual selection (no crash, no empty mode).
3. The mapping is resolved from the app focused at dictation **start** (consistent with the focus guard).

## Success Criteria
- Pure `AppModeResolver` unit-tested; controller resolves the effective mode per utterance; Settings pane
  to manage mappings. `swift build` clean, `swift test` green.
