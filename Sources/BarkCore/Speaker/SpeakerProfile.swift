import Foundation

/// The enrolled voiceprint persisted on device. Exactly one per device.
///
/// Holds only the derived centroid — **no raw enrollment audio is retained**.
/// `modelID` stamps which embedding model produced the centroid: if the running
/// embedder reports a different `modelID`, the profile is treated as *not
/// enrolled* (prompt re-enroll) rather than silently mis-scored across
/// incompatible vector spaces.
public struct SpeakerProfile: Codable, Sendable, Equatable {
    /// Mean of the enrollment-sample embeddings (L2-normalized).
    public let centroid: SpeakerEmbedding
    /// Number of phrases averaged into the centroid (target 5).
    public let sampleCount: Int
    /// When the voiceprint was created.
    public let enrolledAt: Date
    /// Embedding-model/version tag (`SpeakerEmbedder.modelID`).
    public let modelID: String

    public init(centroid: SpeakerEmbedding, sampleCount: Int, enrolledAt: Date, modelID: String) {
        self.centroid = centroid
        self.sampleCount = sampleCount
        self.enrolledAt = enrolledAt
        self.modelID = modelID
    }

    /// True when this profile was produced by `embedderModelID`'s vector space and
    /// so can be scored against it. A mismatch ⇒ caller treats it as not enrolled.
    public func isCompatible(with embedderModelID: String) -> Bool {
        modelID == embedderModelID && centroid.dimension > 0
    }
}
