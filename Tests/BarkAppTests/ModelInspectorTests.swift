import XCTest
@testable import BarkCore
@testable import BarkEngines

final class ModelInspectorTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bark-inspector-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    // MARK: - Empty / foreign

    func testEmptyDirectoryProducesEmptySnapshot() async {
        let inspector = ModelInspector(directory: tempDir)
        let snap = await inspector.snapshot()
        XCTAssertEqual(snap.models.count, 0)
        XCTAssertEqual(snap.totalBytes, 0)
    }

    func testForeignFilesAreIgnored() async throws {
        // A file that doesn't match our `<backend>--<model>.bin` naming is left
        // out of the snapshot (not deleted — we never mutate files we don't own).
        try "junk".write(to: tempDir.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        try Data(repeating: 0x42, count: 16).write(to: tempDir.appendingPathComponent("garbage.bin"))
        let snap = await ModelInspector(directory: tempDir).snapshot()
        XCTAssertEqual(snap.models.count, 0)
        // Foreign files still count toward totalBytes (the snapshot lists the
        // directory as-is; the UI can surface this for awareness).
        XCTAssertGreaterThan(snap.totalBytes, 0)
    }

    // MARK: - Caching contract

    func testModelsAreListedAndSorted() async throws {
        // Pre-populate two cached files with known sizes.
        try writeCache(backend: .whisperkit, modelID: "z-model", payload: Data(repeating: 0, count: 100))
        try writeCache(backend: .parakeet, modelID: "a-model", payload: Data(repeating: 1, count: 200))

        let snap = await ModelInspector(directory: tempDir).snapshot()
        XCTAssertEqual(snap.models.count, 2)
        // Sorted by id (= backend/modelID), so a-model (parakeet) comes first.
        XCTAssertEqual(snap.models[0].id, "parakeet/a-model")
        XCTAssertEqual(snap.models[1].id, "whisperkit/z-model")
        XCTAssertEqual(snap.totalBytes, 300)
    }

    func testRemovalDropsOneEntry() async throws {
        try writeCache(backend: .whisperkit, modelID: "x", payload: Data(repeating: 0, count: 50))
        try writeCache(backend: .parakeet, modelID: "y", payload: Data(repeating: 1, count: 50))
        let inspector = ModelInspector(directory: tempDir)
        var snap = await inspector.snapshot()
        XCTAssertEqual(snap.models.count, 2)

        let target = snap.models.first { $0.id == "whisperkit/x" }!
        await inspector.remove(target)
        snap = await inspector.snapshot()
        XCTAssertEqual(snap.models.count, 1)
        XCTAssertEqual(snap.models.first?.id, "parakeet/y")
    }

    func testRemovalIsIdempotent() async {
        let inspector = ModelInspector(directory: tempDir)
        let bogus = CachedModel(backend: .apple, modelID: "missing",
                                url: tempDir.appendingPathComponent("apple--missing.bin"),
                                sizeBytes: 0, modifiedAt: .distantPast,
                                verification: .notVerified(reason: ""))
        await inspector.remove(bogus)   // must not throw
    }

    // MARK: - Verification (without a bundled manifest)

    func testVerifyWithNoBundledManifestReportsNoManifestFound() async throws {
        try writeCache(backend: .whisperkit, modelID: "any",
                       payload: Data("any payload".utf8))
        let inspector = ModelInspector(directory: tempDir)
        var snap = await inspector.snapshot()
        let model = snap.models[0]
        XCTAssertEqual(model.verification, .noManifestFound)
        let verified = await inspector.verify(model)
        XCTAssertEqual(verified.verification, .noManifestFound)
        snap.models[0] = verified
        _ = snap
    }

    // MARK: - Verification result coverage

    func testVerifyWithoutBundledManifestDoesNotReportVerified() async throws {
        try writeCache(backend: .parakeet, modelID: "tdt", payload: Data(repeating: 7, count: 1024))
        let snap = await ModelInspector(directory: tempDir).snapshot()
        let model = snap.models[0]
        XCTAssertEqual(model.verification, .noManifestFound)
        let verified = await ModelInspector(directory: tempDir).verify(model)
        XCTAssertEqual(verified.verification, .noManifestFound)
    }

    // MARK: - Helpers

    private func writeCache(backend: STTBackendID, modelID: String, payload: Data) throws {
        let url = tempDir.appendingPathComponent("\(backend.rawValue)--\(modelID).bin")
        try payload.write(to: url, options: .atomic)
    }
}