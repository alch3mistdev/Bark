# Tasks: On-device LLM rewrite

- [ ] T001 [BarkCore] `TextCleaner.prepare(progress:)` default no-op.
- [ ] T002 [BarkCleanupMLX] `MLXTextCleaner.prepare(progress:)` (download+load w/ progress);
  `isAvailable` = container loaded; `clean()` requires a loaded container.
- [ ] T003 [Bark] DictationController: `LLMStatus`, `llmStatus`, `llmEnginePresent`, `prepareLLM()`;
  enable-toggle + launch trigger; keep produceText gated on `isAvailable`.
- [ ] T004 [Bark] SettingsView General: toggle enabled when engine present + status row + Download button.
- [ ] T005 [scripts] make-dmg.sh `BARK_MLX=1` manifest swap (build/restore).
- [ ] T006 Verify: lean `swift build`+`swift test` green; MLX target builds; MLX app links; build MLX DMG.
- [ ] T007 Review (Codex + ef-adversary on diff); commit + merge; ship MLX DMG.
