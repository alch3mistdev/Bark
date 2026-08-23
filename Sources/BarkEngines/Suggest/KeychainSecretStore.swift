import Foundation
import Security
import BarkCore

/// Keychain-backed storage for the external endpoint's API key (015 FR-013) —
/// generic password, device-only, when-unlocked: the same posture as the
/// history/speaker encryption keys (`EncryptedSpeakerProfileStore`). The key
/// NEVER enters the Settings JSON.
///
/// OS adapter: exercised indirectly (clients test against `InMemorySecretStore`);
/// Keychain round-trip behavior is best-effort verified in the manual QA matrix
/// (constitution Quality Gates).
public struct KeychainSecretStore: SecretStore {
    private let service: String

    public init(service: String = "com.bark.external-llm") {
        self.service = service
    }

    public func read(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ secret: String, account: String) throws {
        guard !secret.isEmpty else { delete(account: account); return }
        var add = baseQuery(account: account)
        add[kSecValueData as String] = Data(secret.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
    }

    public func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

public enum SecretStoreError: Error, Sendable, Equatable {
    case keychain(OSStatus)
}
