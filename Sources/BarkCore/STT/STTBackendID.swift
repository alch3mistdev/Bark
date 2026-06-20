import Foundation

/// Identifies which concrete `STTEngine` implementation should handle a session.
///
/// Lives in `BarkCore` so the protocol layer is dependency-free (constitution
/// principle III). Real engines live in `BarkEngines` behind `#if` flags so the
/// lean build still ships with a single, fully-tested pipeline.
///
/// Persisted in `Settings.sttBackend`; serialized as the raw string so a future
/// backend (e.g. a smaller on-device Parakeet variant) can be added without
/// breaking older settings payloads (settings decode tolerantly — see
/// `Settings.init(from:)`).
public enum STTBackendID: String, Codable, Sendable, CaseIterable, Equatable, Identifiable {
    /// Apple `SpeechAnalyzer` / `SpeechTranscriber` (macOS 26). Default — lowest
    /// latency, ANE, zero bundled weight, fully offline after the locale install.
    /// Always available.
    case apple

    /// Argmax WhisperKit — Whisper (tiny → large-v3) on Core ML / ANE. 99+ languages,
    /// broader accent/noise robustness than Apple STT. Available when the binary
    /// is built with `Package-stt-extras.swift` (`WHISPERKIT` defined).
    case whisperkit

    /// NVIDIA Parakeet TDT-0.6b-v3 via FluidAudio (Core ML, ANE). 25 languages,
    /// Apache-2.0. Available when the binary is built with `Package-stt-extras.swift`
    /// (`FLUIDAUDIO` defined).
    case parakeet

    /// Stable identifier for SwiftUI `ForEach` and `Picker` (via `Identifiable`).
    public var id: String { rawValue }

    /// Tolerant decoder: unknown future raw values fall back to `.apple` so a
    /// settings payload written by a newer build never bricks an older one.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = STTBackendID(rawValue: raw) ?? .apple
    }

    /// Human-readable label for the Settings UI.
    public var displayName: String {
        switch self {
        case .apple:      return "Apple SpeechAnalyzer"
        case .whisperkit: return "WhisperKit (Argmax)"
        case .parakeet:   return "Parakeet (FluidAudio)"
        }
    }

    /// One-sentence pitch shown next to the picker (UI uses `.secondary`).
    public var blurb: String {
        switch self {
        case .apple:
            return "Lowest latency, runs on the Neural Engine. Always available."
        case .whisperkit:
            return "Whisper on Core ML. 99+ languages, robust to accent and noise."
        case .parakeet:
            return "NVIDIA Parakeet TDT. 25 languages, Apache-2.0."
        }
    }

    /// Whether the backend is compiled into the running binary. The lean default
    /// build (`Package.swift`) reports `false` for `whisperkit` and `parakeet`.
    public var isCompiledIn: Bool {
        switch self {
        case .apple:      return true
        case .whisperkit: return STTBackendCompilationFlags.whisperKit
        case .parakeet:   return STTBackendCompilationFlags.fluidAudio
        }
    }
}

/// Build-time flags surfaced at runtime so the UI / factory can offer only
/// backends that are actually present in the binary.
///
/// Mirrors the `#if WHISPERKIT` / `#if FLUIDAUDIO` gates in
/// `WhisperKitEngine.swift` / `ParakeetEngine.swift`. `BarkEngines` is the only
/// place these symbols are defined; `BarkCore` re-exports them through a thin
/// façade so the protocol layer can stay dep-free.
public enum STTBackendCompilationFlags: Sendable {
    #if WHISPERKIT
    public static let whisperKit = true
    #else
    public static let whisperKit = false
    #endif

    #if FLUIDAUDIO
    public static let fluidAudio = true
    #else
    public static let fluidAudio = false
    #endif
}