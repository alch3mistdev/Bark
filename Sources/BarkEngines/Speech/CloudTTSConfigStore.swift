import Foundation
import BarkCore

/// Resolved cloud-TTS configuration for one utterance.
public struct CloudTTSConfig: Sendable, Equatable {
    /// False whenever the user's backend is the on-device system voice — the
    /// synthesizer then refuses before touching the network at all.
    public var enabled: Bool
    public var apiKey: String
    public var voiceID: String
    public var modelID: String

    public init(enabled: Bool = false,
                apiKey: String = "",
                voiceID: String = CloudTTSRequest.defaultVoiceID,
                modelID: String = CloudTTSRequest.defaultModelID) {
        self.enabled = enabled
        self.apiKey = apiKey
        self.voiceID = voiceID
        self.modelID = modelID
    }

    public static let disabled = CloudTTSConfig()
}

/// Thread-safe handoff of cloud-TTS settings from the `@MainActor` controller
/// (which owns Settings and the Keychain) to the `Sendable` synthesizer (which
/// runs requests off the main actor). The controller refreshes this
/// immediately before every utterance, so the engine can never read stale
/// configuration, and no `@MainActor` state is touched from a nonisolated
/// context.
public final class CloudTTSConfigStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CloudTTSConfig

    public init(_ initial: CloudTTSConfig = .disabled) {
        value = initial
    }

    public var current: CloudTTSConfig {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    public func update(_ config: CloudTTSConfig) {
        lock.lock()
        value = config
        lock.unlock()
    }
}
