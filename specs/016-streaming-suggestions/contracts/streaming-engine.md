# Contract: SuggestionEngine streaming seam (016)

## Protocol addition (BarkCore/Suggest/SuggestionEngine.swift)

```swift
public protocol SuggestionEngine: Sendable {
    var isAvailable: Bool { get async }
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws
    func suggest(_ request: SuggestionRequest) async throws -> String
    /// Incremental raw output. Each chunk is a well-formed Swift String, but
    /// chunk boundaries carry NO alignment guarantee — they may split JSON
    /// tokens, think tags, or candidate text anywhere. Consumers must parse
    /// incrementally (SuggestionStreamParser).
    func suggestStream(_ request: SuggestionRequest) -> AsyncThrowingStream<String, Error>
    func unload() async
}
```

## Default implementation (the FR-010 degrade path)

```swift
public extension SuggestionEngine {
    func suggestStream(_ request: SuggestionRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(try await self.suggest(request))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
```

## Semantics (binding on all conformers)

| Guarantee | Detail |
|---|---|
| Termination | The stream MUST finish (normally or throwing) exactly once; consumers apply the overall deadline outside. |
| Cancellation | Consumer cancellation (dropping the iteration task) MUST propagate: `onTermination` cancels the producing work; best-effort at the model level. |
| Content | Concatenation of all yielded chunks MUST equal what `suggest(_:)` would have returned for the same request (same raw text, chunked). |
| Errors | Same typed errors as `suggest` (`SuggestionError`, `CleanupError.timedOut` is applied by the caller's deadline, not the engine). |
| Privacy | Chunks MUST NOT be logged or persisted by the engine (constitution Principle I). |

## Conformers in v1

| Conformer | Implementation |
|---|---|
| `MLXTextCleaner` (BarkCleanupMLX) | Native: yields each `streamDetails` chunk; stops after the existing `suggestOutputCharBound` cap. |
| `OpenAICompatClient` (BarkEngines) | Default (batch) — SSE deliberately out of scope (research R2). To adopt streaming later, implement `suggestStream` natively; no other code changes. |
| Test fakes | Scripted chunk sequences with controllable delays/errors. |
