# Contract: DialogueEngine

```swift
public protocol DialogueEngine: Sendable {
    var isAvailable: Bool { get async }

    /// One conversational reply. `system` and `turns` are built exclusively by
    /// DialoguePromptBuilder (fenced). Returns the raw engine text; the caller parses it
    /// with DialogueReplyParser. Implementations bound output (≤ 256 tokens, temperature 0)
    /// and must be cancellable.
    func reply(system: String, turns: [DialogueTurn]) async throws -> String

    /// Final-prompt synthesis over the whole conversation. Plain text out (no JSON wrapper),
    /// bounded (≤ 512 tokens); caller applies the 4 000-char output bound and sanitization.
    func synthesize(system: String, turns: [DialogueTurn]) async throws -> String
}
```

## Wire contract for `reply` output (enforced by prompt, recovered by parser)

The system prompt instructs: respond with exactly one JSON object
`{"reply": "<next Socratic question or statement>", "ready": <true|false>}`.

- `ready: false` — keep exploring.
- `ready: true`, non-empty `reply` — engine believes goals are clear and is asking the user to
  confirm (e.g. "Ready for me to draft it?"). Controller presents it and highlights **Done**.
- `ready: true`, empty `reply` — the user's previous turn was an affirmative answer to that
  question; this is the **synthesis trigger**. The system prompt instructs the model to emit
  exactly this shape when the user confirms.

`DialogueReplyParser` is tolerant: it extracts the first JSON object found in the output
(models may wrap in prose/code fences); on any failure it returns
`(text: rawOutput, ready: false)`. Malformed output can therefore never trigger synthesis
(FR-003 fail-safe).

## Conformers

- `MLXTextCleaner` (`BarkCleanupMLX`, `#if MLXCleanup`): fresh
  `ChatSession(container, instructions: system, history: turns→Chat.Message)` per call
  (research R2); shares model residency with dictation/suggest. Lean build: stub throwing
  `DialogueError.engineUnavailable`.
- `OpenAICompatClient` (`BarkEngines`): same chat-completions endpoint; `messages` =
  `[system] + turns` mapped to roles. Non-streaming (spec assumption).

## Error taxonomy

`DialogueError { engineUnavailable, deadlineExceeded, badResponse(String), transport(String) }`.
Deadlines are the **caller's** job (controller wraps calls: 20 s reply / 30 s synthesize);
conformers just honor cancellation. All errors are retryable in-session; none abort silently.

## Fencing guarantee

`DialoguePromptBuilder` is the only construction path for `system`/`turns` content reaching an
engine. Captured context and every user utterance pass through fixed-point `neutralize`
(SuggestionPrompt pattern) inside tagged blocks; the guardrail preamble is fixed and
non-editable.
