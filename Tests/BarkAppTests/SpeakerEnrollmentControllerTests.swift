import XCTest
@testable import BarkCore
@testable import Bark

/// 014: the enrollment controller had real, deterministic logic (VAD capture,
/// take validation, centroid averaging, fail-closed persistence) and zero tests
/// — all the fakes it needs already existed.
@MainActor
final class SpeakerEnrollmentControllerTests: XCTestCase {
    /// One good take: 3 loud frames (VAD onset at 2) + 9 silent (hangover 8).
    /// Yields ~17,600 samples ≥ the 16,000 minimum, meanRMS ≈ 0.033 ≥ 0.01.
    private static let goodTake: [Float] =
        [Float](repeating: 0.3, count: 3) + [Float](repeating: 0, count: 9)

    /// Audible to the VAD (0.013 ≥ medium threshold 0.012) but the take's mean
    /// RMS lands ≈ 0.0014 < the 0.01 loudness floor → must ask for a redo.
    private static let quietTake: [Float] =
        [Float](repeating: 0.013, count: 3) + [Float](repeating: 0, count: 9)

    private func make(embedder: FakeSpeakerEmbedder,
                      store: InMemorySpeakerProfileStore,
                      script: [Float]) -> SpeakerEnrollmentController {
        SpeakerEnrollmentController(
            embedder: embedder,
            store: store,
            audioFactory: { ScriptedAudioCapture(rmsLevels: script, autoFinish: true) },
            sensitivity: { .medium }
        )
    }

    private func wait(_ predicate: @escaping () -> Bool) async -> Bool {
        for _ in 0..<200 { if predicate() { return true }; try? await Task.sleep(for: .milliseconds(20)) }
        return false
    }

    func testFiveGoodTakesSaveCentroidAndComplete() async {
        let embedder = FakeSpeakerEmbedder(.embedding(SpeakerEmbedding([1, 0, 0, 0])))
        let store = InMemorySpeakerProfileStore()
        let script = Array(Array(repeating: Self.goodTake, count: 5).joined())
        let c = make(embedder: embedder, store: store, script: script)
        let completed = expectation(description: "onComplete fired")
        c.onComplete = { completed.fulfill() }

        c.start()
        let done = await wait { c.phase == .done }
        XCTAssertTrue(done)
        XCTAssertEqual(c.capturedCount, 5)
        await fulfillment(of: [completed], timeout: 2)

        let profile = await store.load()
        XCTAssertEqual(profile?.sampleCount, 5)
        XCTAssertNotNil(profile?.centroid)
    }

    func testQuietTakeAsksForRedoWithoutCountingIt() async {
        let embedder = FakeSpeakerEmbedder(.embedding(SpeakerEmbedding([1, 0, 0, 0])))
        let store = InMemorySpeakerProfileStore()
        let c = make(embedder: embedder, store: store, script: Self.quietTake)

        c.start()
        let redone = await wait { if case .redo(_, 0) = c.phase { return true } else { return false } }
        XCTAssertTrue(redone)
        XCTAssertEqual(c.capturedCount, 0)   // rejected take never counts
        let profile = await store.load()
        XCTAssertNil(profile)
    }

    func testEmbedderFailureFailsClosed() async {
        // No embedding → no voiceprint, ever. A partial/failed enrollment must
        // never persist anything (fail closed).
        let embedder = FakeSpeakerEmbedder(.failure)
        let store = InMemorySpeakerProfileStore()
        let c = make(embedder: embedder, store: store, script: Self.goodTake)

        c.start()
        let failed = await wait { if case .failed = c.phase { return true } else { return false } }
        XCTAssertTrue(failed)
        let profile = await store.load()
        XCTAssertNil(profile)
    }

    func testCancelDiscardsProgress() async {
        let embedder = FakeSpeakerEmbedder(.embedding(SpeakerEmbedding([1, 0, 0, 0])))
        let store = InMemorySpeakerProfileStore()
        let c = make(embedder: embedder, store: store, script: Self.goodTake)

        c.start()
        c.cancel()
        XCTAssertEqual(c.phase, .idle)
        let profile = await store.load()
        XCTAssertNil(profile)
    }
}
