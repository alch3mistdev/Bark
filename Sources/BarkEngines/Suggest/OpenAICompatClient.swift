import Foundation
import BarkCore

/// `SuggestionEngine` over an OpenAI-compatible chat-completions endpoint
/// (015 FR-013): covers Ollama, LM Studio, and cloud providers behind one
/// schema. Opt-in with a privacy warning (constitution v2.0.0 Principle I /
/// ADR-010); the Bearer header is attached only when a key exists (Ollama is
/// keyless). Failures map to typed `SuggestionError`s so the controller can
/// fall back toward the local engine (R8).
public final class OpenAICompatClient: SuggestionEngine, Sendable {
    private let endpoint: String
    private let model: String
    private let apiKey: String?
    private let urlSession: URLSession

    public init(endpoint: String, model: String, apiKey: String?,
                urlSession: URLSession = OpenAICompatClient.makeSession()) {
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey
        self.urlSession = urlSession
    }

    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral   // no cache/cookies of prompt content
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }

    public var isAvailable: Bool {
        get async { !endpoint.isEmpty && !model.isEmpty }
    }

    public func suggest(_ request: SuggestionRequest) async throws -> String {
        guard let url = Self.chatCompletionsURL(base: endpoint) else {
            throw SuggestionError.endpointNotConfigured
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body = ChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: request.system),
                .init(role: "user", content: request.user),
            ],
            max_tokens: 256,
            temperature: 0
        )
        urlRequest.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: urlRequest)
        } catch {
            throw SuggestionError.network((error as NSError).localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SuggestionError.badResponse("not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SuggestionError.http(http.statusCode)
        }
        guard let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let content = decoded.choices.first?.message.content else {
            throw SuggestionError.badResponse("missing choices[0].message.content")
        }
        return content
    }

    /// Accepts a base URL with or without `/v1` or a trailing slash.
    static func chatCompletionsURL(base: String) -> URL? {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.hasSuffix("/chat/completions") { return URL(string: trimmed) }
        return URL(string: trimmed + "/chat/completions")
    }

    // MARK: - Wire types (OpenAI chat-completions subset)

    struct ChatRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let messages: [Message]
        let max_tokens: Int
        let temperature: Double
    }

    struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }
}
