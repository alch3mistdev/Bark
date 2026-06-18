import SwiftUI
import BarkCore
import BarkEngines

struct MenuContentView: View {
    @Bindable var controller: DictationController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !controller.permissionsReady {
                PermissionsBanner(controller: controller)
                Divider()
            }

            modePicker

            if !controller.liveText.isEmpty {
                Text(controller.liveText)
                    .font(.callout)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }

            if let error = controller.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            controlButton

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Image(systemName: controller.phase.menuSymbol)
                .foregroundStyle(controller.phase.isActive ? Color.accentColor : .secondary)
            Text(controller.phase.title).font(.headline)
            Spacer()
            if !controller.isModelReady {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var modePicker: some View {
        Picker("Mode", selection: $controller.modeRegistry.selectedID) {
            ForEach(controller.modeRegistry.modes) { mode in
                Label(mode.name, systemImage: mode.symbol).tag(mode.id)
            }
        }
        .pickerStyle(.menu)
        .disabled(controller.phase.isActive)
    }

    @ViewBuilder
    private var controlButton: some View {
        if controller.phase.isActive {
            Button {
                controller.stopDictation()
            } label: {
                Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.escape, modifiers: [])
        } else {
            Button {
                controller.startDictation()
            } label: {
                Label("Start dictation", systemImage: "mic.fill").frame(maxWidth: .infinity)
            }
            .disabled(!controller.isModelReady || !controller.permissionsReady)
        }
    }

    private var footer: some View {
        HStack {
            Text("Hold fn to talk")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Settings…") { openSettings() }
                .buttonStyle(.link)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.link)
        }
    }
}

struct PermissionsBanner: View {
    @Bindable var controller: DictationController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Permissions needed", systemImage: "lock.shield")
                .font(.subheadline.bold())
            ForEach(PermissionKind.allCases, id: \.self) { kind in
                let state = controller.permissions.state(of: kind)
                if state != .granted {
                    Button {
                        controller.requestPermission(kind)
                    } label: {
                        HStack {
                            Image(systemName: "circle")
                            Text(label(for: kind))
                            Spacer()
                            Text("Grant").font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func label(for kind: PermissionKind) -> String {
        switch kind {
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility (type into apps)"
        case .inputMonitoring: return "Input Monitoring (global hotkey)"
        }
    }
}
