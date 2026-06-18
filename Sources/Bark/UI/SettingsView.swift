import SwiftUI
import BarkCore
import BarkEngines

struct SettingsView: View {
    @Bindable var controller: DictationController

    var body: some View {
        TabView {
            GeneralPane(controller: controller)
                .tabItem { Label("General", systemImage: "gearshape") }
            PermissionsPane(controller: controller)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
            PrivacyPane()
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 460, height: 360)
        .onAppear { controller.refreshPermissions() }
    }
}

private struct GeneralPane: View {
    @Bindable var controller: DictationController

    var body: some View {
        Form {
            Section("Speech model") {
                LabeledContent("Engine", value: "Apple SpeechAnalyzer (on-device)")
                LabeledContent("Status", value: controller.isModelReady ? "Ready" : "Preparing…")
            }
            Section("Cleanup") {
                LabeledContent("Deterministic cleaner", value: "Always on")
                LabeledContent("LLM rewrite", value: controller.llmAvailable ? "Qwen3-4B (MLX)" : "Not installed")
                if !controller.llmAvailable {
                    Text("LLM modes (Email, Message, Code, List) fall back to the instant cleaner until the MLX engine is enabled. See the README.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Modes") {
                ForEach(controller.modeRegistry.modes) { mode in
                    HStack {
                        Label(mode.name, systemImage: mode.symbol)
                        Spacer()
                        if mode.usesLLM {
                            Text("LLM").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }
            }
            Section("Hotkey") {
                LabeledContent("Push to talk", value: "Hold fn (Globe)")
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionsPane: View {
    @Bindable var controller: DictationController

    var body: some View {
        Form {
            ForEach(PermissionKind.allCases, id: \.self) { kind in
                Section(title(kind)) {
                    let state = controller.permissions.state(of: kind)
                    HStack {
                        Image(systemName: icon(state))
                            .foregroundStyle(color(state))
                        Text(stateText(state))
                        Spacer()
                        Button("Grant") { controller.requestPermission(kind) }
                            .disabled(state == .granted)
                        Button("Open Settings") { controller.permissions.openSettings(for: kind) }
                    }
                    Text(why(kind)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func title(_ k: PermissionKind) -> String {
        switch k {
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        }
    }
    private func why(_ k: PermissionKind) -> String {
        switch k {
        case .microphone: return "Capture your voice while dictating."
        case .accessibility: return "Type the cleaned text into the focused app."
        case .inputMonitoring: return "Detect the global push-to-talk hotkey."
        }
    }
    private func icon(_ s: PermissionState) -> String {
        s == .granted ? "checkmark.circle.fill" : "exclamationmark.circle"
    }
    private func color(_ s: PermissionState) -> Color { s == .granted ? .green : .orange }
    private func stateText(_ s: PermissionState) -> String {
        switch s {
        case .granted: return "Granted"
        case .denied: return "Denied"
        case .notDetermined: return "Not requested"
        }
    }
}

private struct PrivacyPane: View {
    var body: some View {
        Form {
            Section("Fully offline by default") {
                Label("Audio never leaves your Mac", systemImage: "mic.slash")
                Label("Transcription runs on the Apple Neural Engine", systemImage: "cpu")
                Label("No telemetry, analytics, or accounts", systemImage: "network.slash")
            }
            Section("Safety") {
                Label("Never types into password / secure fields", systemImage: "key")
                Label("Never presses Return (won't run terminal commands)", systemImage: "terminal")
                Label("Restores your clipboard after pasting", systemImage: "doc.on.clipboard")
                Label("History is off by default", systemImage: "clock.arrow.circlepath")
            }
        }
        .formStyle(.grouped)
    }
}
