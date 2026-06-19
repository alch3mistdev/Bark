import SwiftUI
import AppKit
import BarkCore
import BarkEngines

struct SettingsView: View {
    @Bindable var controller: DictationController
    @State private var pane: Pane = .general

    enum Pane: String, CaseIterable, Identifiable {
        case general, hotkey, modes, apps, history, permissions, privacy
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: "gearshape"
            case .hotkey: "keyboard"
            case .modes: "slider.horizontal.3"
            case .apps: "app.badge"
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
            case .apps: "Per-app modes"
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
                        Image(systemName: item.icon)
                            .font(.system(size: 16, weight: .medium))
                            .frame(width: 40, height: 32)
                            .background(pane == item ? Color.accentColor.opacity(0.18) : .clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                            .foregroundStyle(pane == item ? Color.accentColor : .secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(item.title)
                }
            }
            .padding(8)
            Divider()

            Group {
                switch pane {
                case .general: GeneralPane(controller: controller)
                case .hotkey: HotkeyPane(controller: controller)
                case .modes: ModesPane(controller: controller)
                case .apps: AppModesPane(controller: controller)
                case .history: HistoryPane(controller: controller)
                case .permissions: PermissionsPane(controller: controller)
                case .privacy: PrivacyPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 480, height: 430)
        .onAppear { controller.refreshPermissions() }
    }
}

// MARK: - General

private let supportedLocales: [(String, String)] = [
    ("en-US", "English (US)"), ("en-GB", "English (UK)"), ("es-ES", "Spanish"),
    ("fr-FR", "French"), ("de-DE", "German"), ("it-IT", "Italian"),
    ("pt-BR", "Portuguese (BR)"), ("ja-JP", "Japanese"), ("zh-CN", "Chinese"), ("ko-KR", "Korean"),
]

private struct AppModesPane: View {
    @Bindable var controller: DictationController
    @State private var newBundleID = ""
    @State private var newModeID = Mode.clean.id

