import Foundation
import BarkCore

#if FLUIDAUDIO
import FluidAudio
@preconcurrency import AVFoundation

/// `STTEngine` backed by NVIDIA Parakeet TDT-0.6b-v3 via FluidAudio (Core ML,
/// ANE). 25 languages, Apache-2.0, narrow decoder — sits between Apple's STT
/// (lowest latency) and WhisperKit (widest language coverage) in the trade-off
/// matrix. Same `STTEngine` contract; the pipeline is unchanged (ADR-002,
/// ADR-006).
///
/// Activated when the binary is built with `Package-stt-extras.swift`
/// (`-D FLUIDAUDIO`). The lean build compiles the stub below.
///
/// SDK NOTE (2026-06): FluidAudio's ASR API surface is `AsrModels.downloadAndLoad()`
/// → `AsrManager(config:).initialize(models:)` → `asr.transcribe(samples, source:)`.
/// The adapter below mirrors that flow. Real call sites should be re-verified
/// when the SDK is pulled in; the `STTResult` shape we expose is the only
/// contract the pipeline reads.
public actor ParakeetEngine: STTEngine {
    private let manifest: ModelManifest?
    private let downloader: ModelDownloading?
    private var localeID = "en-US"
    private var isPrepared = false
    private var asr: AsrManager?

    public init(manifest: ModelManifest? = nil, downloader: ModelDownloading? = nil) {
        self.manifest = manifest
        self.downloader = downloader
    }

    public func prepare(locale: String) async throws {
        localeID = locale
        // If a manifest is supplied we MUST verify the on-disk bundle before
        // handing the path to FluidAudio (SEC-003). FluidAudio's own
        // `downloadAndLoad` does NOT verify integrity, so we use it only when
        // no manifest is supplied (dev workflow).
        let models: AsrModels
        if let manifest, let downloader {
            let verifiedURL = try await downloader.ensureModel(for: manifest)
            models = try await AsrModels.loadFromLocal(url: verifiedURL)
        } else {
            models = try await AsrModels.downloadAndLoad()
        }

        let manager = AsrManager(config: .default)
        try await manager.initialize(models: models)
        self.asr = manager
        isPrepared = true
        BarkLog.stt.info("Parakeet prepared for \(locale, privacy: .public)")
    }

    public func beginStream() async throws -> AsyncThrowingStream<STTResult, Error> {
        guard isPrepared, let asr else { throw STTError.notPrepared }
        // FluidAudio's batch ASR returns `transcribe(_:source:)` with a single
        // final result; we yield a single `STTResult(isFinal: true)`. A future
        // revision can adopt FluidAudio's streaming API when it's released; the
        // protocol doesn't change.
        let (stream, cont) = AsyncThrowingStream<STTResult, Error>.makeStream()
        let locale = localeID
        Task { [asr] in
            do {
                let samples = await Self.collectUtterance()
                let result = try await asr.transcribe(samples, source: .system)
                if locale != "auto" && !result.detectedLanguage.isEmpty
                    && result.detectedLanguage != locale {
                    BarkLog.stt.warning("parakeet detected \(result.detectedLanguage, privacy: .public)"
                                       + " but locale was \(locale, privacy: .public)")
                }
                cont.yield(STTResult(text: result.text, isFinal: true))
                cont.finish()
            } catch {
                cont.finish(throwing: error)
            }
        }
        return stream
    }

    public func feed(_ frames: AudioFrames) async {
        // Symmetric with WhisperKitEngine — real adapters implement a chunked
        // async source inside beginStream. The protocol stays identical.
    }

    public func finishStream() async throws {}

    public func cancel() async {}

    /// Internal placeholder — a streaming-capable adapter would buffer PCM
    /// samples here and `await` them on `finishStream`. Today's FluidAudio
    /// batch API doesn't need it; included so the API surface is symmetric
    /// with `WhisperKitEngine`.
    private static func collectUtterance() async -> [Float] { [] }
}

#else

/// Stub compiled when the Parakeet backend is not present (default lean build).
/// See `WhisperKitEngine` for the rationale and activation path.
public final class ParakeetEngine: STTEngine, @unchecked Sendable {
    public init() {}

    public func prepare(locale: String) async throws {
        throw STTError.engineFailure("Parakeet backend not compiled in this build. "
                                    + "Use Package-stt-extras.swift and rebuild.")
    }

    public func beginStream() async throws -> AsyncThrowingStream<STTResult, Error> {
        throw STTError.engineFailure("Parakeet backend not compiled in this build.")
    }

    public func feed(_ frames: AudioFrames) async {}

    public func finishStream() async throws {}

    public func cancel() async {}
}

#endif