import Foundation

/// Turns a raw transcript into the final text for a given `Mode`.
/// `BasicTextCleaner` (deterministic) is the always-available default;
/// `MLXTextCleaner` (LLM) is an optional, swappable rewrite backend (ADR-003).
public protocol TextCleaner: Sendable {
    /// Whether this cleaner can run right now (e.g. model loaded).
    var isAvailable: Bool { get async }

    /// Load/download any backing model, reporting 0...1 progress. Deterministic
    /// cleaners have nothing to load (default no-op). Kept separate from `clean`
    /// so a slow first-time download never trips the per-utterance deadline.
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws

    /// Produce the cleaned text. Must be faithful: never invent content.
    func clean(_ text: String, mode: Mode) async throws -> String

    /// Progressive variant for live UI. Default implementation yields the
    /// single `clean(_:mode:)` result.
    func cleanStream(_ text: String, mode: Mode) -> AsyncThrowingStream<String, Error>
}

public extension TextCleaner {
    /// Default: nothing to load.
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {}

    func cleanStream(_ text: String, mode: Mode) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await clean(text, mode: mode)
                    continuation.yield(result)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public enum CleanupError: Error, Sendable, Equatable {
    case modelUnavailable
    case timedOut
    case outputRejected(reason: String)
}
