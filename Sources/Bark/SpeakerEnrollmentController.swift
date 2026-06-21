import Foundation
import Observation
import BarkCore

/// Guided voice enrollment: the user reads a short set of prompted phrases; each
/// take is captured via VAD, validated (long + loud enough), and embedded. When
/// enough good takes are collected, their embeddings are averaged into a centroid
/// and persisted as the `SpeakerProfile`. **No raw enrollment audio is retained.**
///
/// Lives on the main actor for the UI; the embedding extraction runs off-actor in
/// the injected `SpeakerEmbedder`. Created via `DictationController.makeEnrollmentController()`.
@MainActor
@Observable
public final class SpeakerEnrollmentController {
    public enum Phase: Equatable, Sendable {
        case idle
        case listening(captured: Int)            // waiting for the user to read the current phrase
        case evaluating
        case redo(reason: String, captured: Int) // last take rejected; re-read without losing good takes
        case saving
        case done
        case failed(String)
    }

    /// The fixed set of short, varied phrases the user reads. Five takes (research D3).
    public static let phrases = [
        "The quick brown fox jumps over the lazy dog.",
        "Bark types what I say, only when I say it.",
        "Today the room is calm and the weather is clear.",
        "Six small ships sailed swiftly south at sunrise.",
        "Please remember to verify my voice before you type.",
    ]

    public private(set) var phase: Phase = .idle
    public private(set) var capturedCount = 0
    public var requiredCount: Int { Self.phrases.count }

    /// The phrase the user should read next ("" once all are captured).
    public var currentPrompt: String {
        capturedCount < Self.phrases.count ? Self.phrases[capturedCount] : ""
    }

    /// Called once a voiceprint has been saved, so the owner can reload it.
    public var onComplete: (@MainActor () -> Void)?

    private let embedder: SpeakerEmbedder
    private let store: SpeakerProfileStore
    private let audioFactory: @Sendable () -> AudioCapturing
    private let sensitivity: @MainActor () -> VADSensitivity

    private var embeddings: [SpeakerEmbedding] = []
    private var audio: AudioCapturing?
    private var task: Task<Void, Never>?

    /// ≥1.0 s of voiced audio at 16 kHz; below this a take is too short to embed.
    private static let minVoicedSamples = 16_000
    /// Mean-RMS floor for a usable take (too-quiet takes are re-recorded).
    private static let minMeanRMS: Float = 0.01

    public init(
        embedder: SpeakerEmbedder,
        store: SpeakerProfileStore,
        audioFactory: @escaping @Sendable () -> AudioCapturing,
        sensitivity: @escaping @MainActor () -> VADSensitivity
    ) {
        self.embedder = embedder
        self.store = store
        self.audioFactory = audioFactory
        self.sensitivity = sensitivity
    }

    /// Begin (or restart) enrollment from zero captured takes.
    public func start() {
        guard task == nil else { return }
        embeddings.removeAll()
        capturedCount = 0
        phase = .listening(captured: 0)
        task = Task { [weak self] in await self?.runEnrollment() }
    }

    /// Abort and discard any in-progress takes.
    public func cancel() {
        task?.cancel(); task = nil
        audio?.stop(); audio = nil
        phase = .idle
    }

    private func runEnrollment() async {
        let engine = audioFactory()
        self.audio = engine
        let stream: AsyncStream<AudioFrames>
        do { stream = try engine.start() }
        catch { phase = .failed("Couldn't open the microphone."); audio = nil; return }

        var vad = VoiceActivityDetector(config: VADConfig(sensitivity: sensitivity()))
        var capturing = false
        var preroll: [AudioFrames] = []
        let prerollMax = 3
        var samples: [Float] = []
        var energyAccum: Float = 0
        var energyFrames = 0
        var capturedFrames = 0
        let maxFrames = 150   // ~15 s per-phrase safety cap

        for await frames in stream {
            guard !Task.isCancelled else { break }
            let event = vad.process(frames)

            if !capturing {
                preroll.append(frames)
                if preroll.count > prerollMax { preroll.removeFirst() }
                guard event == .speechStarted else { continue }
                samples.removeAll(); energyAccum = 0; energyFrames = 0; capturedFrames = 0
                for f in preroll { samples.append(contentsOf: f.samples) }
                preroll.removeAll()
                capturing = true
            } else {
                samples.append(contentsOf: frames.samples)
                energyAccum += VoiceActivityDetector.rms(frames.samples)
                energyFrames += 1
                capturedFrames += 1
                guard event == .speechEnded || capturedFrames >= maxFrames else { continue }
                capturing = false
                vad.reset()
                let meanRMS = energyFrames > 0 ? energyAccum / Float(energyFrames) : 0
                await evaluateTake(samples, meanRMS: meanRMS)
                if case .done = phase { break }
                if case .failed = phase { break }
            }
        }
        engine.stop()
        self.audio = nil
    }

    private func evaluateTake(_ samples: [Float], meanRMS: Float) async {
        phase = .evaluating
        guard samples.count >= Self.minVoicedSamples else {
            phase = .redo(reason: "That was too short — hold the phrase a moment longer.",
                          captured: capturedCount)
            return
        }
        guard meanRMS >= Self.minMeanRMS else {
            phase = .redo(reason: "That was too quiet — speak up or move closer to the mic.",
                          captured: capturedCount)
            return
        }
        do {
            let embedding = try await embedder.embed(samples)
            embeddings.append(embedding)
            capturedCount = embeddings.count
            if capturedCount >= requiredCount {
                await finish()
            } else {
                phase = .listening(captured: capturedCount)
            }
        } catch {
            // Enrollment can't fail open — without an embedding there is no
            // voiceprint. Surface the error so the user can retry/cancel.
            phase = .failed("Speaker model unavailable — enrollment can't continue.")
        }
    }

    private func finish() async {
        phase = .saving
        let centroid = SpeakerEmbedding.mean(of: embeddings)
        let profile = SpeakerProfile(centroid: centroid,
                                     sampleCount: embeddings.count,
                                     enrolledAt: Date(),
                                     modelID: embedder.modelID)
        do {
            try await store.save(profile)
            phase = .done
            onComplete?()
        } catch {
            phase = .failed("Couldn't save the voiceprint.")
        }
        audio?.stop(); audio = nil
    }
}
