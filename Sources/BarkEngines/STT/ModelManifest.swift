import Foundation
import CryptoKit
import BarkCore

/// Integrity-verified description of an STT backend's model bundle.
///
/// A manifest is JSON of the form:
/// ```json
/// {
///   "modelID": "whisper-large-v3-turbo-coreml",
///   "backend": "whisperkit",
///   "url":     "https://huggingface.co/.../resolve/main/weights.bin",
///   "sha256":  "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
///   "sizeBytes": 821456789,
///   "minOSVersion": "26.0"
/// }
/// ```
///
/// The downloader (`ModelDownloader`) compares the SHA-256 of every downloaded
/// byte against `sha256` before the file is allowed into the model cache
/// (`SEC-003 / T-010`). Manifests themselves live in the app bundle or behind
/// a pinned HTTPS endpoint with a separate signature field (future hardening).
public struct ModelManifest: Codable, Sendable, Equatable {
    /// HuggingFace model id or local folder name (passed to the engine).
    public let modelID: String
    /// Which `STTBackendID` this manifest's weights belong to.
    public let backend: STTBackendID
    /// Source URL — HTTPS-only at the call site.
    public let url: URL
    /// Lowercase hex SHA-256 of the file contents.
    public let sha256: String
    /// Expected size in bytes (downloaders reject mismatches before hashing).
    public let sizeBytes: UInt64
    /// Optional: minimum macOS the engine requires (factory surfaces a clean
    /// error rather than a late crash).
    public let minOSVersion: String?

    public init(modelID: String, backend: STTBackendID, url: URL,
                sha256: String, sizeBytes: UInt64, minOSVersion: String? = nil) {
        self.modelID = modelID
        self.backend = backend
        self.url = url
        self.sha256 = sha256.lowercased()
        self.sizeBytes = sizeBytes
        self.minOSVersion = minOSVersion
    }

    /// Custom decoder that normalises `sha256` to lowercase so manifests with
    /// uppercase hex (e.g. from some hash-utility output) don't silently pass
    /// `sha256Bytes` validation while then failing the hash comparison in
    /// `ModelDownloader`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelID = try c.decode(String.self, forKey: .modelID)
        backend = try c.decode(STTBackendID.self, forKey: .backend)
        url = try c.decode(URL.self, forKey: .url)
        sha256 = try c.decode(String.self, forKey: .sha256).lowercased()
        sizeBytes = try c.decode(UInt64.self, forKey: .sizeBytes)
        minOSVersion = try c.decodeIfPresent(String.self, forKey: .minOSVersion)
    }

    /// Decoded hex SHA-256 (`Data`), or `nil` if the manifest's field is not a
    /// valid 64-character hex string. Validated up-front so a bad manifest never
    /// reaches the downloader.
    public var sha256Bytes: Data? {
        guard sha256.count == 64,
              sha256.allSatisfy(\.isHexDigit) else { return nil }
        var bytes = Data(capacity: 32)
        var index = sha256.startIndex
        for _ in 0..<32 {
            let next = sha256.index(index, offsetBy: 2)
            guard let byte = UInt8(sha256[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}

/// Errors raised by the manifest / download / verification pipeline. Conforms
/// to `LocalizedError` so `DictationController.describe(_:)` can surface a
/// meaningful message to the user rather than a generic NSError string.
public enum ModelError: Error, LocalizedError, Sendable, Equatable {
    case manifestMalformed(String)
    case hashMismatch(manifest: String, actual: String)
    case sizeMismatch(expected: UInt64, actual: UInt64)
    case insecureURL(String)
    case directoryUnavailable

    public var errorDescription: String? {
        switch self {
        case .manifestMalformed(let detail):
            return "Model manifest is invalid: \(detail)"
        case .hashMismatch(let expected, let actual):
            return "Model integrity check failed (expected \(expected.prefix(8))…, got \(actual.prefix(8))…). The file may be corrupted or tampered with."
        case .sizeMismatch(let expected, let actual):
            return "Model size mismatch (expected \(expected) bytes, got \(actual) bytes)."
        case .insecureURL(let url):
            return "Model URL is not HTTPS: \(url). Download refused for security."
        case .directoryUnavailable:
            return "The model cache directory could not be created."
        }
    }
}

/// Computes SHA-256 over a file's contents in constant memory (chunked read) so
/// multi-gigabyte model bundles don't need to fit in RAM. The protocol is kept
/// narrow — it's a single method on a single concern — so tests can fake it
/// without touching networking or the filesystem.
public protocol SHA256Hashing: Sendable {
    func hash(of fileURL: URL) throws -> String
    func hash(of data: Data) -> String
}

/// Production implementation backed by CryptoKit. Streams the file in 1 MB
/// chunks; the result is returned as lowercase hex (matching the manifest's
/// expected form).
public struct CryptoKitSHA256: SHA256Hashing {
    public init() {}

    public func hash(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public func hash(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}