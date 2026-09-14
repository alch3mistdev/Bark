import Foundation

/// Which engine speaks discussion replies (018). `system` is the on-device
/// `AVSpeechSynthesizer` and the default; `elevenLabs` is an explicit,
/// warned opt-in that transmits the reply text (ADR-012, mirroring ADR-010).
public enum DiscussionTTSBackend: String, Codable, Sendable, CaseIterable, Identifiable {
    case system
    case elevenLabs

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system: return "On-device system voice"
        case .elevenLabs: return "ElevenLabs (sends text)"
        }
    }
}
