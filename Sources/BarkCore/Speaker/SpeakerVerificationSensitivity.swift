import Foundation

/// User-chosen matching strictness for the speaker gate. Mirrors `VADSensitivity`
/// in shape and file location.
///
/// Higher = stricter = fewer *other* voices pass, at the cost of occasionally
/// re-declining the user's own voice. The thresholds are **starting points**,
/// calibrated on real device captures before release (research D3 / SC-007).
public enum SpeakerVerificationSensitivity: String, Sendable, CaseIterable, Codable, Identifiable {
    case low, medium, high

    public var id: String { rawValue }

    /// Minimum cosine similarity (utterance vs. enrolled centroid) to accept.
    public var acceptThreshold: Float {
        switch self {
        case .low: return 0.40
        case .medium: return 0.50
        case .high: return 0.62
        }
    }

    public var label: String {
        switch self {
        case .low: return "Low (lenient)"
        case .medium: return "Medium"
        case .high: return "High (strict — shared rooms)"
        }
    }
}
