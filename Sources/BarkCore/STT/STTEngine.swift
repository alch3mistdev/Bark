import Foundation

/// One transcription update. `isFinal == false` means a volatile/partial hypothesis
/// that may still change; `true` means the segment is committed.
public struct STTResult: Sendable, Equatable {
    public var text: String
    public var isFinal: Bool

    public init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }

    public static let empty = STTResult(text: "", isFinal: true)
}

/// A batch of PCM samples handed from the audio layer to an STT engine.
/// Always 16 kHz mono Float32 by contract (`AudioCaptureEngine` converts).
public struct AudioFrames: Sendable {
    public var samples: [Float]
    public var sampleRate: Double
    public var sequence: UInt64

    public init(samples: [Float], sampleRate: Double = 16_000, sequence: UInt64 = 0) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.sequence = sequence
    }
}

/// Swappable speech-to-text backend. Concrete adapters (Apple SpeechAnalyzer,
/// Parakeet/FluidAudio, WhisperKit) live in `BarkEngines`; the pipeline depends
/// only on this protocol (ADR-002).
public protocol STTEngine: Sendable {
    /// Warm/load the model for `locale` (e.g. "en-US"). Idempotent.
    func prepare(locale: String) async throws

    /// Begin a streaming session; returns the live results stream
    /// (volatile updates then a final per segment).
    func beginStream() async throws -> AsyncThrowingStream<STTResult, Error>

    /// Feed converted PCM frames into the active session.
    func feed(_ frames: AudioFrames) async

    /// Signal end-of-audio and flush the final transcript.
    func finishStream() async throws

    /// Abort the active session, discarding pending audio.
    func cancel() async
}

/// Raised by engines for predictable, user-actionable failures.
public enum STTError: Error, Sendable, Equatable {
    case modelNotInstalled(locale: String)
    case localeUnsupported(locale: String)
    case notPrepared
    case engineFailure(String)
}
