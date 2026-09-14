import Foundation

/// Quality tier of a system speech voice, ordered worst → best. Mirrors
/// `AVSpeechSynthesisVoiceQuality` without importing AVFoundation, so the
/// selection policy stays pure and testable in `BarkCore`.
public enum VoiceTier: Int, Comparable, Sendable, Codable {
    case basic = 0      // compact / super-compact — robotic, always installed
    case enhanced = 1   // downloadable, noticeably better
    case premium = 2    // downloadable, best Apple ships to third-party apps

    public static func < (lhs: VoiceTier, rhs: VoiceTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .basic: return "Basic"
        case .enhanced: return "Enhanced"
        case .premium: return "Premium"
        }
    }
}

/// One installed voice, as the UI and the selection policy see it.
public struct VoiceOption: Sendable, Equatable, Identifiable {
    public var identifier: String
    public var name: String
    public var language: String   // BCP-47, e.g. "en-US"
    public var tier: VoiceTier

    public var id: String { identifier }

    public init(identifier: String, name: String, language: String, tier: VoiceTier) {
        self.identifier = identifier
        self.name = name
        self.language = language
        self.tier = tier
    }

    /// Joke voices macOS ships (`Bad News`, `Zarvox`, `Bells`, `Whisper`…).
    /// They report the same `basic` tier as real compact voices, so tier alone
    /// can't exclude them — auto-selection must never land on one.
    public var isNovelty: Bool {
        identifier.hasPrefix("com.apple.speech.synthesis.voice.")
    }

    /// Eloquence — the retro DECtalk-style formant synthesizer (`Eddy`, `Flo`,
    /// `Grandma`…). Real voices, but markedly more robotic than even the
    /// compact ones, so they're excluded from auto-selection too.
    public var isLegacyFormant: Bool {
        identifier.hasPrefix("com.apple.eloquence.")
    }

    /// Eligible for automatic selection (the user may still pick these by hand).
    public var isAutoSelectable: Bool { !isNovelty && !isLegacyFormant }
}

/// What the synthesizer should use for one utterance.
public struct SpeechVoiceConfig: Sendable, Equatable {
    /// Voice identifier, or nil to let the platform choose its default.
    public var voiceIdentifier: String?
    /// Platform-normalized speech rate (`AVSpeechUtteranceDefaultSpeechRate`
    /// is 0.5); `nil` keeps the platform default.
    public var rate: Float?

    public init(voiceIdentifier: String? = nil, rate: Float? = nil) {
        self.voiceIdentifier = voiceIdentifier
        self.rate = rate
    }
}

/// Picks which installed voice to speak with (017 follow-up). Bark's first cut
/// set no voice at all, so `AVSpeechSynthesizer` fell back to the platform
/// default — a *compact* voice on a stock Mac, which is the single biggest
/// cause of "the TTS sounds terrible". This policy prefers the best installed
/// tier for the user's language and never auto-selects a novelty or Eloquence
/// voice.
public enum VoiceSelector {
    /// Voices offered in the picker for `language`, best tier first. Novelty
    /// and Eloquence voices are included (a user may want `Zarvox`) but sorted
    /// last so they can't be mistaken for the recommended choice.
    public static func options(from all: [VoiceOption], language: String) -> [VoiceOption] {
        matching(all, language: language).sorted { a, b in
            if a.isAutoSelectable != b.isAutoSelectable { return a.isAutoSelectable }
            if a.tier != b.tier { return a.tier > b.tier }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// The voice to speak with: the user's explicit choice when it is still
    /// installed, else the best auto-selectable voice for `language`, else nil
    /// (caller falls back to the platform default).
    public static func best(from all: [VoiceOption],
                            language: String,
                            preferred: String?) -> VoiceOption? {
        if let preferred, !preferred.isEmpty,
           let chosen = all.first(where: { $0.identifier == preferred }) {
            return chosen   // honor an explicit pick, novelty included
        }
        return options(from: all, language: language).first { $0.isAutoSelectable }
    }

    /// True when a better tier than `current` exists on this machine for
    /// `language` — drives the "download a Premium voice" hint.
    public static func hasBetterTierAvailable(than current: VoiceTier,
                                              from all: [VoiceOption],
                                              language: String) -> Bool {
        matching(all, language: language).contains { $0.isAutoSelectable && $0.tier > current }
    }

    /// Voices for `language`, preferring an exact region match and falling
    /// back to the same base language ("en-US" → any "en-*") so a user whose
    /// only good voice is `en-GB` still gets it.
    static func matching(_ all: [VoiceOption], language: String) -> [VoiceOption] {
        let exact = all.filter { $0.language.caseInsensitiveCompare(language) == .orderedSame }
        if !exact.isEmpty { return exact }
        let base = baseLanguage(language)
        return all.filter { baseLanguage($0.language).caseInsensitiveCompare(base) == .orderedSame }
    }

    static func baseLanguage(_ tag: String) -> String {
        String(tag.split(separator: "-").first ?? Substring(tag))
    }
}
