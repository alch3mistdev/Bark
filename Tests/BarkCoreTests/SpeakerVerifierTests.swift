import XCTest
@testable import BarkCore

final class SpeakerVerifierTests: XCTestCase {

    // MARK: - SpeakerEmbedding.cosineSimilarity

    func testCosineIdenticalIsOne() {
        let a = SpeakerEmbedding([1, 2, 3, 4])
        XCTAssertEqual(SpeakerEmbedding.cosineSimilarity(a, a), 1.0, accuracy: 1e-5)
    }

    func testCosineOrthogonalIsZero() {
        let a = SpeakerEmbedding([1, 0])
        let b = SpeakerEmbedding([0, 1])
        XCTAssertEqual(SpeakerEmbedding.cosineSimilarity(a, b), 0, accuracy: 1e-6)
    }

    func testCosineOppositeIsMinusOne() {
        let a = SpeakerEmbedding([1, 0, 0])
        let b = SpeakerEmbedding([-1, 0, 0])
        XCTAssertEqual(SpeakerEmbedding.cosineSimilarity(a, b), -1.0, accuracy: 1e-5)
    }

    func testCosineMagnitudeInvariant() {
        // Scaling a vector doesn't change direction → similarity unchanged.
        let a = SpeakerEmbedding([1, 1, 0])
        let b = SpeakerEmbedding([5, 5, 0])
        XCTAssertEqual(SpeakerEmbedding.cosineSimilarity(a, b), 1.0, accuracy: 1e-5)
    }

    func testCosineDimensionMismatchIsZero() {
        let a = SpeakerEmbedding([1, 0, 0])
        let b = SpeakerEmbedding([1, 0])
        XCTAssertEqual(SpeakerEmbedding.cosineSimilarity(a, b), 0)
    }

    func testCosineEmptyOrZeroIsZero() {
        XCTAssertEqual(SpeakerEmbedding.cosineSimilarity(SpeakerEmbedding([]), SpeakerEmbedding([])), 0)
        let zero = SpeakerEmbedding([0, 0, 0])
        XCTAssertEqual(SpeakerEmbedding.cosineSimilarity(zero, SpeakerEmbedding([1, 1, 1])), 0)
    }

    // MARK: - l2normalized

    func testL2NormalizedIsUnitLength() {
        let n = SpeakerEmbedding([3, 4]).l2normalized()   // |[3,4]| = 5
        XCTAssertEqual(n.values[0], 0.6, accuracy: 1e-5)
        XCTAssertEqual(n.values[1], 0.8, accuracy: 1e-5)
    }

    func testL2NormalizedZeroVectorStaysZero() {
        let n = SpeakerEmbedding([0, 0, 0]).l2normalized()
        XCTAssertEqual(n.values, [0, 0, 0])   // no NaN
    }

    // MARK: - mean (centroid)

    func testMeanOfIdenticalVectorsEqualsNormalizedVector() {
        let v = SpeakerEmbedding([1, 0, 0])
        let centroid = SpeakerEmbedding.mean(of: [v, v, v])
        XCTAssertEqual(SpeakerEmbedding.cosineSimilarity(centroid, v), 1.0, accuracy: 1e-5)
    }

    func testMeanIsElementwiseThenNormalized() {
        let a = SpeakerEmbedding([1, 0])
        let b = SpeakerEmbedding([0, 1])
        let centroid = SpeakerEmbedding.mean(of: [a, b])   // mean [0.5,0.5] → normalize → [0.707,0.707]
        XCTAssertEqual(centroid.values[0], 0.7071, accuracy: 1e-3)
        XCTAssertEqual(centroid.values[1], 0.7071, accuracy: 1e-3)
    }

    func testMeanOfEmptyIsEmpty() {
        XCTAssertEqual(SpeakerEmbedding.mean(of: []).values, [])
    }

    func testMeanIgnoresDimensionMismatchedOutliers() {
        let a = SpeakerEmbedding([1, 0, 0])
        let b = SpeakerEmbedding([1, 0, 0])
        let outlier = SpeakerEmbedding([9, 9])   // wrong dim → ignored
        let centroid = SpeakerEmbedding.mean(of: [a, outlier, b])
        XCTAssertEqual(centroid.dimension, 3)
        XCTAssertEqual(SpeakerEmbedding.cosineSimilarity(centroid, a), 1.0, accuracy: 1e-5)
    }

