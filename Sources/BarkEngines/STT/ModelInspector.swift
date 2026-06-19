import Foundation
import AppKit
import BarkCore

/// A snapshot of one cached model bundle on disk. Used by the Settings UI to
/// show what's been verified-and-cached, and to surface drift (hash mismatch)
/// if a cached file's SHA-256 no longer matches its manifest.
public struct CachedModel: Sendable, Equatable, Identifiable {
    public let backend: STTBackendID
    public let modelID: String
    public let url: URL
    public let sizeBytes: UInt64
    public let modifiedAt: Date

    /// Result of re-verifying the file against its manifest, if a manifest is
    /// supplied. `nil` means we couldn't find a matching manifest in the bundle
    /// (e.g. user copied a file into the cache directory by hand).
    public let verification: Verification

    public enum Verification: Sendable, Equatable {
        case verified                          // SHA-256 matches manifest
        case hashMismatch(manifest: String, actual: String)
        case noManifestFound
        case notVerified(reason: String)
    }

    public var id: String { "\(backend.rawValue)/\(modelID)" }

    public var displaySize: String {
        ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }
}

/// Snapshot of the whole model cache directory. Cheap to compute (just
/// `FileManager.contentsOfDirectory` + per-file size); the SHA-256 verification
/// step is opt-in (`ModelInspector.verify(_:)`) so the UI can render the list
/// first and re-verify on demand.
public struct ModelCacheSnapshot: Sendable, Equatable {
    public let directory: URL
    public let models: [CachedModel]
    public let totalBytes: UInt64

    public static let empty = ModelCacheSnapshot(directory: ModelStore.defaultCacheDirectory,
                                                  models: [],
                                                  totalBytes: 0)

    public var displaySize: String {
        ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
    }
}

/// Read-only inspector for the model cache. Used by the Settings UI to render
/// the "Models" pane — shows what has been verified-and-cached, lets the user
/// re-verify, reveal in Finder, or delete individual bundles.
///
/// `ModelInspector` is intentionally side-effect-free for listing. Mutations
/// (delete / reveal) go through explicit methods so the UI can scope them
/// safely. We never auto-delete anything (mirrors the policy in
/// `EncryptedHistoryStore.purge` — user action only).
public actor ModelInspector {
    private let directory: URL
    private let hasher: SHA256Hashing
    private let bundle: Bundle

    public init(directory: URL = ModelStore.defaultCacheDirectory,
                hasher: SHA256Hashing = CryptoKitSHA256(),
                bundle: Bundle = .main) {
        self.directory = directory
        self.hasher = hasher
        self.bundle = bundle
    }

    /// List the cache. Each entry is paired with the matching manifest if one
    /// is bundled for that `(backend, modelID)`. Verification is NOT run here
    /// — call `verify(_:)` per row to check SHA-256.
    public func snapshot() async -> ModelCacheSnapshot {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else {
            return ModelCacheSnapshot(directory: directory, models: [], totalBytes: 0)
        }

        let manifestsByKey = bundledManifestsByKey()
        var models: [CachedModel] = []
        var total: UInt64 = 0
        for url in urls {
            let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = UInt64(attrs?.fileSize ?? 0)
            total += size

            guard let (backend, modelID) = parseCacheFileName(url.lastPathComponent) else {
                continue   // foreign file in our cache; ignore silently
            }
            let key = "\(backend.rawValue)/\(modelID)"
            let manifest = manifestsByKey[key]

            models.append(CachedModel(
                backend: backend,
                modelID: modelID,
                url: url,
                sizeBytes: size,
                modifiedAt: attrs?.contentModificationDate ?? .distantPast,
                verification: .notVerified(reason: "Tap Re-verify")
            ))
        }
        models.sort { $0.id < $1.id }
        return ModelCacheSnapshot(directory: directory, models: models, totalBytes: total)
    }

    /// Re-verify one cached bundle against its bundled manifest. Returns a new
    /// snapshot row with the verification result populated. Mismatches do NOT
    /// delete the file automatically — the user decides via the UI.
    public func verify(_ model: CachedModel) async -> CachedModel {
        guard let manifest = STTEngineFactory.bundledManifest(for: model.backend),
              manifest.modelID == model.modelID else {
            var copy = model
            copy.verification = .noManifestFound
            return copy
        }
        do {
            let actual = try hasher.hash(of: model.url)
            var copy = model
            copy.verification = (actual == manifest.sha256)
                ? .verified
                : .hashMismatch(manifest: manifest.sha256, actual: actual)
            return copy
        } catch {
            var copy = model
            copy.verification = .notVerified(reason: error.localizedDescription)
            return copy
        }
    }

    /// Remove a single cached bundle. Idempotent. No-op if the file is absent.
    public func remove(_ model: CachedModel) async {
        try? FileManager.default.removeItem(at: model.url)
    }

    /// Open Finder pointed at a cached bundle (or the cache root if nil).
    public func reveal(_ model: CachedModel? = nil) {
        let target = model?.url ?? directory
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    // MARK: - Helpers

    private func bundledManifestsByKey() -> [String: ModelManifest] {
        var dict: [String: ModelManifest] = [:]
        for id in STTBackendID.allCases {
            if let manifest = STTEngineFactory.bundledManifest(for: id) {
                dict["\(id.rawValue)/\(manifest.modelID)"] = manifest
            }
        }
        return dict
    }

    /// Parse `<backend>--<model>.bin` (see `ModelStore.cachedURL`). Returns
    /// `(backend, modelID)` if the filename matches our convention.
    private func parseCacheFileName(_ name: String) -> (STTBackendID, String)? {
        guard name.hasSuffix(".bin") else { return nil }
        let stripped = String(name.dropLast(4))
        guard let separator = stripped.range(of: "--") else { return nil }
        let rawBackend = String(stripped[..<separator.lowerBound])
        let modelID = String(stripped[separator.upperBound...])
        guard let backend = STTBackendID(rawValue: rawBackend), !modelID.isEmpty else {
            return nil
        }
        return (backend, modelID)
    }
}