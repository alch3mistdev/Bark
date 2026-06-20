import Foundation

/// Stable, deterministic on-disk location for cached model bundles.
///
/// Layout:
///   ~/Library/Application Support/Bark/models/
///       whisperkit--whisper-large-v3-turbo-coreml.bin
///       parakeet--parakeet-tdt-0.6b-v3-coreml.bin
///       …
/// (double-dash separator; backend is the lowercased `STTBackendID`.)
///
/// Paths are derived from the manifest, not from the URL — so re-pointing a
/// manifest at a mirror does not invalidate the existing cache.
public enum ModelStore {
    /// Cache root. Created lazily by `ModelDownloader`; public so callers can
    /// present a "Reveal in Finder" affordance or compute disk usage.
    public static var defaultCacheDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Bark/models", isDirectory: true)
    }

    /// On-disk path for a manifest's verified bundle.
    public static func cachedURL(for manifest: ModelManifest, in directory: URL) -> URL {
        // Sanitise `modelID` so a malicious manifest (e.g. containing `/`, `\`,
        // or `..`) cannot escape the intended cache directory.
        let safeID = manifest.modelID
            .replacingOccurrences(of: "/",  with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "..",  with: "_")
        let fileName = "\(manifest.backend.rawValue)--\(safeID).bin"
        return directory.appendingPathComponent(fileName)
    }

    /// Idempotent directory creation. Logs but does not throw on EEXIST so a
    /// concurrent `ensureModel` for two different manifests is safe.
    public static func ensureDirectoryExists(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
    }

    /// Total bytes used by the model cache. Cheap for the small model set Bark
    /// ships (≤ a handful of bundles); the OS will reclaim space if the user
    /// uninstalls the app via Finder.
    public static func diskUsage(in directory: URL = defaultCacheDirectory) -> UInt64 {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: directory,
                                                      includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        return urls.reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + UInt64(size)
        }
    }
}