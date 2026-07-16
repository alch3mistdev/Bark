import XCTest
@testable import BarkCore
@testable import BarkEngines

/// Wire-level contract of the external backend (015 T037): request shape,
/// Bearer only with a key, and typed errors for 401 / timeout / malformed
/// bodies so the controller can fall back toward the local engine (R8).
final class OpenAICompatClientTests: XCTestCase {
    /// URLProtocol stub: scripts one response (or error) per test and records
    /// the outgoing request.
    final class StubURLProtocol: URLProtocol {
        nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
        nonisolated(unsafe) static var lastRequest: URLRequest?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lastRequest = request
            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
            }
            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private func makeClient(apiKey: String? = nil) -> OpenAICompatClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return OpenAICompatClient(endpoint: "http://localhost:11434/v1", model: "qwen3:8b",
                                  apiKey: apiKey, urlSession: URLSession(configuration: configuration))
    }

    private func respond(status: Int, body: String) -> @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
             Data(body.utf8))
        }
    }

    private let request = SuggestionRequest(system: "sys", user: "usr")

    override func tearDown() {
        StubURLProtocol.handler = nil
        StubURLProtocol.lastRequest = nil
        super.tearDown()
    }

    func testSuccessParsesContentAndShapesRequest() async throws {
        StubURLProtocol.handler = respond(status: 200, body: #"""
            {"choices":[{"message":{"role":"assistant","content":"[\"Run the tests\", \"Ship it\"]"}}]}
            """#)
        let raw = try await makeClient(apiKey: "sk-test").suggest(request)
        XCTAssertEqual(raw, #"["Run the tests", "Ship it"]"#)

        let sent = StubURLProtocol.lastRequest
        XCTAssertEqual(sent?.url?.absoluteString, "http://localhost:11434/v1/chat/completions")
        XCTAssertEqual(sent?.httpMethod, "POST")
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = sent?.httpBody ?? sent?.httpBodyStream.map { stream -> Data in
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
            return data
        }
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(body)) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "qwen3:8b")
        XCTAssertEqual(json["temperature"] as? Double, 0)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user"])
        XCTAssertEqual(messages[0]["content"] as? String, "sys")
        XCTAssertEqual(messages[1]["content"] as? String, "usr")
    }

    func testNoAuthorizationHeaderWithoutKey() async throws {
        StubURLProtocol.handler = respond(status: 200, body: #"{"choices":[{"message":{"content":"[]"}}]}"#)
        _ = try await makeClient(apiKey: nil).suggest(request)
        XCTAssertNil(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"))
    }

    func testHTTP401MapsToTypedError() async {
        StubURLProtocol.handler = respond(status: 401, body: #"{"error":"unauthorized"}"#)
        do {
            _ = try await makeClient().suggest(request)
            XCTFail("expected http error")
        } catch {
            XCTAssertEqual(error as? SuggestionError, .http(401))
        }
    }

    func testTransportFailureMapsToNetworkError() async {
        StubURLProtocol.handler = { _ in throw URLError(.timedOut) }
        do {
            _ = try await makeClient().suggest(request)
            XCTFail("expected network error")
        } catch {
            guard case .network = error as? SuggestionError else {
                return XCTFail("expected .network, got \(error)")
            }
        }
    }

    func testMalformedBodyMapsToBadResponse() async {
        StubURLProtocol.handler = respond(status: 200, body: #"{"not":"openai"}"#)
        do {
            _ = try await makeClient().suggest(request)
            XCTFail("expected badResponse")
        } catch {
            guard case .badResponse = error as? SuggestionError else {
                return XCTFail("expected .badResponse, got \(error)")
            }
        }
    }

    func testEndpointURLNormalization() {
        XCTAssertEqual(OpenAICompatClient.chatCompletionsURL(base: "http://x/v1")?.absoluteString,
                       "http://x/v1/chat/completions")
        XCTAssertEqual(OpenAICompatClient.chatCompletionsURL(base: "http://x/v1/")?.absoluteString,
                       "http://x/v1/chat/completions")
        XCTAssertEqual(OpenAICompatClient.chatCompletionsURL(base: "http://x/v1/chat/completions")?.absoluteString,
                       "http://x/v1/chat/completions")
        XCTAssertNil(OpenAICompatClient.chatCompletionsURL(base: "   "))
    }
}
