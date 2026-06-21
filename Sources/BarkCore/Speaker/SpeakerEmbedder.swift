import Foundation

/// The single seam between pure `BarkCore` logic and the CoreML/ML adapter in
/// `BarkEngines` — the only place the 256-float extraction crosses the layer
/// boundary (constitution III).
///
/// Callers MUST treat any `throw` as **fail-open**: inject as normal, never block
/// the user's own dictation (FR-009).
public protocol SpeakerEmbedder: Sendable {
    /// Produce a speaker embedding from 16 kHz mono Float PCM samples.
    /// - Returns: an L2-normalized `SpeakerEmbedding` (256-d for WeSpeaker v2).
    /// - Throws: if the model is unavailable or extraction fails.
    func embed(_ samples: [Float]) async throws -> SpeakerEmbedding

    /// Model/version tag stamped into enrolled profiles, so an incompatible stored
    /// voiceprint is detected and re-enrollment is prompted (see `SpeakerProfile`).
    var modelID: String { get }
}
