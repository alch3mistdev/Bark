import SwiftUI
import AppKit
import BarkCore

struct ModesPane: View {
    @Bindable var controller: DictationController
    @State private var editingBuiltIn: Mode?
    @State private var editingCustom: Mode?

    var body: some View {
        Form {
            Section("Built-in") {
                ForEach(Mode.builtInModes) { shipped in
                    Button { editingBuiltIn = shipped } label: {
                        HStack {
                            Label(shipped.name, systemImage: shipped.symbol)
                            Spacer()
                            if controller.isBuiltInModified(id: shipped.id) { tag("Modified") }
                            if shipped.usesLLM { tag("LLM") }
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Section("Custom") {
                let customs = controller.modes.filter { m in !Mode.builtInModes.contains { $0.id == m.id } }
                if customs.isEmpty {
                    Text("No custom modes yet.").foregroundStyle(.secondary)
                }
                ForEach(customs) { mode in
                    HStack {
                        Button { editingCustom = mode } label: {
                            HStack {
                                Label(mode.name, systemImage: mode.symbol)
                                Spacer()
                                if mode.usesLLM { tag("LLM") }
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button(role: .destructive) { controller.removeMode(id: mode.id) } label: {
                            Image(systemName: "trash")
                        }.buttonStyle(.borderless)
                    }
                }
                Button("Add custom mode…") {
                    editingCustom = Mode(id: "custom-\(UUID().uuidString.prefix(8))", name: "New Mode",
                                         symbol: "wand.and.stars", usesLLM: true,
                                         systemPrompt: "Rewrite the dictated text. Keep the meaning; do not add content.")
                }
            }
            // Per-app auto-selection lives with the modes it selects (was its own pane).
            AppModeSections(controller: controller)
        }
        .formStyle(.grouped)
        .sheet(item: $editingBuiltIn) { shipped in
            BuiltInPromptEditor(controller: controller, shipped: shipped) { editingBuiltIn = nil }
        }
        .sheet(item: $editingCustom) { mode in
            CustomModeEditor(controller: controller, initial: mode) { editingCustom = nil }
        }
    }

    private func tag(_ s: String) -> some View {
        Text(s).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

/// The per-app mode mapping sections, folded into the Modes pane (014): the
/// mapping picks between the modes listed right above it.
struct AppModeSections: View {
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
}
