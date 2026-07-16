import Foundation

/// Which engine generates suggestions (015 FR-013). `local` = the on-device
/// MLX model (rides the existing `llmEnabled` consent); `external` = a
/// user-configured OpenAI-compatible endpoint (opt-in, warned, ADR-010).
public enum SuggestionBackendID: String, Codable, Sendable, CaseIterable, Identifiable {
    case local
    case external
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .local: return "On-device model"
        case .external: return "Custom endpoint"
        }
    }
}

/// One fully-assembled suggestion request. `system`/`user` come exclusively
/// from `SuggestionPrompt` so the injection guardrail can't be bypassed.
public struct SuggestionRequest: Sendable, Equatable {
    public var system: String
    public var user: String
    public var maxCandidates: Int

    public init(system: String, user: String, maxCandidates: Int = 4) {
        self.system = system
        self.user = user
        self.maxCandidates = maxCandidates
    }
}

/// Generates candidate responses from screen context (015). Deliberately NOT
/// `TextCleaner` — that contract is "faithful rewrite, never invent"; this one
/// is generative. Returns the model's RAW text; the caller parses/validates
/// via `SuggestionResponseParser` so malformed output never reaches an
/// injector. Concrete impls: `MLXTextCleaner` (shared model residency) and
/// `OpenAICompatClient` (BarkEngines).
public protocol SuggestionEngine: Sendable {
    var isAvailable: Bool { get async }
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws
    func suggest(_ request: SuggestionRequest) async throws -> String
    func unload() async
}

public extension SuggestionEngine {
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {}
    func unload() async {}
}

public enum SuggestionError: Error, Sendable, Equatable {
    case engineUnavailable
    case timedOut
    case noValidCandidates
    case emptyContext
    case endpointNotConfigured
    case http(Int)                 // non-2xx from the external endpoint
    case network(String)           // transport failure
    case badResponse(String)       // endpoint replied with an unparseable body
}

/// Stores the external endpoint's API key. Real impl (`KeychainSecretStore`,
/// BarkEngines) uses the Keychain — the key NEVER enters the Settings JSON
/// (FR-013); tests inject an in-memory fake.
public protocol SecretStore: Sendable {
    func read(account: String) -> String?
    func write(_ secret: String, account: String) throws
    func delete(account: String)
}
