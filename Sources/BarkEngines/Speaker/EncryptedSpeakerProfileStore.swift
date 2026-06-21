import Foundation
import CryptoKit
import Security
import BarkCore

/// On-device, **encrypted-at-rest** persistence for the enrolled voiceprint —
/// the same AES-256-GCM + Keychain scheme as `EncryptedHistoryStore`, with a
/// **distinct** key identity (`com.bark.speaker`) so deleting the voiceprint and
/// purging transcript history are fully independent (research D6).
///
/// A voiceprint is biometric-adjacent personal data: ciphertext file is `0600`,
/// `.completeFileProtection`, excluded from backups; the key lives in the
/// Keychain (device-only, when-unlocked) and is destroyed on `delete()`.
///
/// For tests, inject a fixed `key` + a temp `directory` to exercise the crypto
/// and deletion without touching the real Keychain.
public actor EncryptedSpeakerProfileStore: SpeakerProfileStore {
    private let fileURL: URL
    private let keyService: String
    private let account: String
    private let injectedKey: SymmetricKey?

    public init(directory: URL? = nil,
                keyService: String = "com.bark.speaker",
                account: String = "speaker-key",
                key: SymmetricKey? = nil) {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory   // never trap on a missing support dir
        let base = directory ?? support.appendingPathComponent("Bark", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("speaker.enc")
        self.keyService = keyService
        self.account = account
        self.injectedKey = key
    }

    public func load() async -> SpeakerProfile? {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return nil }
        do {
            let key = try resolveKey()
            let box = try AES.GCM.SealedBox(combined: data)
            let plain = try AES.GCM.open(box, using: key)
            return try JSONDecoder().decode(SpeakerProfile.self, from: plain)
        } catch {
            // Unreadable (corrupt / key mismatch). Don't clobber silently — back it
            // up, log, and report "not enrolled" so the caller fails open and the
            // user can re-enroll. Never crash.
            let backup = fileURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            BarkLog.pipeline.error("voiceprint unreadable; backed up to speaker.enc.corrupt")
            return nil
        }
    }

    public func save(_ profile: SpeakerProfile) async throws {
        let key = try resolveKey()
        let plain = try JSONEncoder().encode(profile)
        let sealed = try AES.GCM.seal(plain, using: key)
        guard let combined = sealed.combined else {
            throw SpeakerStoreError.sealFailed
        }
        try combined.write(to: fileURL, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    public func delete() async {
        try? FileManager.default.removeItem(at: fileURL)
        if injectedKey == nil { deleteKeychainKey() }
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
            kSecAttrAccount as String: account,
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
        guard status == errSecSuccess else { throw SpeakerStoreError.keychain(status) }
    }

    private func deleteKeychainKey() {
        SecItemDelete(keychainQuery() as CFDictionary)
    }
}

/// Failures from sealing/persisting the voiceprint. `load()` never throws (a bad
/// file degrades to `nil` so the gate fails open); only `save()` surfaces these.
public enum SpeakerStoreError: Error, Sendable, Equatable {
    case sealFailed
    case keychain(OSStatus)
}
