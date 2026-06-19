import Foundation

/// How readily speech is detected. Higher sensitivity → lower energy threshold.
public enum VADSensitivity: String, Sendable, CaseIterable, Codable, Identifiable {
    case low, medium, high

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .low: return "Low (noisy rooms)"
        case .medium: return "Medium"
        case .high: return "High (quiet speech)"
        }
    }

    /// RMS energy threshold for a frame to count as speech.
    public var energyThreshold: Float {
        switch self {
        case .low: return 0.025
        case .medium: return 0.012
        case .high: return 0.006
        }
    }
}

public enum VADEvent: Sendable, Equatable {
    case none
    case speechStarted
    case speechEnded
}

public struct VADConfig: Sendable {
    public var energyThreshold: Float
    public var onsetFrames: Int      // consecutive speech frames to confirm onset
    public var hangoverFrames: Int   // consecutive silence frames to confirm end-of-utterance

    public init(energyThreshold: Float = VADSensitivity.medium.energyThreshold,
                onsetFrames: Int = 3, hangoverFrames: Int = 8) {
        self.energyThreshold = energyThreshold
        self.onsetFrames = max(1, onsetFrames)
        self.hangoverFrames = max(1, hangoverFrames)
    }

    public init(sensitivity: VADSensitivity, onsetFrames: Int = 2, hangoverFrames: Int = 8) {
        self.init(energyThreshold: sensitivity.energyThreshold,
                  onsetFrames: onsetFrames, hangoverFrames: hangoverFrames)
    }
}

/// Energy-based voice-activity detector with onset confirmation + silence
/// hangover. Pure + unit-tested; fed one `AudioFrames` chunk (~100 ms) at a time.
public struct VoiceActivityDetector: Sendable {
    public private(set) var isSpeaking = false
    private let config: VADConfig
    private var speechRun = 0
    private var silenceRun = 0

    public init(config: VADConfig = .init()) {
        self.config = config
    }

    /// Root-mean-square energy of a frame's samples (0...~1 for normalized PCM).
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    @discardableResult
    public mutating func process(_ frames: AudioFrames) -> VADEvent {
        process(rms: Self.rms(frames.samples))
    }

    /// Drive with a precomputed RMS (used by tests).
    @discardableResult
    public mutating func process(rms: Float) -> VADEvent {
        let isSpeech = rms >= config.energyThreshold
        if isSpeech {
            silenceRun = 0
            speechRun += 1
            if !isSpeaking && speechRun >= config.onsetFrames {
                isSpeaking = true
                return .speechStarted
            }
        } else {
            speechRun = 0
            if isSpeaking {
                silenceRun += 1
                if silenceRun >= config.hangoverFrames {
                    isSpeaking = false
                    return .speechEnded
                }
            }
        }
        return .none
    }

    public mutating func reset() {
        isSpeaking = false
        speechRun = 0
        silenceRun = 0
    }
}
