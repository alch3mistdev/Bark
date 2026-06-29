# Contract: TextCleaner.refine + refine PromptTemplate

The generative half of the second stage. A new `TextCleaner` capability plus a fenced prompt, both
reusing the existing prompt-injection defense.

## TextCleaner.refine (`BarkCore/Cleanup/TextCleaner.swift`)

```swift
public protocol TextCleaner: Sendable {
    // … existing isAvailable / prepare / clean / cleanStream …

    /// Apply a spoken `instruction` to `text` under `mode`. Default impl throws
    /// `.modelUnavailable` — only LLM-backed cleaners refine.
    func refine(_ text: String, instruction: String, mode: Mode) async throws -> String
}

public extension TextCleaner {
    func refine(_ text: String, instruction: String, mode: Mode) async throws -> String {
        throw CleanupError.modelUnavailable
    }
}
```

- `BasicTextCleaner` inherits the default (declines) → the lean build has no second stage (FR-011).
- `MLXTextCleaner` overrides it (below). `FakeCleaner` (tests) returns a canned/failing/hanging result
  to exercise success, validation-failure, and timeout.

## MLXTextCleaner.refine (`BarkCleanupMLX/MLXTextCleaner.swift`)

1. Build messages: system = `PromptTemplate.refineSystem(for: mode)`; user =
   `PromptTemplate.refineUser(draft: text, instruction: instruction)`.
2. Run the model (same session/runtime as `clean`).
3. Validate: `OutputValidator.validate(output, against: text)` (length/empty guard); throw on reject.
4. The controller wraps the whole call in `withThrowingDeadline(seconds: cleanupDeadline)`; timeout
   ⇒ keep prior draft (FR-009/FR-010).

## PromptTemplate refine additions (`BarkCore/Cleanup/PromptTemplate.swift`)

```swift
public static func refineSystem(for mode: Mode) -> String   // guardrail + (mode.revisionPrompt ?? generic)
public static func refineUser(draft: String, instruction: String) -> String
```

- **Generic instruction** (when `mode.revisionPrompt == nil`): "Apply the user's instruction to the
  text. Keep the author's meaning and facts; output only the rewritten text."
- **Fencing**: draft wrapped in `<text>…</text>`, instruction in `<instruction>…</instruction>`. Both
  strings have their literal closing tags stripped (mirrors `PromptTemplate.user`’s
  `replacingOccurrences(of: closeTag, with: "")`). The guardrail orders the model to treat both
  fenced blocks as data — the instruction directs *how to rewrite the text*, never how to behave
  toward the model (FR-013, OWASP LLM01).

## Behavioral contract

| # | Given | When | Then |
|---|---|---|---|
| 1 | deterministic cleaner | `refine(...)` | throws `.modelUnavailable` |
| 2 | mode with `revisionPrompt` | `refineSystem(for:)` | system text contains that prompt, not the generic |
| 3 | mode with `revisionPrompt == nil` | `refineSystem(for:)` | system text contains the generic instruction |
| 4 | instruction contains `</instruction>` | `refineUser(...)` | the literal closing tag is neutralized |
| 5 | LLM returns 5× the input length | `refine(...)` | `OutputValidator` throws → controller keeps prior draft |
| 6 | LLM exceeds deadline | controller-wrapped `refine(...)` | `CleanupError.timedOut` → keep prior draft |
