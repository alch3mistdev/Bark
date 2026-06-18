import Foundation
import CryptoKit
import Security
import BarkCore

/// Opt-in transcript history, **encrypted at rest** with AES-256-GCM. The key
/// lives in the Keychain (device-only, when-unlocked); the ciphertext file is
/// `0600` and excluded from backups (SEC-006 / T-008).
///
/// For tests, inject a fixed `key` + a temp `directory` to exercise the crypto
/// and retention without touching the Keychain.
public actor EncryptedHistoryStore: HistoryStore {
    private let fileURL: URL
    private let keyService: String
    private let injectedKey: SymmetricKey?
    private var cache: [HistoryRecord]?

    public init(directory: URL? = nil, keyService: String = "com.bark.history", key: SymmetricKey? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Bark", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("history.enc")
        self.keyService = keyService
        self.injectedKey = key
    }

    public func append(_ record: HistoryRecord) async throws {
        var records: [HistoryRecord]
        do {
            records = try loadStrict()
        } catch {
            // Existing file is unreadable (corrupt / key mismatch). Don't clobber
            // it (Codex) — back it up, then start fresh so we still record forward.
            let backup = fileURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            BarkLog.pipeline.error("history unreadable; backed up to history.enc.corrupt")
            records = []
        }
        records.append(record)
        records = RetentionPolicy.trim(records)
        try save(records)
        cache = records
    }

    public func all() async -> [HistoryRecord] {
        if let cache { return cache }
        do {
            let records = try loadStrict()
            cache = records
            return records
        } catch {
            // Don't cache the failure — a transient miss must not mask real data.
            BarkLog.pipeline.error("history unreadable; returning empty")
            return []
        }
    }

    /// Loads + decrypts; distinguishes "no file" (→ `[]`) from "unreadable" (→ throws).
    private func loadStrict() throws -> [HistoryRecord] {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return [] }
        let key = try resolveKey()
        let box = try AES.GCM.SealedBox(combined: data)
        let plain = try AES.GCM.open(box, using: key)
        return try JSONDecoder().decode([HistoryRecord].self, from: plain)
    }

    public func purge() async throws {
        try? FileManager.default.removeItem(at: fileURL)
        if injectedKey == nil { deleteKeychainKey() }
        cache = []
    }

    // MARK: - Persistence

    private func save(_ records: [HistoryRecord]) throws {
        let key = try resolveKey()
        let plain = try JSONEncoder().encode(records)
        let sealed = try AES.GCM.seal(plain, using: key)
        guard let combined = sealed.combined else { throw CleanupError.outputRejected(reason: "seal") }
        try combined.write(to: fileURL, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    // MARK: - Key management

    private func resolveKey() throws -> SymmetricKey {
        if let injectedKey { return injectedKey }
        if let existing = readKeychainKey() { return existing }
        let key = SymmetricKey(size: .bits256)
        try storeKeychainKey(key)
        return key
    }

    private func keychainQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyService,
            kSecAttrAccount as String: "history-key",
        ]
    }

    private func readKeychainKey() -> SymmetricKey? {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return SymmetricKey(data: data)
    }

    private func storeKeychainKey(_ key: SymmetricKey) throws {
        let data = key.withUnsafeBytes { Data($0) }
        var add = keychainQuery()
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemDelete(add as CFDictionary)
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw CleanupError.outputRejected(reason: "keychain \(status)") }
    }

    private func deleteKeychainKey() {
        SecItemDelete(keychainQuery() as CFDictionary)
    }
}
