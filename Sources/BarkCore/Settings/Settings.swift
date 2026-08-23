import Foundation

/// Persisted hotkey choice. Stored as raw values so `BarkCore` stays free of
/// CoreGraphics; `BarkEngines` maps this to/from `HotkeyConfig`.
public struct HotkeySetting: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case modifierHold   // push-to-talk: hold a modifier
        case keyToggle      // tap a key to toggle
    }

    public var kind: Kind
    public var keyCode: UInt16      // virtual key (keyToggle)
    public var modifierFlags: UInt64 // CGEventFlags rawValue (modifierHold)

    public init(kind: Kind = .modifierHold, keyCode: UInt16 = 0, modifierFlags: UInt64 = HotkeySetting.fnFlag) {
        self.kind = kind
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
    }

    /// CGEventFlags.maskSecondaryFn raw value (the fn / Globe key).
    public static let fnFlag: UInt64 = 0x800000

    public static let `default` = HotkeySetting()

    /// Human-readable label for the UI.
    public var displayName: String {
        switch kind {
        case .modifierHold:
            switch modifierFlags {
            case Self.fnFlag: return "Hold fn (Globe)"
            case 0x100000: return "Hold ⌘"
            case 0x80000:  return "Hold ⌥"
            case 0x40000:  return "Hold ⌃"
            case 0x20000:  return "Hold ⇧"
            default:       return "Hold modifier"
            }
        case .keyToggle:
            return Self.modifierSymbols(modifierFlags) + Self.keyName(keyCode)
        }
    }

    /// ⌃⌥⌘⇧ symbols for the held modifiers, in the conventional order.
    static func modifierSymbols(_ flags: UInt64) -> String {
        var s = ""
        if flags & 0x40000  != 0 { s += "⌃" }
        if flags & 0x80000  != 0 { s += "⌥" }
        if flags & 0x20000  != 0 { s += "⇧" }
        if flags & 0x100000 != 0 { s += "⌘" }
        return s
    }

    /// Best-effort US-layout name for a virtual keycode (enough for the keys the
    /// recorder accepts: letters, digits, function keys, space).
    static func keyName(_ code: UInt16) -> String {
        Self.keyNames[code] ?? "key \(code)"
    }

    static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 32: "U", 34: "I",
        31: "O", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        49: "Space", 36: "Return", 48: "Tab",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
    ]
}

/// All user-configurable, persisted state. Encoded as JSON in `UserDefaults`.
public struct Settings: Codable, Sendable, Equatable {
    public var selectedModeID: String
    public var customModes: [Mode]
    public var builtInPromptOverrides: [String: PromptOverride]   // built-in modeID → prompt edits (013)
    public var appModeMap: [String: String]   // focused-app bundleID → modeID
    public var localeID: String
    public var sttBackend: STTBackendID
    public var hotkey: HotkeySetting
    public var handsFreeHotkey: HotkeySetting
    public var vadSensitivity: VADSensitivity
    public var speakerGateEnabled: Bool
    public var speakerSensitivity: SpeakerVerificationSensitivity
    public var launchAtLogin: Bool
    public var historyEnabled: Bool
    public var llmEnabled: Bool
    public var restoreClipboard: Bool
    public var outputRouting: OutputRouting
    public var soundFeedback: Bool
    public var enhancedHUD: Bool
    public var holdToRefineEnabled: Bool   // 012: opt-in to the hold-to-refine second stage
    public var hasCompletedOnboarding: Bool

    // Suggested responses (015). The external API key lives in the Keychain
    // (`KeychainSecretStore`), never in this blob (FR-013).
    public var suggestionsEnabled: Bool
    public var suggestionsHotkey: HotkeySetting
    public var suggestionBackend: SuggestionBackendID
    public var externalLLMEndpoint: String    // OpenAI-compatible base URL, e.g. http://localhost:11434/v1
    public var externalLLMModel: String       // chat-completions model name
    public var suggestionAutoSubmit: Bool     // ADR-010 exception: opt-in Return after a picked suggestion

    public init(
        selectedModeID: String = Mode.clean.id,
        customModes: [Mode] = [],
        builtInPromptOverrides: [String: PromptOverride] = [:],
        appModeMap: [String: String] = [:],
        localeID: String = "en-US",
        sttBackend: STTBackendID = .apple,
        hotkey: HotkeySetting = .default,
        handsFreeHotkey: HotkeySetting = HotkeySetting(kind: .keyToggle, keyCode: 96, modifierFlags: 0),
        vadSensitivity: VADSensitivity = .medium,
        speakerGateEnabled: Bool = false,   // opt-in, like historyEnabled/llmEnabled
        speakerSensitivity: SpeakerVerificationSensitivity = .medium,
        launchAtLogin: Bool = false,
        historyEnabled: Bool = false,
        llmEnabled: Bool = false,   // opt-in: enabling triggers the ~2.5 GB model download (consent)
        restoreClipboard: Bool = true,
        outputRouting: OutputRouting = .insert,
        soundFeedback: Bool = true,
        enhancedHUD: Bool = false,
        holdToRefineEnabled: Bool = true,   // 012: on by default when an LLM is present (gesture is opt-in by nature)
        hasCompletedOnboarding: Bool = false,
        suggestionsEnabled: Bool = false,   // opt-in master switch (015)
        // ⌃⌥S: a chord, so it never needs the fn/function-key row (which would
        // collide with the fn-hold push-to-talk). keyCode 1 = 'S';
        // modifierFlags = maskControl(0x40000) | maskAlternate(0x80000).
        suggestionsHotkey: HotkeySetting = HotkeySetting(kind: .keyToggle, keyCode: 1, modifierFlags: 0xC0000),
        suggestionBackend: SuggestionBackendID = .local,
        externalLLMEndpoint: String = "",
        externalLLMModel: String = "",
        suggestionAutoSubmit: Bool = false
    ) {
        self.selectedModeID = selectedModeID
        self.customModes = customModes
        self.builtInPromptOverrides = builtInPromptOverrides
        self.appModeMap = appModeMap
        self.localeID = localeID
        self.sttBackend = sttBackend
        self.hotkey = hotkey
        self.handsFreeHotkey = handsFreeHotkey
        self.vadSensitivity = vadSensitivity
        self.speakerGateEnabled = speakerGateEnabled
        self.speakerSensitivity = speakerSensitivity
        self.launchAtLogin = launchAtLogin
        self.historyEnabled = historyEnabled
        self.llmEnabled = llmEnabled
        self.restoreClipboard = restoreClipboard
        self.outputRouting = outputRouting
        self.soundFeedback = soundFeedback
        self.enhancedHUD = enhancedHUD
        self.holdToRefineEnabled = holdToRefineEnabled
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.suggestionsEnabled = suggestionsEnabled
        self.suggestionsHotkey = suggestionsHotkey
        self.suggestionBackend = suggestionBackend
        self.externalLLMEndpoint = externalLLMEndpoint
        self.externalLLMModel = externalLLMModel
        self.suggestionAutoSubmit = suggestionAutoSubmit
    }

