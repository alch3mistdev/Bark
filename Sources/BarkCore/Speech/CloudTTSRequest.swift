import Foundation

/// One voice offered by the cloud provider's account.
public struct ElevenLabsVoice: Sendable, Equatable, Identifiable, Decodable {
    public var id: String
    public var name: String
    public var category: String?

    public init(id: String, name: String, category: String? = nil) {
        self.id = id
        self.name = name
        self.category = category
    }

    private enum CodingKeys: String, CodingKey {
        case id = "voice_id"
        case name
        case category
    }
}

public enum SpeechSynthesisError: Error, Sendable, Equatable {
    case notConfigured            // no key, or no voice
    case http(Int)                // non-2xx
    case transport(String)        // URLSession failure
    case badAudio(String)         // empty or undecodable body
    case deadlineExceeded
}

/// Pure request/response shaping for the cloud TTS path (018). Kept out of
/// `BarkEngines` so URL construction, the text bound, and decoding are all
/// unit-testable without a network — same posture as
/// `OpenAICompatClient.chatCompletionsURL`.
public enum CloudTTSRequest {
    public static let defaultBaseURL = "https://api.elevenlabs.io/v1"
    /// Lowest-latency model ElevenLabs publishes (~75 ms TTFB), which is what
    /// a conversational turn needs; user-editable for higher-quality models.
    public static let defaultModelID = "eleven_flash_v2_5"
    /// "Rachel" — a long-standing default voice on every account, so the
    /// feature speaks as soon as a key is entered, before any voice fetch.
    public static let defaultVoiceID = "21m00Tcm4TlvDq8ikWAM"
    /// Hard bound on transmitted text. A reply is one or two sentences; this
    /// only exists so a runaway generation cannot produce a surprise bill.
    public static let maxCharacters = 2000

    /// `POST {base}/text-to-speech/{voiceID}`.
    public static func synthesisURL(base: String = defaultBaseURL, voiceID: String) -> URL? {
        guard !voiceID.isEmpty else { return nil }
        guard let root = normalizedBase(base) else { return nil }
        return URL(string: root + "/text-to-speech/" + voiceID)
    }

    /// `GET {base}/voices`.
    public static func voicesURL(base: String = defaultBaseURL) -> URL? {
        guard let root = normalizedBase(base) else { return nil }
        return URL(string: root + "/voices")
    }

    /// Trims whitespace and trailing slashes; nil for an unusable base.
    static func normalizedBase(_ base: String) -> String? {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty, URL(string: trimmed) != nil else { return nil }
        return trimmed
    }

    /// The text actually transmitted: trimmed and bounded (FR-008).
    public static func boundedText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters else { return trimmed }
        return String(trimmed.prefix(maxCharacters))
    }

    struct Body: Encodable {
        let text: String
        let model_id: String
    }

    /// JSON body for a synthesis request. Returns nil only if encoding fails.
    public static func synthesisBody(text: String, modelID: String) -> Data? {
        let model = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return try? JSONEncoder().encode(
            Body(text: boundedText(text),
                 model_id: model.isEmpty ? defaultModelID : model)
        )
    }

    private struct VoicesResponse: Decodable {
        let voices: [ElevenLabsVoice]
    }

    /// Decode `GET /voices`, dropping entries missing an id or name.
    public static func decodeVoices(_ data: Data) throws -> [ElevenLabsVoice] {
        guard let response = try? JSONDecoder().decode(VoicesResponse.self, from: data) else {
            throw SpeechSynthesisError.badAudio("unparseable voice list")
        }
        return response.voices.filter { !$0.id.isEmpty && !$0.name.isEmpty }
    }
}
