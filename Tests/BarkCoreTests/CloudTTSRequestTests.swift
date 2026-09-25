import XCTest
@testable import BarkCore

/// Pure shaping for the cloud TTS path (018): URLs, body, the transmitted-text
/// bound, and voice-list decoding — all without a network.
final class CloudTTSRequestTests: XCTestCase {
    func testSynthesisURLShape() {
        XCTAssertEqual(CloudTTSRequest.synthesisURL(voiceID: "abc")?.absoluteString,
                       "https://api.elevenlabs.io/v1/text-to-speech/abc")
        // Trailing slashes and surrounding whitespace are tolerated.
        XCTAssertEqual(CloudTTSRequest.synthesisURL(base: "  https://example.test/v1///  ",
                                                    voiceID: "v")?.absoluteString,
                       "https://example.test/v1/text-to-speech/v")
    }

    func testSynthesisURLRefusesUnusableInput() {
        XCTAssertNil(CloudTTSRequest.synthesisURL(voiceID: ""))          // no voice
        XCTAssertNil(CloudTTSRequest.synthesisURL(base: "", voiceID: "v"))
        XCTAssertNil(CloudTTSRequest.synthesisURL(base: "   ", voiceID: "v"))
        XCTAssertNil(CloudTTSRequest.synthesisURL(base: "///", voiceID: "v"))
    }

    func testVoicesURLShape() {
        XCTAssertEqual(CloudTTSRequest.voicesURL()?.absoluteString,
                       "https://api.elevenlabs.io/v1/voices")
        XCTAssertNil(CloudTTSRequest.voicesURL(base: ""))
    }

    func testBodyCarriesBoundedTextAndModel() throws {
        let data = try XCTUnwrap(CloudTTSRequest.synthesisBody(text: "  Which audience?  ",
                                                               modelID: "eleven_turbo_v2_5"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["text"] as? String, "Which audience?")   // trimmed
        XCTAssertEqual(json["model_id"] as? String, "eleven_turbo_v2_5")
    }

    func testEmptyModelFallsBackToDefault() throws {
        let data = try XCTUnwrap(CloudTTSRequest.synthesisBody(text: "hi", modelID: "   "))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["model_id"] as? String, CloudTTSRequest.defaultModelID)
        XCTAssertEqual(CloudTTSRequest.defaultModelID, "eleven_flash_v2_5")   // lowest latency
    }

    func testTransmittedTextIsBounded() {
        // FR-008: a runaway reply cannot produce a surprise bill.
        let long = String(repeating: "a", count: CloudTTSRequest.maxCharacters + 500)
        XCTAssertEqual(CloudTTSRequest.boundedText(long).count, CloudTTSRequest.maxCharacters)
        // Short text passes through untouched apart from trimming.
        XCTAssertEqual(CloudTTSRequest.boundedText("\n Which tone? \n"), "Which tone?")
        XCTAssertEqual(CloudTTSRequest.boundedText("   "), "")
    }

    func testVoiceListDecoding() throws {
        let body = #"""
        {"voices":[
          {"voice_id":"21m00Tcm4TlvDq8ikWAM","name":"Rachel","category":"premade"},
          {"voice_id":"x","name":"Custom"},
          {"voice_id":"","name":"Broken"},
          {"voice_id":"y","name":""}
        ]}
        """#
        let voices = try CloudTTSRequest.decodeVoices(Data(body.utf8))
        // Entries missing an id or a name are dropped rather than shown blank.
        XCTAssertEqual(voices.map(\.name), ["Rachel", "Custom"])
        XCTAssertEqual(voices.first?.id, "21m00Tcm4TlvDq8ikWAM")
        XCTAssertEqual(voices.first?.category, "premade")
    }

    func testMalformedVoiceListThrows() {
        XCTAssertThrowsError(try CloudTTSRequest.decodeVoices(Data("not json".utf8))) { error in
            guard case SpeechSynthesisError.badAudio = error as? SpeechSynthesisError ?? .notConfigured else {
                return XCTFail("expected badAudio, got \(error)")
            }
        }
        XCTAssertThrowsError(try CloudTTSRequest.decodeVoices(Data(#"{"other":1}"#.utf8)))
    }

    func testDefaultsAreUsableOutOfTheBox() {
        // A key alone must be enough to speak (FR-004).
        XCTAssertFalse(CloudTTSRequest.defaultVoiceID.isEmpty)
        XCTAssertNotNil(CloudTTSRequest.synthesisURL(voiceID: CloudTTSRequest.defaultVoiceID))
    }

    func testBackendDefaultIsOnDevice() {
        // ADR-012: egress is opt-in.
        XCTAssertEqual(Settings.default.discussionTTSBackend, .system)
        XCTAssertEqual(Settings.default.elevenLabsModelID, CloudTTSRequest.defaultModelID)
    }

    func testSettingsPayloadNeverCarriesAnAPIKey() throws {
        // SC-005: the key lives in the Keychain only. Encode settings with
        // every cloud field populated and prove no key-shaped field exists.
        var s = Settings.default
        s.discussionTTSBackend = .elevenLabs
        s.elevenLabsVoiceID = "voice-123"
        s.elevenLabsModelID = "model-123"
        let data = try JSONEncoder().encode(s)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in json.keys {
            XCTAssertFalse(key.lowercased().contains("apikey"), "unexpected key field: \(key)")
            XCTAssertFalse(key.lowercased().contains("secret"), "unexpected secret field: \(key)")
        }
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("xi-api-key"))
    }
}
