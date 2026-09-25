import XCTest
import AVFoundation
@testable import BarkCore
@testable import BarkEngines
@testable import Bark

/// 018: the cloud synthesizer against a stubbed endpoint, and the fallback
/// composite that makes "fail toward the local engine" structural.
final class CloudTTSTests: XCTestCase {
    /// URLProtocol stub — scripts one response (or error) and records requests.
    /// Same pattern as `OpenAICompatClientTests`.
    final class CloudStubURLProtocol: URLProtocol {
        nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
        nonisolated(unsafe) static var lastRequest: URLRequest?
        nonisolated(unsafe) static var requestCount = 0
        /// Leaves the request outstanding forever, for the deadline test.
        /// Implemented by returning from `startLoading` WITHOUT notifying the
        /// client — never by sleeping or spinning, because this runs on the
        /// shared URL loading thread and blocking it starves every later test
        /// in the class (which is exactly how this suite first failed).
        nonisolated(unsafe) static var hang = false

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lastRequest = request
            Self.requestCount += 1
            if Self.hang { return }
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

    override func tearDown() {
        CloudStubURLProtocol.handler = nil
        CloudStubURLProtocol.lastRequest = nil
        CloudStubURLProtocol.requestCount = 0
        CloudStubURLProtocol.hang = false
        super.tearDown()
    }

    private func makeSynthesizer(config: CloudTTSConfig,
                                 deadline: Double = 5) -> ElevenLabsSynthesizer {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudStubURLProtocol.self]
        return ElevenLabsSynthesizer(config: CloudTTSConfigStore(config),
                                     urlSession: URLSession(configuration: configuration),
                                     deadline: deadline)
    }

    private func enabledConfig(key: String = "sk-test") -> CloudTTSConfig {
        CloudTTSConfig(enabled: true, apiKey: key, voiceID: "voice-1", modelID: "eleven_flash_v2_5")
    }

