import XCTest
import CryptoKit
@testable import BarkCore
@testable import BarkEngines

final class SpeakerProfileStoreTests: XCTestCase {
    private func profile(modelID: String = "wespeaker-v2") -> SpeakerProfile {
        SpeakerProfile(centroid: SpeakerEmbedding([0.6, 0.8]),
                       sampleCount: 5, enrolledAt: Date(timeIntervalSince1970: 1_700_000_000),
                       modelID: modelID)
    }

    func testEncryptedRoundTripAndDelete() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)

        let store = EncryptedSpeakerProfileStore(directory: dir, key: key)
        try await store.save(profile())

        // Fresh instance with the same key decrypts the single profile.
        let reopened = EncryptedSpeakerProfileStore(directory: dir, key: key)
        let loaded = await reopened.load()
        XCTAssertEqual(loaded, profile())

        // On-disk bytes are ciphertext — the modelID string must not appear in the clear.
        let raw = try Data(contentsOf: dir.appendingPathComponent("speaker.enc"))
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("wespeaker-v2"))

        await reopened.delete()
        let after = await reopened.load()
        XCTAssertNil(after)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("speaker.enc").path))
    }

    func testSaveOverwritesSingleProfile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let store = EncryptedSpeakerProfileStore(directory: dir, key: key)

        try await store.save(profile(modelID: "old"))
        try await store.save(profile(modelID: "new"))
        let loaded = await store.load()
        XCTAssertEqual(loaded?.modelID, "new")   // exactly one profile per device
    }

    func testWrongKeyIsTreatedAsNotEnrolled() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = EncryptedSpeakerProfileStore(directory: dir, key: SymmetricKey(size: .bits256))
        try await writer.save(profile())

        // A different key can't decrypt → load() returns nil (gate fails open), the
        // unreadable file is backed up rather than destroyed.
        let attacker = EncryptedSpeakerProfileStore(directory: dir, key: SymmetricKey(size: .bits256))
        let loaded = await attacker.load()
        XCTAssertNil(loaded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("speaker.enc.corrupt").path))
    }
}
