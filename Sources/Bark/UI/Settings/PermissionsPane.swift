import SwiftUI
import BarkEngines

struct PermissionsPane: View {
    @Bindable var controller: DictationController

    var body: some View {
        Form {
            ForEach(PermissionKind.allCases, id: \.self) { kind in
                Section(kind.displayName) {
                    let state = controller.permissions.state(of: kind)
                    HStack {
                        Image(systemName: icon(state)).foregroundStyle(color(state))
                        Text(stateText(state))
                        Spacer()
                        Button("Grant") { controller.requestPermission(kind) }.disabled(state == .granted)
                        Button("Open Settings") { controller.permissions.openSettings(for: kind) }
                    }
                    Text(kind.purpose).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func icon(_ s: PermissionState) -> String { s == .granted ? "checkmark.circle.fill" : "exclamationmark.circle" }
    private func color(_ s: PermissionState) -> Color { s == .granted ? .green : .orange }
    private func stateText(_ s: PermissionState) -> String {
        switch s { case .granted: "Granted"; case .denied: "Denied"; case .notDetermined: "Not requested" }
    }
}
