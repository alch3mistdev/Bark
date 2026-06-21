import Foundation

/// Encrypted, device-only persistence for the enrolled voiceprint. Biometric-
/// adjacent data → the same protection as transcript history (constitution IV).
///
/// The concrete `EncryptedSpeakerProfileStore` (BarkEngines) clones
/// `EncryptedHistoryStore`'s AES-256-GCM + Keychain scheme with a **distinct**
/// key identity so deleting the voiceprint and purging history are independent.
public protocol SpeakerProfileStore: Sendable {
    /// The stored profile, or `nil` if absent or unreadable (treated as not enrolled).
    func load() async -> SpeakerProfile?

    /// Persist (overwrite) the single profile.
    func save(_ profile: SpeakerProfile) async throws

    /// Remove the ciphertext **and** the protection key; the gate becomes inactive.
    func delete() async
}