    private var runningApps: [(name: String, bundleID: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in app.bundleIdentifier.map { (app.localizedName ?? $0, $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func appName(_ bundleID: String) -> String {
        runningApps.first { $0.bundleID == bundleID }?.name ?? bundleID
    }

    var body: some View {
        Form {
            Section("Auto-select mode by app") {
                let entries = controller.appModeMap.sorted { $0.key < $1.key }
                if entries.isEmpty {
                    Text("No app mappings yet. Add one below.").foregroundStyle(.secondary)
                }
                ForEach(entries, id: \.key) { bundleID, modeID in
                    HStack {
                        Text(appName(bundleID)).frame(maxWidth: .infinity, alignment: .leading)
                        Text(controller.modes.first { $0.id == modeID }?.name ?? modeID)
                            .foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            controller.setAppMode(bundleID: bundleID, modeID: nil)
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                }
            }
            Section("Add mapping") {
                Picker("App", selection: $newBundleID) {
                    Text("Choose…").tag("")
                    ForEach(runningApps, id: \.bundleID) { Text($0.name).tag($0.bundleID) }
                }
                Picker("Mode", selection: $newModeID) {
                    ForEach(controller.modes) { Text($0.name).tag($0.id) }
                }
                Button("Add mapping") {
                    controller.setAppMode(bundleID: newBundleID, modeID: newModeID)
                    newBundleID = ""
                }
                .disabled(newBundleID.isEmpty)
                Text("When you dictate into a mapped app, that mode is used automatically; other apps use "
                     + "your manual selection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct LLMStatusBadge: View {
    let status: LLMStatus
    var body: some View {
        switch status {
        case .unavailable:
            Text("Not in this build").foregroundStyle(.secondary)
        case .notLoaded:
            Text("Qwen3-4B — not downloaded").foregroundStyle(.secondary)
        case .downloading(let p):
            HStack(spacing: 8) {
                ProgressView(value: p).frame(width: 90)
                Text("\(Int(p * 100))%").monospacedDigit().foregroundStyle(.secondary)
            }
        case .ready:
            Label("Qwen3-4B ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }
}

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
                    .disabled(!controller.llmEnginePresent)

                LabeledContent("LLM engine") { LLMStatusBadge(status: controller.llmStatus) }

                if !controller.llmEnginePresent {
                    Text("This build ships without the on-device LLM. LLM modes (Email, Message, Code, "
                         + "List) use the instant deterministic cleaner. Install the MLX build "
                         + "(README → \u{201C}Enable LLM rewrite\u{201D}) to add Qwen3-4B.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    switch controller.llmStatus {
                    case .notLoaded:
                        Button("Download model (~2.5 GB)") { controller.prepareLLM() }
                    case .failed:
                        Button("Retry download") { controller.prepareLLM() }
                    default:
                        EmptyView()
                    }
                    Text("First download is ~2.5 GB; afterwards the model runs fully offline. Until it's "
                         + "ready, LLM modes use the instant cleaner.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Output") {
                Picker("When dictation ends", selection: $controller.outputRouting) {
                    ForEach(OutputRouting.allCases) { Text($0.label).tag($0) }
                }
                if controller.outputRouting == .copyOnly {
                    Text("Text is copied to the clipboard instead of typed. Paste it with ⌘V. "
                         + "Useful for apps where synthetic typing is unreliable.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Startup") {
                Toggle("Launch Bark at login", isOn: $controller.launchAtLogin)
            }
            Section("Feedback") {
                Toggle("Play start / insert sounds", isOn: $controller.soundFeedback)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Hotkey

private struct HotkeyPane: View {
    @Bindable var controller: DictationController
    // UI selection is local so "Custom" can show the recorder WITHOUT first
    // overwriting the persisted hotkey (the recorder commits the real key).
    @State private var mode: HotkeyPreset = .fn

    var body: some View {
        Form {
            Section("Trigger") {
                Picker("Hotkey", selection: $mode) {
                    ForEach(HotkeyPreset.allCases) { Text($0.label).tag($0) }
                }
                .disabled(controller.phase.isActive)
                .onChange(of: mode) { _, newValue in
                    if newValue == .fn {
                        controller.hotkeySetting = HotkeyPreset.fn.setting(currentCustom: controller.hotkeySetting)
                    }
                    // .custom → wait for the recorder to capture a key; don't apply a placeholder.
                }

                if mode == .custom {
                    LabeledContent("Toggle key") {
                        HotkeyRecorder(setting: $controller.hotkeySetting)
                    }
                    .disabled(controller.phase.isActive)
                }

                Text("Hold fn to push-to-talk (release to insert), or pick Custom and record a function "
                     + "key (F1–F20) to toggle dictation on/off. Changes apply immediately.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Hands-free") {
                Toggle("Hands-free dictation", isOn: Binding(
                    get: { controller.handsFreeActive },
                    set: { $0 ? controller.startHandsFree() : controller.stopHandsFree() }
                ))
                LabeledContent("Toggle key") {
                    HotkeyRecorder(setting: $controller.handsFreeHotkeySetting)
                }
                Picker("Sensitivity", selection: $controller.vadSensitivity) {
                    ForEach(VADSensitivity.allCases) { Text($0.label).tag($0) }
                }
                Text("When on, Bark records whenever you speak and inserts when you pause — no button to "
                     + "hold. Press the toggle key (default F5) to turn it on/off.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { mode = HotkeyPreset.from(controller.hotkeySetting) }
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
    @State private var query = ""
    @State private var copiedID: UUID?

    var body: some View {
        Form {
            Section {
                Toggle("Keep history (encrypted, on-device)", isOn: $controller.historyEnabled)
                Text("Off by default. When on, transcripts are stored encrypted (AES-GCM, key in Keychain).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("History") {
                TextField("Search", text: $query)
                    .textFieldStyle(.roundedBorder)
                if records.isEmpty {
                    Text(query.isEmpty ? "No history." : "No matches.").foregroundStyle(.secondary)
                }
                ForEach(records) { r in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.output).lineLimit(2)
                            Text(r.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(copiedID == r.id ? "Copied" : "Copy") {
                            Task { await controller.copyToClipboard(r.output); copiedID = r.id }
                        }
                        .buttonStyle(.borderless)
                    }
                    .contextMenu {
                        Button("Copy to clipboard") {
                            Task { await controller.copyToClipboard(r.output); copiedID = r.id }
                        }
                    }
                }
                if !records.isEmpty {
                    Button("Purge all history", role: .destructive) {
                        Task { await controller.purgeHistory(); await reload() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await reload() }
        .onChange(of: query) { _, _ in copiedID = nil; Task { await reload() } }
    }

    private func reload() async {
        records = await controller.searchHistory(query)
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
