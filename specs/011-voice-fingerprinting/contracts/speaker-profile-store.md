# Contract: SpeakerProfileStore

Encrypted, device-only persistence for the enrolled voiceprint. Biometric-adjacent data → same protection
as transcript history (constitution IV + quality gates).

## Protocol (BarkCore)

```swift
public protocol SpeakerProfileStore: Sendable {
    func load() async -> SpeakerProfile?     // nil if absent or unreadable (treated as not enrolled)
    func save(_ profile: SpeakerProfile) async throws
    func delete() async                       // removes ciphertext AND Keychain key
}
```

## Implementation: `EncryptedSpeakerProfileStore` (BarkEngines)

Clone of `EncryptedHistoryStore` with a distinct identity:
- **Cipher**: AES-256-GCM (CryptoKit). Plaintext = JSON-encoded `SpeakerProfile`.
- **Key**: 256-bit, stored in Keychain, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
  - `keyService = "com.bark.speaker"`, account `"speaker-key"` — **separate** from history's
    `com.bark.history`, so deleting the voiceprint and purging history are independent.
- **File**: `~/Library/Application Support/Bark/speaker.enc`, perms `0600`, `.completeFileProtection`,
  `isExcludedFromBackup = true`, atomic write.
- **load()**: missing file ⇒ `nil`; unreadable/corrupt or key-mismatch ⇒ back up to `speaker.enc.corrupt`,
  log, return `nil` (never crash; caller fails open). A profile whose `modelID` ≠ the running embedder's
  `modelID` is loaded but treated by the caller as not-enrolled (prompt re-enroll).
- **delete()**: remove file + delete Keychain key.

## Invariants
- The voiceprint never leaves the device and is never written in plaintext.
- No raw enrollment audio is persisted — only the derived centroid.
- Single profile per device (one file).

## Test seam
Constructor accepts an injected key + temp directory (like `EncryptedHistoryStore`) so crypto + delete can
be exercised without touching the real Keychain.
