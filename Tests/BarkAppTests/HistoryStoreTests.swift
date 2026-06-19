import XCTest
import CryptoKit
@testable import BarkCore
@testable import BarkEngines

final class HistoryStoreTests: XCTestCase {
    func testEncryptedRoundTripAndPurge() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("barktest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)

        let store = EncryptedHistoryStore(directory: dir, key: key)
        for i in 0..<3 {
            try await store.append(HistoryRecord(transcript: "t\(i)", output: "out\(i)", modeID: "clean", appBundleID: nil))
        }

        // A fresh instance (cold cache) decrypts the file with the same key.
        let reopened = EncryptedHistoryStore(directory: dir, key: key)
        let all = await reopened.all()
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(Set(all.map(\.output)), ["out0", "out1", "out2"])

        // On-disk bytes are ciphertext — plaintext must not appear.
        let raw = try Data(contentsOf: dir.appendingPathComponent("history.enc"))
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("out1"))

        try await reopened.purge()
        let after = await reopened.all()
        XCTAssertTrue(after.isEmpty)
    }

    func testDefaultSearchAndRecent() async throws {
        // The protocol's default search/recent (007) compose HistoryQuery + RetentionPolicy
        // over all(); the concrete store needs no change.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("barktest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = EncryptedHistoryStore(directory: dir, key: SymmetricKey(size: .bits256))
        try await store.append(HistoryRecord(transcript: "send email", output: "Send email.", modeID: "email", appBundleID: nil))
        try await store.append(HistoryRecord(transcript: "git status", output: "git status", modeID: "raw", appBundleID: nil))

        let hits = await store.search("git")
        XCTAssertEqual(hits.map(\.output), ["git status"])

        let empty = await store.search("nomatch")
        XCTAssertTrue(empty.isEmpty)

        // Blank query → recent (all, newest-first, trimmed).
        let blank = await store.search("")
        XCTAssertEqual(blank.count, 2)
        let recent = await store.recent(limit: 1)
        XCTAssertEqual(recent.count, 1)
    }

    func testWrongKeyCannotDecrypt() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("barktest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = EncryptedHistoryStore(directory: dir, key: SymmetricKey(size: .bits256))
        try await writer.append(HistoryRecord(transcript: "secret", output: "secret", modeID: "clean", appBundleID: nil))

        // Different key → decrypt fails → treated as empty (no crash, no leak).
        let attacker = EncryptedHistoryStore(directory: dir, key: SymmetricKey(size: .bits256))
        let all = await attacker.all()
        XCTAssertTrue(all.isEmpty)
    }

    func testUnreadableFileIsBackedUpNotClobbered() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("barktest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = EncryptedHistoryStore(directory: dir, key: SymmetricKey(size: .bits256))
        try await first.append(HistoryRecord(transcript: "first", output: "first", modeID: "clean", appBundleID: nil))

        // A store with a different key can't read the file; appending must back up
        // the unreadable file rather than silently destroy it (Codex).
        let other = EncryptedHistoryStore(directory: dir, key: SymmetricKey(size: .bits256))
        try await other.append(HistoryRecord(transcript: "second", output: "second", modeID: "clean", appBundleID: nil))

        let backup = dir.appendingPathComponent("history.enc.corrupt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        let all = await other.all()
        XCTAssertEqual(all.map(\.output), ["second"])
    }
}
