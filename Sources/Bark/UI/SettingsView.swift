import SwiftUI
import BarkCore

/// Settings root: the labeled tab bar and pane switch. Each pane lives in its
/// own file under `UI/Settings/` (014 split of the former 900-line monolith).
struct SettingsView: View {
    @Bindable var controller: DictationController
    @State private var pane: Pane = .general

    /// Single source of truth for the settings window size — `WindowManager`
    /// sizes the NSWindow from this too.
    static let windowSize = CGSize(width: 480, height: 430)

    enum Pane: String, CaseIterable, Identifiable {
        case general, hotkey, modes, models, history, permissions, privacy
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: "gearshape"
            case .hotkey: "keyboard"
            case .modes: "slider.horizontal.3"
            case .models: "externaldrive.badge.checkmark"
            case .history: "clock"
            case .permissions: "lock.shield"
            case .privacy: "hand.raised"
            }
        }
        var title: String {
            switch self {
            case .general: "General"
            case .hotkey: "Hotkey"
            case .modes: "Modes"
            case .models: "Models"
            case .history: "History"
            case .permissions: "Permissions"
            case .privacy: "Privacy"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(Pane.allCases) { item in
                    Button {
                        pane = item
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: item.icon)
                                .font(.system(size: 15, weight: .medium))
                            Text(item.title)
                                .font(.system(size: 9))
                        }
                        .frame(width: 58, height: 42)
                        .background(pane == item ? Color.accentColor.opacity(0.18) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .foregroundStyle(pane == item ? Color.accentColor : .secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(item.title)
                    .accessibilityLabel(item.title)
                    .accessibilityAddTraits(pane == item ? .isSelected : [])
                }
            }
            .padding(8)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Settings sections")
            Divider()

            Group {
                switch pane {
                case .general: GeneralPane(controller: controller)
                case .hotkey: HotkeyPane(controller: controller)
                case .modes: ModesPane(controller: controller)
                case .models: ModelsPane()
                case .history: HistoryPane(controller: controller)
                case .permissions: PermissionsPane(controller: controller)
                case .privacy: PrivacyPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        .onAppear { controller.refreshPermissions() }
    }
}
