# Tasks: Context-aware reply options (Smart Replies)

- [x] T001 [BarkCore] `ConversationContext` (+ `bounded`), `BranchOption` (id-stable, value-equal),
  and `ContextProvider` protocol. `Context/ConversationContext.swift`.
- [x] T002 [BarkCore] `BranchSuggester` protocol (`isAvailable` / `prepare` default no-op /
  `suggest(for:maxOptions:)`). `Context/BranchSuggester.swift`.
- [x] T003 [BarkCore] `QuestionClassifier.isYesNoQuestion` (pure). `Context/QuestionClassifier.swift`.
- [x] T004 [BarkCore] `BasicBranchSuggester.suggestions(for:)` — yes/no else generic set (pure).
  `Context/BasicBranchSuggester.swift`.
- [x] T005 [BarkCore] `BranchPromptTemplate` — injection-safe system+user prompt and
  `parse(_:maxOptions:)` (strip markers/quotes, dedupe, bound count & length). `Context/BranchPromptTemplate.swift`.
- [x] T006 [BarkCore] `Settings.smartRepliesEnabled` (default false) + tolerant decode.
- [x] T007 [BarkEngines] `AccessibilityContextReader: ContextProvider` — best-effort AX read of the
  focused window's text with messaging timeout + bounded traversal. `Context/AccessibilityContextReader.swift`.
- [x] T008 [BarkCleanupMLX] `MLXModelHost` shared container (prepare/isLoaded/respond) + lean stub.
- [x] T009 [BarkCleanupMLX] Refactor `MLXTextCleaner` onto `MLXModelHost`; lean stub updated.
- [x] T010 [BarkCleanupMLX] `MLXBranchSuggester` on `MLXModelHost` (+ parse) + lean stub.
- [x] T011 [Bark] DictationController: `smartRepliesEnabled`, `branchSuggesterPresent`,
  `branchOptions` / `branchSuggesting` / `branchUsedLLM` / `branchNotice`; `prepareBranchContext()`,
  `requestLLMSuggestions()`, `chooseBranch(_:)`, `clearBranchSuggestions()`; extract
  `performTargetedInsert` shared by `reinsert`. No state-machine changes.
- [x] T012 [Bark] CompositionRoot: build shared `MLXModelHost`, wire `MLXTextCleaner` +
  `MLXBranchSuggester` + `AccessibilityContextReader` (lean: nil suggester, reader still wired).
- [x] T013 [Bark] MenuContentView: "Smart Replies" section (task-prepares context, option buttons,
  AI-suggestions button, dictate-custom affordance, notice).
- [x] T014 [Bark] SettingsView: Smart Replies toggle (General) + Privacy note.
- [x] T015 [Tests/BarkCore] `BranchSuggestionTests` — classifier, basic suggester, prompt parse/bound.
- [x] T016 [Tests/BarkApp] Fakes: `FakeContextProvider`, `FakeBranchSuggester`; `SmartRepliesTests`
  — off→no read; yes/no; generic; LLM replace; fallback on fail; choose→inject payload, no Return;
  no context→notice.
- [ ] T017 **Verify on macOS** (cannot run here — no Swift toolchain / macOS-26 SDK): lean
  `swift build` + `swift test` green (output shown); MLX target compiles
  (`cp Package-mlx.swift Package.swift && swift build`). Per Principle II this is NOT yet claimed.
- [ ] T018 Adversarial review (Codex + ef-adversary) on the diff; address or document findings.
