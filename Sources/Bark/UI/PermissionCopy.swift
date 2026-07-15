import BarkEngines

/// Single source of truth for permission display copy. Settings, onboarding,
/// and the menu banner all read these — previously three hand-rolled switches
/// with three different wordings.
extension PermissionKind {
    var displayName: String {
        switch self {
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        }
    }

    /// What Bark uses the permission for, in one sentence.
    var purpose: String {
        switch self {
        case .microphone: "Capture your voice while dictating (audio stays on-device)."
        case .accessibility: "Type the cleaned text into the app you're using."
        case .inputMonitoring: "Detect the global push-to-talk hotkey."
        }
    }
}
