import Foundation
import BarkCore

/// Hooks the rest of the pipeline uses to talk to "the model downloader".
/// Injected so tests can swap a fake without touching the network or disk.
public protocol ModelDownloading: Sendable {
    /// Returns the on-disk path of the verified model bundle. Downloads and
    /// sha256-verifies if not cached; returns the cached path if present and
    /// matches the manifest.
    func ensureModel(for manifest: ModelManifest) async throws -> URL

    /// Removes the cached bundle for a manifest (used when the user disables
    /// the backend, or a future "free disk space" affordance).
    func removeCached(for manifest: ModelManifest) async throws
}

/// Default downloader: downloads over HTTPS, writes to a stable cache path,
/// verifies SHA-256 before returning. Idempotent — repeated calls with the same
/// manifest short-circuit to the cache.
///
/// The verification step is the closing control for `SEC-003 / T-010` (see
/// `docs/SECURITY.md` ☐ → ☑). If the hash mismatches, the file is deleted and
/// `.hashMismatch` is thrown so the UI can show a "model is corrupted" message
/// rather than a silent failure.
public actor ModelDownloader: ModelDownloading {
    private let session: URLSession
    private let cacheDirectory: URL
    private let hasher: SHA256Hashing

    public init(session: URLSession = .shared,
                cacheDirectory: URL = ModelStore.defaultCacheDirectory,
                hasher: SHA256Hashing = CryptoKitSHA256()) {
        self.session = session
        self.cacheDirectory = cacheDirectory
        self.hasher = hasher
    }

    public func ensureModel(for manifest: ModelManifest) async throws -> URL {
        guard manifest.sha256Bytes != nil else {
            throw ModelError.manifestMalformed("sha256 is not a valid 64-char hex string")
        }
        try ModelStore.ensureDirectoryExists(cacheDirectory)

        let cachedURL = ModelStore.cachedURL(for: manifest, in: cacheDirectory)

        // Fast path: cached file matches → return without network.
        if FileManager.default.fileExists(atPath: cachedURL.path) {
            let actualHash = try hasher.hash(of: cachedURL)
            if actualHash == manifest.sha256 {
                BarkLog.stt.info("model cache hit: \(manifest.modelID, privacy: .public)")
                return cachedURL
            }
            // Stale or corrupt — drop and re-download.
            try? FileManager.default.removeItem(at: cachedURL)
        }

        // Manifest pin: refuse anything that isn't HTTPS (defense in depth — the
        // manifest's URL is also pinned by being part of the bundled JSON).
        guard manifest.url.scheme?.lowercased() == "https" else {
            throw ModelError.insecureURL(manifest.url.absoluteString)
        }

        // Stream the download to a system-managed temporary file via
        // URLSession.download(from:), then hash that file in constant memory
        // (1 MB chunks in CryptoKitSHA256). The temp file is removed by the
        // `defer` below; the final `moveItem` is a rename-based move on APFS
        // (the typical macOS filesystem), which is effectively atomic for
        // concurrent `ensureModel` callers.
        let (tempURL, response) = try await session.download(from: manifest.url)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw STTError.engineFailure("model download failed: HTTP \(http.statusCode)")
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: tempURL.path)
        let actualSize = (attrs[.size] as? UInt64) ?? 0
        if actualSize != manifest.sizeBytes {
            throw ModelError.sizeMismatch(expected: manifest.sizeBytes, actual: actualSize)
        }

        let actualHash = try hasher.hash(of: tempURL)
        guard actualHash == manifest.sha256 else {
            // Hash mismatch: the file MUST NOT land in the cache. We never write
            // it to `cachedURL`, so the next call will retry. (See SEC-003.)
            throw ModelError.hashMismatch(manifest: manifest.sha256, actual: actualHash)
        }

        // Atomic move into the cache so concurrent `ensureModel` callers can't
        // observe a half-written file.
        try? FileManager.default.removeItem(at: cachedURL)
        try FileManager.default.moveItem(at: tempURL, to: cachedURL)
        BarkLog.stt.info("model cached: \(manifest.modelID, privacy: .public)")
        return cachedURL
    }

    public func removeCached(for manifest: ModelManifest) async throws {
        let url = ModelStore.cachedURL(for: manifest, in: cacheDirectory)
        try? FileManager.default.removeItem(at: url)
    }
}