import XCTest
@testable import BarkCore
@testable import BarkEngines

final class ModelManifestTests: XCTestCase {

    // MARK: - sha256Bytes

    func testSha256BytesRoundTripsValidHex() {
        let hex = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
        let manifest = makeManifest(sha256: hex)
        let bytes = manifest.sha256Bytes
        XCTAssertNotNil(bytes)
        XCTAssertEqual(bytes?.count, 32)
    }

    func testSha256BytesLowercasesInput() {
        let hex = "9F86D081884C7D659A2FEAA0C55AD015A3BF4F1B2B0B822CD15D6C15B0F00A08"
        XCTAssertNotNil(makeManifest(sha256: hex).sha256Bytes)
    }

    func testSha256BytesRejectsShort() {
        XCTAssertNil(makeManifest(sha256: "abcd").sha256Bytes)
    }

    func testSha256BytesRejectsNonHex() {
        // 64 chars but with a non-hex character
        let bad = String(repeating: "z", count: 64)
        XCTAssertNil(makeManifest(sha256: bad).sha256Bytes)
    }

    func testSha256BytesRejectsOddLength() {
        XCTAssertNil(makeManifest(sha256: "abc").sha256Bytes)
    }

    // MARK: - CryptoKitSHA256

    func testHashOfKnownStringMatchesReferenceVector() {
        // SHA-256("hello world") — canonical test vector.
        let expected = "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
        let actual = CryptoKitSHA256().hash(of: Data("hello world".utf8))
        XCTAssertEqual(actual, expected)
    }

    func testHashOfEmptyStringMatchesReferenceVector() {
        let expected = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        let actual = CryptoKitSHA256().hash(of: Data())
        XCTAssertEqual(actual, expected)
    }

    func testHashOfLargeDataIsDeterministic() {
        let data = Data((0..<10_000).map { UInt8($0 & 0xff) })
        let a = CryptoKitSHA256().hash(of: data)
        let b = CryptoKitSHA256().hash(of: data)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 64)
    }

    // MARK: - Codable round-trip

    func testCodableRoundTrip() throws {
        let manifest = makeManifest()
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(ModelManifest.self, from: data)
        XCTAssertEqual(decoded, manifest)
    }

    // MARK: - Helpers

    private func makeManifest(
        sha256: String = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
    ) -> ModelManifest {
        ModelManifest(
            modelID: "whisper-large-v3-turbo-coreml",
            backend: .whisperkit,
            url: URL(string: "https://huggingface.co/example/resolve/main/weights.bin")!,
            sha256: sha256,
            sizeBytes: 821_456_789,
            minOSVersion: "26.0"
        )
    }
}