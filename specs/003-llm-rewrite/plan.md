# Implementation Plan: On-device LLM rewrite

**Branch**: `003-llm-rewrite` | **Spec**: ./spec.md

## Approach
- **Model lifecycle separate from generation.** Add `TextCleaner.prepare(progress:)` (default no-op).
  `MLXTextCleaner.prepare` downloads+loads Qwen3-4B via `#huggingFaceLoadModelContainer(configuration:
  progressHandler:)`; `isAvailable` becomes true only once the container is loaded. `clean()` requires a
  loaded container (no lazy download), so the per-utterance 8 s deadline only ever wraps generation.
- **Controller drives it.** `LLMStatus { unavailable, notLoaded, downloading(Double), ready, failed }`
  published for UI. Enabling the toggle (or launch with it persisted on) calls `prepareLLM()` which runs
  `prepare(progress:)` and updates status on the main actor. `produceText` still gates on
  `await llm.isAvailable`, so until "Ready" the LLM modes fall back to the deterministic cleaner — no
  hang, no timeout.
- **Settings UI.** General → Cleanup shows the toggle (enabled when the engine is compiled in) + a live
  status row (Not downloaded / Downloading N% / Ready / Failed) + a "Download model (~2.5 GB)" button.
- **Shipped build uses MLX.** Keep the lean `Package.swift` as the default for fast offline `swift test`;
  build the DMG from `Package-mlx.swift` via `BARK_MLX=1 scripts/make-dmg.sh` (env var; swaps manifest,
  builds, restores). The MLX target + MLX app already compile/link (verified increment 1). LLM is
  opt-in: `Settings.llmEnabled` defaults to **false**, so no model downloads until the user enables it
  (consent); `activate()` only warms the model if the user previously opted in.

## Constitution Check
- I (Offline): model download is the sanctioned, user-initiated network event; offline after. PASS.
- IV: LLM output still passes sanitizer + OutputValidator + injection guards (unchanged). PASS.
- V (non-blocking): download is a separate observable step; generation stays under the deadline. PASS.

## Files
```
Sources/BarkCore/Cleanup/TextCleaner.swift          (+ prepare(progress:) default no-op)
Sources/BarkCleanupMLX/MLXTextCleaner.swift         (prepare with progress; clean requires loaded model)
Sources/Bark/DictationController.swift              (LLMStatus, llmStatus, llmEnginePresent, prepareLLM)
Sources/Bark/UI/SettingsView.swift                  (LLM status + download button)
scripts/make-dmg.sh                                 (BARK_MLX manifest swap)
```

## Risks
- Runtime 2.5 GB HF download can't be fully exercised here; verified by API/types + that the MLX target
  and MLX app build. Document that the first download happens on the user's machine.
- `prepare` progress callback is `@Sendable` off-main → hop to `@MainActor` to update status.
