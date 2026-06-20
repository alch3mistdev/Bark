import Foundation
import BarkCore

/// Factory: turns a persisted `STTBackendID` (and any opt-in manifest) into a
/// concrete `STTEngine`. The single place the choice lives, so the rest of the
/// pipeline (and tests) can stay backend-agnostic.
///
/// Usage in `CompositionRoot`:
/// ```swift
/// let stt = STTEngineFactory.make(
///     id: settings.settings.sttBackend,
///     manifest: bundledManifest(for: settings.settings.sttBackend),
///     downloader: ModelDownloader()
/// )
/// ```
public enum STTEngineFactory {
    /// Construct an engine for `id`. If the requested backend isn't compiled
    /// into the running binary, returns the Apple engine (always present) and
    /// logs a one-shot warning — so a stale setting never bricks the app.
    public static func make(
        id: STTBackendID,
        manifest: ModelManifest? = nil,
        downloader: ModelDownloading? = nil
    ) -> STTEngine {
        switch id {
        case .apple:
            return SpeechAnalyzerEngine()
        case .whisperkit:
            guard STTBackendCompilationFlags.whisperKit else {
                BarkLog.stt.warning("whisperkit backend not compiled; falling back to apple")
                return SpeechAnalyzerEngine()
            }
            return WhisperKitEngine(manifest: manifest, downloader: downloader)
        case .parakeet:
            guard STTBackendCompilationFlags.fluidAudio else {
                BarkLog.stt.warning("parakeet backend not compiled; falling back to apple")
                return SpeechAnalyzerEngine()
            }
            return ParakeetEngine(manifest: manifest, downloader: downloader)
        }
    }

    /// Default manifest lookup. In a real release, the app ships a
    /// `Resources/manifests/<backend>.json` for each compiled-in backend; the
    /// factory reads that file (offline, bundled) and passes it to the engine.
    /// Returns `nil` if the file is missing — engines then fall back to their
    /// own default cache.
    public static func bundledManifest(for id: STTBackendID) -> ModelManifest? {
        guard let url = Bundle.main.url(forResource: "manifest-\(id.rawValue)",
                                        withExtension: "json")
        else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(ModelManifest.self, from: data)
        } catch {
            BarkLog.stt.error("manifest parse failed for \(id.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}