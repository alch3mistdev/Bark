import Foundation

/// Result of evaluating one utterance against the enrolled voiceprint. Drives the
/// hands-free gate branch.
///
/// Only `.reject`/`.borderline` suppress injection; every other case — including
/// `.tooShort` and `.notEnrolled` — injects (fail-open, FR-009). `borderline`
/// gates identically to `reject`; it exists so the caller can locally log
/// near-misses for threshold calibration (research D3).
public enum SpeakerDecision: Sendable, Equatable {
    /// similarity ≥ threshold → inject.
    case accept(score: Float)
    /// similarity < threshold − margin (gate ran) → suppress, faint cue, keep listening.
    case reject(score: Float)
    /// threshold − margin ≤ similarity < threshold → gates as reject; logged for calibration.
    case borderline(score: Float)
    /// utterance below the voiced-duration floor → inject (fail-open).
    case tooShort
    /// no usable profile (none / disabled / model-incompatible) → inject (fail-open).
    case notEnrolled

    /// Whether this decision permits injection. Only `reject`/`borderline` block.
    public var allowsInjection: Bool {
        switch self {
        case .reject, .borderline: return false
        case .accept, .tooShort, .notEnrolled: return true
        }
    }
}

/// Pure decision logic for the speaker gate. No I/O, no dependencies, total and
/// deterministic — fully unit-testable in the lean build.
public struct SpeakerVerifier: Sendable {
    public init() {}

    /// Decide whether `utterance` matches the enrolled `profile`.
    ///
    /// - `profile == nil` ⇒ `.notEnrolled`.
    /// - else `score = cosineSimilarity(utterance, profile.centroid)`:
    ///   - `score ≥ threshold` ⇒ `.accept`
    ///   - `threshold − margin ≤ score < threshold` ⇒ `.borderline`
    ///   - `score < threshold − margin` ⇒ `.reject`
    ///
    /// `.tooShort` is decided **by the caller** (voiced-duration check) before
    /// embedding — never produced here.
    public func decide(
        utterance: SpeakerEmbedding,
        profile: SpeakerProfile?,
        threshold: Float,
        borderlineMargin: Float = 0.05
    ) -> SpeakerDecision {
        guard let profile else { return .notEnrolled }
        let score = SpeakerEmbedding.cosineSimilarity(utterance, profile.centroid)
        if score >= threshold { return .accept(score: score) }
        if score >= threshold - borderlineMargin { return .borderline(score: score) }
        return .reject(score: score)
    }
}
