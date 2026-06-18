import SwiftUI
import BarkCore
import BarkEngines

struct SettingsView: View {
    @Bindable var controller: DictationController

    var body: some View {
        TabView {
            GeneralPane(controller: controller)
                .tabItem { Label("General", systemImage: "gearshape") }
            HotkeyPane(controller: controller)
                .tabItem { Label("Hotkey", systemImage: "keyboard") }
            ModesPane(controller: controller)
                .tabItem { Label("Modes", systemImage: "slider.horizontal.3") }
            HistoryPane(controller: controller)
                .tabItem { Label("History", systemImage: "clock") }
            PermissionsPane(controller: controller)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
            PrivacyPane()
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 480, height: 420)
        .onAppear { controller.refreshPermissions() }
    }
}

// MARK: - General

private let supportedLocales: [(String, String)] = [
    ("en-US", "English (US)"), ("en-GB", "English (UK)"), ("es-ES", "Spanish"),
    ("fr-FR", "French"), ("de-DE", "German"), ("it-IT", "Italian"),
    ("pt-BR", "Portuguese (BR)"), ("ja-JP", "Japanese"), ("zh-CN", "Chinese"), ("ko-KR", "Korean"),
]

private struct GeneralPane: View {
    @Bindable var controller: DictationController

    var body: some View {
        Form {
            Section("Speech") {
                Picker("Language", selection: $controller.localeID) {
                    ForEach(supportedLocales, id: \.0) { Text($0.1).tag($0.0) }
                }
                LabeledContent("Engine", value: "Apple SpeechAnalyzer (on-device)")
                LabeledContent("Status", value: controller.isModelReady ? "Ready" : "Preparing…")
            }
            Section("Cleanup") {
                Toggle("Use LLM rewrite for LLM modes", isOn: $controller.llmEnabled)
                    .disabled(!controller.llmAvailable)
                LabeledContent("LLM engine", value: controller.llmAvailable ? "Qwen3-4B (MLX)" : "Not installed")
                if !controller.llmAvailable {
                    Text("LLM modes fall back to the instant cleaner until the MLX engine is enabled (see README).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Startup") {
                Toggle("Launch Bark at login", isOn: $controller.launchAtLogin)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Hotkey

private struct HotkeyPane: View {
    @Bindable var controller: DictationController

    var body: some View {
        Form {
            Section("Push-to-talk / toggle") {
                HotkeyRecorder(setting: $controller.hotkeySetting)
                Text("Hold a modifier (e.g. fn) to push-to-talk, or record a single key to toggle dictation on/off.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Modes

private struct ModesPane: View {
    @Bindable var controller: DictationController
    @State private var draft = Mode(id: "", name: "")
    @State private var editing = false

    var body: some View {
        Form {
            Section("Built-in") {
                ForEach(Mode.builtInModes) { mode in
                    HStack {
                        Label(mode.name, systemImage: mode.symbol)
                        Spacer()
                        if mode.usesLLM { tag("LLM") }
                    }
                }
            }
            Section("Custom") {
                let customs = controller.modes.filter { m in !Mode.builtInModes.contains { $0.id == m.id } }
                if customs.isEmpty {
                    Text("No custom modes yet.").foregroundStyle(.secondary)
                }
                ForEach(customs) { mode in
                    HStack {
                        Label(mode.name, systemImage: mode.symbol)
                        Spacer()
                        if mode.usesLLM { tag("LLM") }
                        Button(role: .destructive) { controller.removeMode(id: mode.id) } label: {
                            Image(systemName: "trash")
                        }.buttonStyle(.borderless)
                    }
                }
                Button("Add custom mode…") {
                    draft = Mode(id: "custom-\(UUID().uuidString.prefix(8))", name: "New Mode",
                                 symbol: "wand.and.stars", usesLLM: true,
                                 systemPrompt: "Rewrite the dictated text. Keep the meaning; do not add content.")
                    editing = true
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $editing) {
            ModeEditor(mode: $draft) { saved in
                controller.upsertMode(saved)
                editing = false
            } cancel: { editing = false }
        }
    }

    private func tag(_ s: String) -> some View {
        Text(s).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

private struct ModeEditor: View {
    @Binding var mode: Mode
    var save: (Mode) -> Void
    var cancel: () -> Void

    var body: some View {
        Form {
            TextField("Name", text: $mode.name)
            Toggle("Use LLM rewrite", isOn: $mode.usesLLM)
            VStack(alignment: .leading) {
                Text("System prompt (instruction to the rewrite model)").font(.caption)
                TextEditor(text: $mode.systemPrompt).frame(height: 100).font(.callout)
            }
            HStack {
                Button("Cancel", action: cancel)
                Spacer()
                Button("Save") { save(mode) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(mode.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 380)
    }
}

// MARK: - History

private struct HistoryPane: View {
    @Bindable var controller: DictationController
    @State private var records: [HistoryRecord] = []

    var body: some View {
        Form {
            Section {
                Toggle("Keep history (encrypted, on-device)", isOn: $controller.historyEnabled)
                Text("Off by default. When on, transcripts are stored encrypted (AES-GCM, key in Keychain).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Recent") {
                if records.isEmpty {
                    Text("No history.").foregroundStyle(.secondary)
                }
                ForEach(records) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.output).lineLimit(2)
                        Text(r.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .contextMenu {
                        Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(r.output, forType: .string) }
                    }
                }
                if !records.isEmpty {
                    Button("Purge all history", role: .destructive) {
                        Task { await controller.purgeHistory(); records = await controller.historyRecords() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { records = await controller.historyRecords() }
    }
}

// MARK: - Permissions

private struct PermissionsPane: View {
    @Bindable var controller: DictationController

    var body: some View {
        Form {
            ForEach(PermissionKind.allCases, id: \.self) { kind in
                Section(title(kind)) {
                    let state = controller.permissions.state(of: kind)
                    HStack {
                        Image(systemName: icon(state)).foregroundStyle(color(state))
                        Text(stateText(state))
                        Spacer()
                        Button("Grant") { controller.requestPermission(kind) }.disabled(state == .granted)
                        Button("Open Settings") { controller.permissions.openSettings(for: kind) }
                    }
                    Text(why(kind)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func title(_ k: PermissionKind) -> String {
        switch k { case .microphone: "Microphone"; case .accessibility: "Accessibility"; case .inputMonitoring: "Input Monitoring" }
    }
    private func why(_ k: PermissionKind) -> String {
        switch k {
        case .microphone: "Capture your voice while dictating."
        case .accessibility: "Type the cleaned text into the focused app."
        case .inputMonitoring: "Detect the global push-to-talk hotkey."
        }
    }
    private func icon(_ s: PermissionState) -> String { s == .granted ? "checkmark.circle.fill" : "exclamationmark.circle" }
    private func color(_ s: PermissionState) -> Color { s == .granted ? .green : .orange }
    private func stateText(_ s: PermissionState) -> String {
        switch s { case .granted: "Granted"; case .denied: "Denied"; case .notDetermined: "Not requested" }
    }
}

// MARK: - Privacy

private struct PrivacyPane: View {
    var body: some View {
        Form {
            Section("Fully offline by default") {
                Label("Audio never leaves your Mac", systemImage: "mic.slash")
                Label("Transcription runs on the Apple Neural Engine", systemImage: "cpu")
                Label("No telemetry, analytics, or accounts", systemImage: "network.slash")
            }
            Section("Safety") {
                Label("Avoids detected password / secure fields", systemImage: "key")
                Label("Never presses Return (won't run terminal commands)", systemImage: "terminal")
                Label("Restores your clipboard after pasting", systemImage: "doc.on.clipboard")
                Label("History is off by default, encrypted when on", systemImage: "lock.doc")
            }
        }
        .formStyle(.grouped)
    }
}
