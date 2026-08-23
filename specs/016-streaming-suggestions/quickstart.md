# Quickstart: Streaming Suggested Responses (016)

Validation guide — proves the feature end-to-end. Design details: [plan.md](plan.md), [data-model.md](data-model.md), [contracts/streaming-engine.md](contracts/streaming-engine.md).

## Prerequisites

- macOS 26+, Apple Silicon, Xcode 26 / Swift 6 toolchain
- For live runs: LLM rewrite enabled in Settings → Models (local backend), suggestions enabled (default hotkey ⌃⌥S)

## Build & automated validation

```bash
swift build                                   # clean build required (constitution gate)
swift test                                    # full suite green (output shown)

# Feature-focused slices:
swift test --filter SuggestionStreamParserTests    # incremental extraction + chunked parity corpus (SC-002)
swift test --filter SuggestionSessionTests         # incremental events, numbering + highlight stability
swift test --filter SuggestionStreamingFlowTests   # end-to-end with streaming fake engine (SC-003/SC-004)
swift test --filter SuggestionControllerFlowTests  # 015 regression incl. batch-degrade path (SC-005)
```

Expected: all green. The parity corpus chunks every batch-parser fixture at every split point — a failure there means streaming would have shown different text than 015 (release blocker).

## Manual validation (live app)

```bash
swift run Bark   # or scripts/make-dmg.sh + install
```

1. **Progressive fill (US1)**: Focus a terminal with a visible question, press ⌃⌥S. Expect: overlay appears immediately ("Reading screen…" → "Thinking…" with an **Other… row already present**), then candidate 1 appears alone, then 2–4 fill in below with a "more coming…" footer; footer disappears when the set completes. Rows never renumber or reorder.
2. **Early selection (US2)**: Press ⌃⌥S, hit `1` the moment the first candidate shows. Expect: overlay dismisses instantly, exactly that text inserted, no late rows flash, no extra generation afterward (Activity Monitor GPU settles).
3. **Cancel mid-stream (US2)**: Press ⌃⌥S, press Escape while candidates are arriving. Expect: overlay gone, nothing inserted, no reappearing UI.
4. **Other… before first candidate (US3/FR-012)**: Press ⌃⌥S and hit `O` during "Thinking…". Expect: one-shot dictation starts; generation abandoned.
5. **Secure-field refusal (unchanged)**: Focus a password field, press ⌃⌥S. Expect: "Not available here" — nothing captured, nothing generated.
6. **Degrade (FR-010)**: Settings → Suggest → Custom endpoint (any OpenAI-compatible server). Expect: 015 behavior — candidates appear together; all interactions identical.

## Performance evidence (SC-001)

Before merging, capture on the reference machine (M3 Pro), local backend, same prompt corpus:

```bash
# pre-streaming baseline: main @ pre-016 merge-base; streamed: this branch
# metric: hotkey → first selectable candidate (log timestamps or screen recording)
```

Record median of ≥5 runs each in the PR description. Target: ≥40% reduction.
