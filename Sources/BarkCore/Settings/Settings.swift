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
            return "Toggle: key \(keyCode)"
        }
    }
}

/// All user-configurable, persisted state. Encoded as JSON in `UserDefaults`.
public struct Settings: Codable, Sendable, Equatable {
    public var selectedModeID: String
    public var customModes: [Mode]
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
    public var hasCompletedOnboarding: Bool

    public init(
        selectedModeID: String = Mode.clean.id,
        customModes: [Mode] = [],
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
        hasCompletedOnboarding: Bool = false
    ) {
        self.selectedModeID = selectedModeID
        self.customModes = customModes
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
        self.hasCompletedOnboarding = hasCompletedOnboarding
    }

    public static let `default` = Settings()

    /// Decode tolerant of older/newer payloads (missing keys → defaults).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings.default
        selectedModeID = try c.decodeIfPresent(String.self, forKey: .selectedModeID) ?? d.selectedModeID
        customModes = try c.decodeIfPresent([Mode].self, forKey: .customModes) ?? d.customModes
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
        hasCompletedOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? d.hasCompletedOnboarding
    }

    /// Build a `ModeRegistry` from built-ins + custom modes with the saved selection.
    public func makeModeRegistry() -> ModeRegistry {
        ModeRegistry(modes: Mode.builtInModes + customModes, selectedID: selectedModeID)
    }
}
