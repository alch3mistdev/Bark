import Foundation
import BarkCore

#if FLUIDAUDIO
import FluidAudio

/// `SpeakerEmbedder` backed by FluidAudio's **WeSpeaker v2** speaker-embedding
/// model (256-d, L2-normalized, Core ML / ANE, Apache-2.0). Reuses the FluidAudio
/// dependency already pulled for Parakeet STT — no new dependency, no SBOM delta
/// (research D1).
///
/// Activated when the binary is built with `Package-stt-extras.swift`
/// (`-D FLUIDAUDIO`). The lean build compiles the throwing stub below, and every
/// caller fails open, so dictation is unaffected.
///
/// SDK NOTE (2026-06): models are loaded from the **integrity-verified** local
/// path returned by `ModelDownloader.ensureModel(for:)` — never FluidAudio's
/// networked `downloadIfNeeded()` (constitution I; mirrors `ParakeetEngine.prepare`).
/// The single-utterance embedding extraction is isolated to one call site
/// (`extractEmbedding`); re-verify it against the pinned FluidAudio tag when the
/// SDK is pulled in — the 256-float `SpeakerEmbedding` shape is the only contract
/// the pipeline reads (research D2). If `extractEmbedding` is not public on the
/// pinned tag, fall back to running diarization on the single utterance and
/// reading the per-speaker vector from `DiarizationResult.speakerDatabase`.
public actor FluidAudioSpeakerEmbedder: SpeakerEmbedder {
    public nonisolated let modelID: String

    private let manifest: ModelManifest?
    private let downloader: ModelDownloading?
    private var diarizer: DiarizerManager?

    public init(manifest: ModelManifest? = nil, downloader: ModelDownloading? = nil) {
        self.manifest = manifest
        self.downloader = downloader
        self.modelID = manifest?.modelID ?? "wespeaker-v2-coreml"
    }

    public func embed(_ samples: [Float]) async throws -> SpeakerEmbedding {
        let diarizer = try await ensureLoaded()
        // The one ML call site. Returns the raw 256-float speaker vector for this
        // single utterance; we L2-normalize defensively (the contract requires a
        // unit vector and the math tolerates a non-normalized one anyway).
        let raw: [Float] = try await diarizer.extractEmbedding(samples)
        guard !raw.isEmpty else {
            throw STTError.engineFailure("speaker embedding extraction returned no vector")
        }
        return SpeakerEmbedding(raw).l2normalized()
    }

    /// Lazily load the diarizer models from the verified local bundle. Idempotent.
    private func ensureLoaded() async throws -> DiarizerManager {
        if let diarizer { return diarizer }
        let models: DiarizerModels
        if let manifest, let downloader {
            let verifiedURL = try await downloader.ensureModel(for: manifest)
            models = try await DiarizerModels.loadFromLocal(url: verifiedURL)
        } else {
            // Dev workflow only: no pinned manifest → FluidAudio's own load. NOT a
            // release path (skips integrity verification); mirrors ParakeetEngine.
            models = try await DiarizerModels.downloadIfNeeded()
        }
        let manager = DiarizerManager()
        try await manager.initialize(models: models)
        self.diarizer = manager
        BarkLog.stt.info("speaker embedder loaded (\(self.modelID, privacy: .public))")
        return manager
    }
}

#else

/// Stub compiled when the speaker-embedding capability is not present (default
/// lean build). `embed` throws so every caller fails open (FR-009); the gate is
/// inert and dictation behaves exactly as today.
public struct FluidAudioSpeakerEmbedder: SpeakerEmbedder {
    public let modelID = "noop"

    public init(manifest: ModelManifest? = nil, downloader: ModelDownloading? = nil) {}

    public func embed(_ samples: [Float]) async throws -> SpeakerEmbedding {
        throw STTError.engineFailure("Speaker ID not compiled in this build. "
                                    + "Use Package-stt-extras.swift and rebuild.")
    }
}

#endif
