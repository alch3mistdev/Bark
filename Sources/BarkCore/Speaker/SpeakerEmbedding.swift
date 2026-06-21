import Foundation

/// A fixed-dimension voice vector (256-d for WeSpeaker v2). The only numeric
/// primitive the speaker gate needs: cosine similarity between an utterance and
/// the enrolled centroid.
///
/// Pure, `Sendable`, zero-dependency — every operation is total and never traps,
/// so a degenerate vector degrades to a safe `0` similarity rather than crashing
/// (keeps the surrounding gate fail-open; see `SpeakerVerifier`).
public struct SpeakerEmbedding: Codable, Sendable, Equatable {
    /// Raw vector. Expected L2-normalized for similarity math, but the operations
    /// below normalize defensively so an un-normalized input still behaves.
    public let values: [Float]

    public init(_ values: [Float]) {
        self.values = values
    }

    /// Vector dimension.
    public var dimension: Int { values.count }

    /// Unit-length copy. A zero (or empty) vector has no direction → returns the
    /// vector unchanged (all-zeros), never NaN.
    public func l2normalized() -> SpeakerEmbedding {
        var sumSq: Float = 0
        for v in values { sumSq += v * v }
        let norm = sumSq.squareRoot()
        guard norm > 0 else { return self }
        return SpeakerEmbedding(values.map { $0 / norm })
    }

    /// Cosine similarity in −1…1. Returns `0` (orthogonal/“can’t tell”) if the
    /// dimensions differ or either vector is empty/zero — never traps, never NaN.
    public static func cosineSimilarity(_ a: SpeakerEmbedding, _ b: SpeakerEmbedding) -> Float {
        guard a.dimension == b.dimension, a.dimension > 0 else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.values.count {
            let x = a.values[i], y = b.values[i]
            dot += x * y
            na += x * x
            nb += y * y
        }
        let denom = (na.squareRoot()) * (nb.squareRoot())
        guard denom > 0 else { return 0 }
        return dot / denom
    }

    /// Enrollment centroid: element-wise mean of the sample embeddings, then
    /// re-normalized to unit length. Returns an empty embedding for an empty
    /// input; ignores dimension-mismatched outliers defensively (uses the first
    /// embedding's dimension as the reference).
    public static func mean(of embeddings: [SpeakerEmbedding]) -> SpeakerEmbedding {
        guard let first = embeddings.first, first.dimension > 0 else {
            return SpeakerEmbedding([])
        }
        let dim = first.dimension
        var sum = [Float](repeating: 0, count: dim)
        var n = 0
        for e in embeddings where e.dimension == dim {
            for i in 0..<dim { sum[i] += e.values[i] }
            n += 1
        }
        guard n > 0 else { return SpeakerEmbedding([]) }
        let inv = 1 / Float(n)
        for i in 0..<dim { sum[i] *= inv }
        return SpeakerEmbedding(sum).l2normalized()
    }
}
