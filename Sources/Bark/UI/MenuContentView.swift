import SwiftUI
import BarkCore
import BarkEngines

struct MenuContentView: View {
    @Bindable var controller: DictationController

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
            } else if !controller.phase.isActive, let last = controller.lastResult {
                VStack(alignment: .leading, spacing: 6) {
                    Text(last)
                        .font(.callout)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(last, forType: .string)
                    } label: {
                        Label("Copy last", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }

            if let error = controller.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if controller.smartRepliesEnabled && !controller.phase.isActive {
                SmartRepliesSection(controller: controller)
            }

            controlButton

            Button {
                controller.toggleHandsFree()
            } label: {
                Label(controller.handsFreeActive ? "Hands-free: On" : "Hands-free",
                      systemImage: controller.handsFreeActive ? "waveform.circle.fill" : "waveform.circle")
                    .frame(maxWidth: .infinity)
            }
            .tint(controller.handsFreeActive ? Color.accentColor : nil)
            .disabled(!controller.isModelReady || !controller.permissionsReady)

            if controller.historyEnabled {
                RecentMenu(controller: controller)
            }

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
        Picker("Mode", selection: $controller.selectedModeID) {
            ForEach(controller.modes) { mode in
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
            .disabled(!controller.isModelReady || !controller.permissionsReady || controller.handsFreeActive)
        }
    }

    private var footer: some View {
        HStack {
            Text("Hold fn to talk")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Settings…") { controller.requestOpenSettings() }
                .buttonStyle(.link)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.link)
        }
    }
}

/// Re-insert a recent dictation into the frontmost app. Offered only from the
/// menubar (the user's target app is still frontmost here, unlike the Settings
/// window). Types via the normal injectors, honouring focus/secure-field guards. (007)
struct RecentMenu: View {
    @Bindable var controller: DictationController
    @State private var recents: [HistoryRecord] = []

    var body: some View {
        Menu {
            if recents.isEmpty {
                Text("No history yet")
            } else {
                ForEach(recents) { r in
                    Button(label(r)) { Task { await controller.reinsert(r) } }
                }
            }
        } label: {
            Label("Re-insert recent", systemImage: "clock.arrow.circlepath")
                .frame(maxWidth: .infinity)
        }
        .menuStyle(.borderlessButton)
        .disabled(controller.phase.isActive || controller.isReinserting || !controller.permissionsReady)
        .task {
            // Capture the app the user is in BEFORE they open the menu, so re-insert
            // targets it and not Bark's popover (Codex/ADV-004).
            controller.snapshotReinsertTarget()
            recents = Array((await controller.searchHistory("")).prefix(8))  // recent, newest-first
        }
    }

    private func label(_ r: HistoryRecord) -> String {
        let oneLine = r.output.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count > 48 ? String(oneLine.prefix(48)) + "…" : oneLine
    }
}

/// Context-aware reply options for mid-session prompts (009). On appear it reads
/// the focused app's latest message and shows instant quick replies; "AI
/// suggestions" asks the on-device model for the most likely replies. Picking one
/// types it into the app you were in — it never presses Return. None fit? Dictate
/// a custom reply with the normal hotkey.
struct SmartRepliesSection: View {
    @Bindable var controller: DictationController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Smart Replies", systemImage: "bubble.left.and.bubble.right")
                    .font(.subheadline.bold())
                Spacer()
                if controller.branchSuggesting { ProgressView().controlSize(.small) }
            }

            if controller.branchOptions.isEmpty {
                Text(controller.branchNotice ?? "Reading the focused app…")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(controller.branchOptions) { option in
                    Button {
                        Task { await controller.chooseBranch(option) }
                    } label: {
                        Text(option.label)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .disabled(controller.isReinserting)
                }
                if let notice = controller.branchNotice {
                    Text(notice).font(.caption2).foregroundStyle(.secondary)
                }
            }

            HStack {
                if controller.branchSuggesterPresent {
                    Button {
                        Task { await controller.requestLLMSuggestions() }
                    } label: {
                        Label("AI suggestions", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(!controller.canSuggestWithLLM || controller.branchSuggesting
                              || !controller.hasBranchContext)
                }
                Spacer()
                Text("Hold fn for a custom reply")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .task {
            // Snapshot the user's app + read context BEFORE they interact with the
            // popover, so a pick targets that app and not Bark (Codex/ADV-004).
            await controller.prepareBranchContext()
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