    // MARK: - SpeakerVerifier.decide

    private let verifier = SpeakerVerifier()

    private func profile(_ centroid: [Float], modelID: String = "m") -> SpeakerProfile {
        SpeakerProfile(centroid: SpeakerEmbedding(centroid), sampleCount: 5, enrolledAt: Date(), modelID: modelID)
    }

    func testDecideNilProfileIsNotEnrolled() {
        let d = verifier.decide(utterance: SpeakerEmbedding([1, 0]), profile: nil, threshold: 0.5)
        XCTAssertEqual(d, .notEnrolled)
        XCTAssertTrue(d.allowsInjection)   // fail-open
    }

    func testDecideAcceptAtAndAboveThreshold() {
        let p = profile([1, 0])
        // identical → score 1.0 ≥ 0.5
        if case .accept(let s) = verifier.decide(utterance: SpeakerEmbedding([1, 0]), profile: p, threshold: 0.5) {
            XCTAssertEqual(s, 1.0, accuracy: 1e-5)
        } else { XCTFail("expected accept") }
    }

    func testDecideExactThresholdIsAccept() {
        // Construct an utterance whose cosine to [1,0] is exactly 0.5: angle 60°.
        let u = SpeakerEmbedding([0.5, 0.8660254])   // cos = 0.5
        let d = verifier.decide(utterance: u, profile: profile([1, 0]), threshold: 0.5)
        guard case .accept = d else { return XCTFail("threshold should accept (>=), got \(d)") }
    }

    func testDecideBorderlineWithinMargin() {
        // cos ≈ 0.47 with threshold 0.5, margin 0.05 → [0.45,0.5) → borderline.
        let u = SpeakerEmbedding([0.47, 0.88259])    // cos ≈ 0.47
        let d = verifier.decide(utterance: u, profile: profile([1, 0]), threshold: 0.5, borderlineMargin: 0.05)
        guard case .borderline = d else { return XCTFail("expected borderline, got \(d)") }
        XCTAssertFalse(d.allowsInjection)            // borderline gates as reject
    }

    func testDecideRejectBelowMargin() {
        let u = SpeakerEmbedding([0, 1])             // cos 0 < 0.45
        let d = verifier.decide(utterance: u, profile: profile([1, 0]), threshold: 0.5)
        guard case .reject = d else { return XCTFail("expected reject, got \(d)") }
        XCTAssertFalse(d.allowsInjection)
    }

    // MARK: - Sensitivity → threshold

    func testSensitivityThresholds() {
        XCTAssertEqual(SpeakerVerificationSensitivity.low.acceptThreshold, 0.40, accuracy: 1e-6)
        XCTAssertEqual(SpeakerVerificationSensitivity.medium.acceptThreshold, 0.50, accuracy: 1e-6)
        XCTAssertEqual(SpeakerVerificationSensitivity.high.acceptThreshold, 0.62, accuracy: 1e-6)
    }

    func testSensitivityMonotonicAndComplete() {
        XCTAssertEqual(SpeakerVerificationSensitivity.allCases, [.low, .medium, .high])
        XCTAssertLessThan(SpeakerVerificationSensitivity.low.acceptThreshold,
                          SpeakerVerificationSensitivity.medium.acceptThreshold)
        XCTAssertLessThan(SpeakerVerificationSensitivity.medium.acceptThreshold,
                          SpeakerVerificationSensitivity.high.acceptThreshold)
    }

    // MARK: - Profile compatibility

    func testProfileCompatibility() {
        let p = profile([1, 0, 0], modelID: "wespeaker-v2")
        XCTAssertTrue(p.isCompatible(with: "wespeaker-v2"))
        XCTAssertFalse(p.isCompatible(with: "other-model"))
        let empty = SpeakerProfile(centroid: SpeakerEmbedding([]), sampleCount: 0, enrolledAt: Date(), modelID: "wespeaker-v2")
        XCTAssertFalse(empty.isCompatible(with: "wespeaker-v2"))   // empty centroid → incompatible
    }
}
