import XCTest
@testable import BarkCore
@testable import BarkEngines

/// Protocol-conformance tests for the WhisperKit / Parakeet engines. These
/// stubs always compile (lean or extras build); the real implementations only
/// compile under the `#if WHISPERKIT` / `#if FLUIDAUDIO` flags. Either way, the
/// type conforms to `STTEngine` and behaves per its documented contract.
final class STTEngineStubTests: XCTestCase {

    // MARK: - Lean build: stubs throw a useful error

    func testWhisperKitStubThrowsWhenNotCompiledIn() async throws {
        if STTBackendCompilationFlags.whisperKit { return }   // skip on extras build
        let engine = WhisperKitEngine()
        do {
            try await engine.prepare(locale: "en-US")
            XCTFail("expected .engineFailure")
        } catch STTError.engineFailure(let message) {
            XCTAssertTrue(message.contains("WhisperKit"))
            XCTAssertTrue(message.contains("Package-stt-extras.swift"))
        }
    }

    func testParakeetStubThrowsWhenNotCompiledIn() async throws {
        if STTBackendCompilationFlags.fluidAudio { return }
        let engine = ParakeetEngine()
        do {
            try await engine.prepare(locale: "en-US")
            XCTFail("expected .engineFailure")
        } catch STTError.engineFailure(let message) {
            XCTAssertTrue(message.contains("Parakeet"))
            XCTAssertTrue(message.contains("Package-stt-extras.swift"))
        }
    }

    // MARK: - Lean build: feed / cancel are safe no-ops

    func testStubFeedAndCancelAreSafe() async {
        // The stub's feed/cancel/finish must not crash, even though prepare
        // throws. The pipeline's per-frame loop never calls those on a
        // not-prepared stub, but defensive callers (tests, future wiring) can.
        let wk = WhisperKitEngine()
        await wk.feed(AudioFrames(samples: [0.1, 0.2, 0.3]))
        await wk.cancel()
        try? await wk.finishStream()

        let pa = ParakeetEngine()
        await pa.feed(AudioFrames(samples: [0.4, 0.5]))
        await pa.cancel()
        try? await pa.finishStream()
    }

    // MARK: - Round-trip through Settings (the setting shape)

    func testSTTBackendIDRoundTripsThroughSettings() throws {
        let payload = """
        {"selectedModeID":"clean","localeID":"en-US","sttBackend":"whisperkit"}
        """
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(payload.utf8))
        XCTAssertEqual(decoded.sttBackend, .whisperkit)
    }

    func testSTTBackendIDDefaultsWhenMissing() throws {
        // An old payload (pre-PR) without sttBackend must decode with .apple.
        let payload = """
        {"selectedModeID":"clean","localeID":"en-US"}
        """
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(payload.utf8))
        XCTAssertEqual(decoded.sttBackend, .apple)
    }

    func testUnknownSTTBackendIDFallsBackOnDecode() throws {
        // A setting from a future build with a backend we don't know MUST NOT
        // throw; the tolerant init(from:) in STTBackendID falls back to .apple
        // so the user's other settings are preserved.
        let payload = """
        {"selectedModeID":"clean","localeID":"en-US","sttBackend":"future-model-v99"}
        """
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(payload.utf8))
        XCTAssertEqual(decoded.sttBackend, .apple)
    }
}