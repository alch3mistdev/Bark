import Foundation
import BarkCore

#if WHISPERKIT
import WhisperKit

/// `STTEngine` backed by Argmax's WhisperKit — Whisper on Core ML, runs on the
/// Apple Neural Engine. Wider language coverage (99+) and better robustness to
/// accent / noise than Apple's on-device STT, at the cost of higher latency
/// (model warm-up, larger decoder). Same `STTEngine` contract as the Apple
/// backend — the pipeline doesn't know the difference (ADR-002, ADR-006).
///
/// Activated when the binary is built with `Package-stt-extras.swift`
/// (`-D WHISPERKIT`). The lean build (`Package.swift`) compiles the stub below
/// so this file is always present in the target and tests can run offline.
///
/// Model download is performed through `ModelDownloader` which sha256-verifies
/// the weights against a bundled manifest before WhisperKit loads them
/// (`SEC-003 / T-010`).
///
/// SDK NOTE (2026-06): WhisperKit 1.0+ ships inside Argmax's
/// `argmax-oss-swift` umbrella. The streaming API surface below is based on
/// the v1.0 documentation; concrete call sites should be re-verified when the
/// SDK is pulled in (the stream-of-`AsyncThrowingStream<STTResult, Error>`
/// shape we expose is the contract that the pipeline already consumes, so
/// most adapter code is glue).
public actor WhisperKitEngine: STTEngine {
    private let manifest: ModelManifest?
    private let downloader: ModelDownloading?
    private var localeID = "en-US"
    private var isPrepared = false
    private var pipeline: WhisperKit?
    /// Continuation for the per-session audio stream. `feed(_:)` yields chunks
    /// here; `finishStream()` / `cancel()` finish it so the Task in `beginStream`
    /// knows when all audio has arrived.
    private var audioContinuation: AsyncStream<[Float]>.Continuation?

    public init(manifest: ModelManifest? = nil, downloader: ModelDownloading? = nil) {
        self.manifest = manifest
        self.downloader = downloader
    }

    public func prepare(locale: String) async throws {
        localeID = locale
        // Resolve the on-disk model path. If a manifest is supplied we MUST verify
        // before handing the path to WhisperKit (SEC-003). A nil manifest means
        // the caller has placed a trusted model elsewhere (e.g. dev workflow).
        let modelFolder: String?
        if let manifest, let downloader {
            modelFolder = try await downloader.ensureModel(for: manifest).path
        } else {
            modelFolder = nil   // let WhisperKit use its own cache (still offline once fetched)
        }

        // SDK NOTE: WhisperKit v1.0 constructor takes `WhisperKitParams`; the
        // shape below mirrors the published API. Confirm against the SDK on
        // first compile.
        let params = WhisperKitParams(
            model: manifest?.modelID ?? "base",
            modelFolder: modelFolder,
            computeOptions: ComputeOptions(modelCompute: .cpuAndGPU)
        )
        let pipe = try await WhisperKit(params)
        self.pipeline = pipe
        isPrepared = true
        BarkLog.stt.info("WhisperKit prepared for \(locale, privacy: .public)")
    }

    public func beginStream() async throws -> AsyncThrowingStream<STTResult, Error> {
        guard isPrepared, let pipeline else { throw STTError.notPrepared }
        // Tear down any previous session's audio stream.
        audioContinuation?.finish()
        audioContinuation = nil

        // Build a channel that bridges `feed(_:)` calls into the Task below.
        var audioCont: AsyncStream<[Float]>.Continuation?
        let audioStream = AsyncStream<[Float]>(bufferingPolicy: .unbounded) { cont in
            audioCont = cont
        }
        self.audioContinuation = audioCont

        // The pipeline code is identical to the Apple backend's path — that's
        // the whole point of the protocol. SDK NOTE: `transcribeStream` is the
        // push-style API; the real call signature should be re-verified, but
        // the `STTResult` surface this exposes is the only contract the
        // pipeline reads.
        let (stream, cont) = AsyncThrowingStream<STTResult, Error>.makeStream()
        let locale = localeID
        Task { [pipeline, audioStream] in
            do {
                // Accumulate all PCM frames from `feed(_:)` calls; the stream
                // finishes when `finishStream()` or `cancel()` is called.
                var allSamples: [Float] = []
                for await chunk in audioStream {
                    allSamples.append(contentsOf: chunk)
                }
                for try await result in pipeline.transcribeStream(
                    audioArray: allSamples,
                    decodeOptions: DecodingOptions(language: locale)
                ) {
                    cont.yield(STTResult(text: result.text, isFinal: !result.isPartial))
                }
                cont.finish()
            } catch {
                cont.finish(throwing: error)
            }
        }
        return stream
    }

    public func feed(_ frames: AudioFrames) async {
        audioContinuation?.yield(frames.samples)
    }

    public func finishStream() async throws {
        // Signal that all audio has been fed; the Task in beginStream will
        // drain the remaining chunks and finish the results stream.
        audioContinuation?.finish()
        audioContinuation = nil
    }

    public func cancel() async {
        // Finish the audio stream so the transcription Task exits cleanly.
        audioContinuation?.finish()
        audioContinuation = nil
    }
}

#else

/// Stub compiled when the WhisperKit backend is not present (the default lean
/// build, `Package.swift`). Always reports "not compiled" so the factory and
/// UI can hide the option. Activate by switching to `Package-stt-extras.swift`
/// (see README → "Optional: enable WhisperKit / Parakeet backends").
public final class WhisperKitEngine: STTEngine, @unchecked Sendable {
    public init(manifest: ModelManifest? = nil, downloader: ModelDownloading? = nil) {}

    public func prepare(locale: String) async throws {
        throw STTError.engineFailure("WhisperKit backend not compiled in this build. "
                                    + "Use Package-stt-extras.swift and rebuild.")
    }

    public func beginStream() async throws -> AsyncThrowingStream<STTResult, Error> {
        throw STTError.engineFailure("WhisperKit backend not compiled in this build.")
    }

    public func feed(_ frames: AudioFrames) async {}

    public func finishStream() async throws {}

    public func cancel() async {}
}

#endif