    public static let `default` = Settings()

    /// Decode tolerant of older/newer payloads (missing keys → defaults).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings.default
        selectedModeID = try c.decodeIfPresent(String.self, forKey: .selectedModeID) ?? d.selectedModeID
        customModes = try c.decodeIfPresent([Mode].self, forKey: .customModes) ?? d.customModes
        builtInPromptOverrides = try c.decodeIfPresent([String: PromptOverride].self, forKey: .builtInPromptOverrides) ?? d.builtInPromptOverrides
        appModeMap = try c.decodeIfPresent([String: String].self, forKey: .appModeMap) ?? d.appModeMap
        localeID = try c.decodeIfPresent(String.self, forKey: .localeID) ?? d.localeID
        sttBackend = try c.decodeIfPresent(STTBackendID.self, forKey: .sttBackend) ?? d.sttBackend
        hotkey = try c.decodeIfPresent(HotkeySetting.self, forKey: .hotkey) ?? d.hotkey
        handsFreeHotkey = try c.decodeIfPresent(HotkeySetting.self, forKey: .handsFreeHotkey) ?? d.handsFreeHotkey
        vadSensitivity = try c.decodeIfPresent(VADSensitivity.self, forKey: .vadSensitivity) ?? d.vadSensitivity
        speakerGateEnabled = try c.decodeIfPresent(Bool.self, forKey: .speakerGateEnabled) ?? d.speakerGateEnabled
        speakerSensitivity = try c.decodeIfPresent(SpeakerVerificationSensitivity.self, forKey: .speakerSensitivity) ?? d.speakerSensitivity
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        historyEnabled = try c.decodeIfPresent(Bool.self, forKey: .historyEnabled) ?? d.historyEnabled
        llmEnabled = try c.decodeIfPresent(Bool.self, forKey: .llmEnabled) ?? d.llmEnabled
        restoreClipboard = try c.decodeIfPresent(Bool.self, forKey: .restoreClipboard) ?? d.restoreClipboard
        outputRouting = try c.decodeIfPresent(OutputRouting.self, forKey: .outputRouting) ?? d.outputRouting
        soundFeedback = try c.decodeIfPresent(Bool.self, forKey: .soundFeedback) ?? d.soundFeedback
        enhancedHUD = try c.decodeIfPresent(Bool.self, forKey: .enhancedHUD) ?? d.enhancedHUD
        holdToRefineEnabled = try c.decodeIfPresent(Bool.self, forKey: .holdToRefineEnabled) ?? d.holdToRefineEnabled
        hasCompletedOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? d.hasCompletedOnboarding
        suggestionsEnabled = try c.decodeIfPresent(Bool.self, forKey: .suggestionsEnabled) ?? d.suggestionsEnabled
        suggestionsHotkey = try c.decodeIfPresent(HotkeySetting.self, forKey: .suggestionsHotkey) ?? d.suggestionsHotkey
        suggestionBackend = try c.decodeIfPresent(SuggestionBackendID.self, forKey: .suggestionBackend) ?? d.suggestionBackend
        externalLLMEndpoint = try c.decodeIfPresent(String.self, forKey: .externalLLMEndpoint) ?? d.externalLLMEndpoint
        externalLLMModel = try c.decodeIfPresent(String.self, forKey: .externalLLMModel) ?? d.externalLLMModel
        suggestionAutoSubmit = try c.decodeIfPresent(Bool.self, forKey: .suggestionAutoSubmit) ?? d.suggestionAutoSubmit
    }

    /// The mode list everything runs on: built-ins with any user prompt
    /// overrides applied, then custom modes. Single source of truth so the
    /// settings UI, per-app resolution, and the pipeline all see the same
    /// prompts (013 / SC-001).
    public func effectiveModes() -> [Mode] {
        // Invalid overrides (e.g. a hand-edited defaults payload over the field
        // bound) are ignored, so FR-009 holds regardless of writer (ADV-004).
        Mode.builtInModes.map { shipped in
            let override = builtInPromptOverrides[shipped.id]
            return shipped.applyingOverride(override?.isValid == true ? override : nil)
        } + customModes
    }

    /// Build a `ModeRegistry` from the effective modes with the saved selection.
    public func makeModeRegistry() -> ModeRegistry {
        ModeRegistry(modes: effectiveModes(), selectedID: selectedModeID)
    }
}