    private func respond(status: Int, body: Data) -> @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            (HTTPURLResponse(url: request.url!, statusCode: status,
                             httpVersion: nil, headerFields: nil)!, body)
        }
    }

    private func bodyData(of request: URLRequest?) -> Data? {
        request?.httpBody ?? request?.httpBodyStream.map { stream -> Data in
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
            return data
        }
    }

    // MARK: - Request shape

    func testRequestCarriesKeyHeaderURLAndBody() async throws {
        CloudStubURLProtocol.handler = respond(status: 200, body: Data([0xFF, 0xFB, 0x00]))
        let synth = makeSynthesizer(config: enabledConfig())
        // Audio is deliberately not valid MP3 — we assert the REQUEST here;
        // playback failure surfaces as badAudio, which is a separate test.
        _ = try? await synth.fetchAudio("Which audience is this for?")

        let sent = try XCTUnwrap(CloudStubURLProtocol.lastRequest)
        XCTAssertEqual(sent.url?.absoluteString,
                       "https://api.elevenlabs.io/v1/text-to-speech/voice-1")
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "xi-api-key"), "sk-test")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Accept"), "audio/mpeg")

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(bodyData(of: sent))) as? [String: Any])
        XCTAssertEqual(json["text"] as? String, "Which audience is this for?")
        XCTAssertEqual(json["model_id"] as? String, "eleven_flash_v2_5")
    }

    func testEmptyTextMakesNoRequestAndNoSpend() async {
        CloudStubURLProtocol.handler = respond(status: 200, body: Data([0x01]))
        let synth = makeSynthesizer(config: enabledConfig())
        try? await synth.synthesizeAndPlay("   \n ")
        XCTAssertEqual(CloudStubURLProtocol.requestCount, 0)
    }

    func testDisabledBackendMakesNoRequest() async {
        // SC-004: selecting the on-device voice must not touch the network.
        CloudStubURLProtocol.handler = respond(status: 200, body: Data([0x01]))
        let synth = makeSynthesizer(config: CloudTTSConfig(enabled: false, apiKey: "sk-test"))
        do {
            _ = try await synth.fetchAudio("hello")
            XCTFail("expected notConfigured")
        } catch {
            XCTAssertEqual(error as? SpeechSynthesisError, .notConfigured)
        }
        XCTAssertEqual(CloudStubURLProtocol.requestCount, 0)
    }

    func testMissingKeyMakesNoRequest() async {
        CloudStubURLProtocol.handler = respond(status: 200, body: Data([0x01]))
        let synth = makeSynthesizer(config: CloudTTSConfig(enabled: true, apiKey: ""))
        do {
            _ = try await synth.fetchAudio("hello")
            XCTFail("expected notConfigured")
        } catch {
            XCTAssertEqual(error as? SpeechSynthesisError, .notConfigured)
        }
        XCTAssertEqual(CloudStubURLProtocol.requestCount, 0)
    }

    // MARK: - Failure matrix (US2 / SC-003)

    func testHTTPFailuresMapToTypedErrors() async {
        for status in [401, 403, 429, 500] {
            CloudStubURLProtocol.handler = respond(status: status, body: Data("{}".utf8))
            let synth = makeSynthesizer(config: enabledConfig())
            do {
                _ = try await synth.fetchAudio("hello")
                XCTFail("expected http(\(status))")
            } catch {
                XCTAssertEqual(error as? SpeechSynthesisError, .http(status))
            }
        }
    }

    func testTransportFailureMapsToTransport() async {
        CloudStubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let synth = makeSynthesizer(config: enabledConfig())
        do {
            _ = try await synth.fetchAudio("hello")
            XCTFail("expected transport")
        } catch {
            guard case .transport = error as? SpeechSynthesisError ?? .notConfigured else {
                return XCTFail("expected transport, got \(error)")
            }
        }
    }

    func testEmptyBodyMapsToBadAudio() async {
        CloudStubURLProtocol.handler = respond(status: 200, body: Data())
        let synth = makeSynthesizer(config: enabledConfig())
        do {
            _ = try await synth.fetchAudio("hello")
            XCTFail("expected badAudio")
        } catch {
            XCTAssertEqual(error as? SpeechSynthesisError, .badAudio("empty body"))
        }
    }

    func testUndecodableAudioMapsToBadAudio() async {
        // A 2xx body that isn't audio must fail rather than silently play nothing.
        CloudStubURLProtocol.handler = respond(status: 200, body: Data("this is not mp3".utf8))
        let synth = makeSynthesizer(config: enabledConfig())
        do {
            try await synth.synthesizeAndPlay("hello")
            XCTFail("expected badAudio")
        } catch {
            guard case .badAudio = error as? SpeechSynthesisError ?? .notConfigured else {
                return XCTFail("expected badAudio, got \(error)")
            }
        }
    }

    func testDeadlineFiresAndCancels() async {
        // A request that never completes: the deadline must win.
        CloudStubURLProtocol.hang = true
        let synth = makeSynthesizer(config: enabledConfig(), deadline: 0.2)
        let started = Date()
        do {
            _ = try await synth.fetchAudio("hello")
            XCTFail("expected deadlineExceeded")
        } catch {
            XCTAssertEqual(error as? SpeechSynthesisError, .deadlineExceeded)
        }
        // Proves the turn can't hang: it returned near the deadline, not the
        // URLSession timeout (15 s).
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    // MARK: - Voice list

    func testVoiceFetchDecodesAndSendsKey() async throws {
        CloudStubURLProtocol.handler = respond(
            status: 200,
            body: Data(#"{"voices":[{"voice_id":"a","name":"Rachel"}]}"#.utf8))
        let synth = makeSynthesizer(config: enabledConfig())
        let voices = try await synth.fetchVoices()
        XCTAssertEqual(voices.map(\.name), ["Rachel"])
        XCTAssertEqual(CloudStubURLProtocol.lastRequest?.url?.absoluteString,
                       "https://api.elevenlabs.io/v1/voices")
        XCTAssertEqual(CloudStubURLProtocol.lastRequest?.value(forHTTPHeaderField: "xi-api-key"), "sk-test")
    }

    func testVoiceFetchWorksBeforeBackendIsSwitchedOn() async throws {
        // The user fetches voices while configuring, before selecting the backend.
        CloudStubURLProtocol.handler = respond(
            status: 200, body: Data(#"{"voices":[{"voice_id":"a","name":"Rachel"}]}"#.utf8))
        let synth = makeSynthesizer(config: CloudTTSConfig(enabled: false, apiKey: "sk-test"))
        let fetched = try await synth.fetchVoices()
        XCTAssertEqual(fetched.count, 1)
    }

    func testVoiceFetchWithoutKeyThrowsWithoutRequest() async {
        let synth = makeSynthesizer(config: CloudTTSConfig(enabled: true, apiKey: ""))
        do {
            _ = try await synth.fetchVoices()
            XCTFail("expected notConfigured")
        } catch {
            XCTAssertEqual(error as? SpeechSynthesisError, .notConfigured)
        }
        XCTAssertEqual(CloudStubURLProtocol.requestCount, 0)
    }

    // MARK: - Fallback composite

    /// Primary that fails on demand and records what it was asked to speak.
    final class FakeFalliblePrimary: FallibleSpeechSynthesizing, @unchecked Sendable {
        private let error: SpeechSynthesisError?
        private let lock = NSLock()
        private var _spoken: [String] = []
        private var _stopCount = 0
        var spoken: [String] { lock.lock(); defer { lock.unlock() }; return _spoken }
        var stopCount: Int { lock.lock(); defer { lock.unlock() }; return _stopCount }

        init(failWith error: SpeechSynthesisError?) { self.error = error }

        private func record(_ text: String) {
            lock.lock(); _spoken.append(text); lock.unlock()
        }

        func synthesizeAndPlay(_ text: String) async throws {
            record(text)
            if let error { throw error }
        }

        func stop() { lock.lock(); _stopCount += 1; lock.unlock() }
    }

    /// Local fallback recording what it spoke.
    final class RecordingLocal: SpeechSynthesizing, @unchecked Sendable {
        private let lock = NSLock()
        private var _spoken: [String] = []
        private var _stopCount = 0
        var spoken: [String] { lock.lock(); defer { lock.unlock() }; return _spoken }
        var stopCount: Int { lock.lock(); defer { lock.unlock() }; return _stopCount }
        let voices: [VoiceOption]

        init(voices: [VoiceOption] = []) { self.voices = voices }

        private func record(_ text: String) {
            lock.lock(); _spoken.append(text); lock.unlock()
        }

        func speak(_ text: String, voice: SpeechVoiceConfig?) async {
            record(text)
        }

        func stop() { lock.lock(); _stopCount += 1; lock.unlock() }
        var availableVoices: [VoiceOption] { voices }
    }

    func testSuccessUsesPrimaryOnly() async {
        let primary = FakeFalliblePrimary(failWith: nil)
        let local = RecordingLocal()
        let composite = FallbackSpeechSynthesizer(primary: primary, fallback: local)
        await composite.speak("Which audience?", voice: nil)
        XCTAssertEqual(primary.spoken, ["Which audience?"])
        XCTAssertTrue(local.spoken.isEmpty)   // no double-speak
    }

    func testFailureFallsBackToLocalExactlyOnce() async {
        let primary = FakeFalliblePrimary(failWith: .http(429))
        let local = RecordingLocal()
        let composite = FallbackSpeechSynthesizer(primary: primary, fallback: local)
        await composite.speak("Which tone?", voice: nil)
        XCTAssertEqual(local.spoken, ["Which tone?"])   // spoken on-device instead
    }

    func testFailureIsReportedOncePerConfiguration() async {
        let primary = FakeFalliblePrimary(failWith: .http(401))
        let composite = FallbackSpeechSynthesizer(primary: primary, fallback: RecordingLocal())
        let reports = ReportBox()
        composite.onCloudFailure = { error in reports.record(error) }

        await composite.speak("one", voice: nil)
        await composite.speak("two", voice: nil)
        await composite.speak("three", voice: nil)
        XCTAssertEqual(reports.count, 1)   // FR-012: not one banner per turn

        composite.resetFailureReporting()  // user changed the key/backend
        await composite.speak("four", voice: nil)
        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(reports.last, .http(401))
    }

    func testNotConfiguredIsNeverReportedAsAFailure() async {
        // The ordinary state when the backend is the system voice — a banner
        // here would fire on every turn for a user who never opted in.
        let primary = FakeFalliblePrimary(failWith: .notConfigured)
        let composite = FallbackSpeechSynthesizer(primary: primary, fallback: RecordingLocal())
        let reports = ReportBox()
        composite.onCloudFailure = { error in reports.record(error) }
        await composite.speak("hello", voice: nil)
        XCTAssertEqual(reports.count, 0)
    }

    func testStopForwardsToBothAndVoicesComeFromLocal() {
        let primary = FakeFalliblePrimary(failWith: nil)
        let voice = VoiceOption(identifier: "com.apple.voice.premium.en-US.Ava",
                                name: "Ava", language: "en-US", tier: .premium)
        let local = RecordingLocal(voices: [voice])
        let composite = FallbackSpeechSynthesizer(primary: primary, fallback: local)
        composite.stop()
        XCTAssertEqual(primary.stopCount, 1)
        XCTAssertEqual(local.stopCount, 1)
        // The system picker configures system voices, so the composite exposes those.
        XCTAssertEqual(composite.availableVoices, [voice])
    }

    /// Thread-safe capture of failure callbacks (they arrive off the main actor).
    final class ReportBox: @unchecked Sendable {
        private let lock = NSLock()
        private var errors: [SpeechSynthesisError] = []
        var count: Int { lock.lock(); defer { lock.unlock() }; return errors.count }
        var last: SpeechSynthesisError? { lock.lock(); defer { lock.unlock() }; return errors.last }
        func record(_ error: SpeechSynthesisError) { lock.lock(); errors.append(error); lock.unlock() }
    }
}
