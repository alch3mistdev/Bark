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
    public var hotkey: HotkeySetting
    public var handsFreeHotkey: HotkeySetting
    public var vadSensitivity: VADSensitivity
    public var launchAtLogin: Bool
    public var historyEnabled: Bool
    public var llmEnabled: Bool
    public var restoreClipboard: Bool
    public var outputRouting: OutputRouting
    public var soundFeedback: Bool
    public var enhancedHUD: Bool
    public var smartRepliesEnabled: Bool   // opt-in: lets Bark read the focused app's text for reply options (009)
    public var hasCompletedOnboarding: Bool

    public init(
        selectedModeID: String = Mode.clean.id,
        customModes: [Mode] = [],
        appModeMap: [String: String] = [:],
        localeID: String = "en-US",
        hotkey: HotkeySetting = .default,
        handsFreeHotkey: HotkeySetting = HotkeySetting(kind: .keyToggle, keyCode: 96, modifierFlags: 0),
        vadSensitivity: VADSensitivity = .medium,
        launchAtLogin: Bool = false,
        historyEnabled: Bool = false,
        llmEnabled: Bool = false,   // opt-in: enabling triggers the ~2.5 GB model download (consent)
        restoreClipboard: Bool = true,
        outputRouting: OutputRouting = .insert,
        soundFeedback: Bool = true,
        enhancedHUD: Bool = false,
        smartRepliesEnabled: Bool = false,   // off by default: reading other apps' text is a privacy expansion (009)
        hasCompletedOnboarding: Bool = false
    ) {
        self.selectedModeID = selectedModeID
        self.customModes = customModes
        self.appModeMap = appModeMap
        self.localeID = localeID
        self.hotkey = hotkey
        self.handsFreeHotkey = handsFreeHotkey
        self.vadSensitivity = vadSensitivity
        self.launchAtLogin = launchAtLogin
        self.historyEnabled = historyEnabled
        self.llmEnabled = llmEnabled
        self.restoreClipboard = restoreClipboard
        self.outputRouting = outputRouting
        self.soundFeedback = soundFeedback
        self.enhancedHUD = enhancedHUD
        self.smartRepliesEnabled = smartRepliesEnabled
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
        hotkey = try c.decodeIfPresent(HotkeySetting.self, forKey: .hotkey) ?? d.hotkey
        handsFreeHotkey = try c.decodeIfPresent(HotkeySetting.self, forKey: .handsFreeHotkey) ?? d.handsFreeHotkey
        vadSensitivity = try c.decodeIfPresent(VADSensitivity.self, forKey: .vadSensitivity) ?? d.vadSensitivity
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        historyEnabled = try c.decodeIfPresent(Bool.self, forKey: .historyEnabled) ?? d.historyEnabled
        llmEnabled = try c.decodeIfPresent(Bool.self, forKey: .llmEnabled) ?? d.llmEnabled
        restoreClipboard = try c.decodeIfPresent(Bool.self, forKey: .restoreClipboard) ?? d.restoreClipboard
        outputRouting = try c.decodeIfPresent(OutputRouting.self, forKey: .outputRouting) ?? d.outputRouting
        soundFeedback = try c.decodeIfPresent(Bool.self, forKey: .soundFeedback) ?? d.soundFeedback
        enhancedHUD = try c.decodeIfPresent(Bool.self, forKey: .enhancedHUD) ?? d.enhancedHUD
        smartRepliesEnabled = try c.decodeIfPresent(Bool.self, forKey: .smartRepliesEnabled) ?? d.smartRepliesEnabled
        hasCompletedOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? d.hasCompletedOnboarding
    }

    /// Build a `ModeRegistry` from built-ins + custom modes with the saved selection.
    public func makeModeRegistry() -> ModeRegistry {
        ModeRegistry(modes: Mode.builtInModes + customModes, selectedID: selectedModeID)
    }
}
