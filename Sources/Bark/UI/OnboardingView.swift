import SwiftUI
import BarkCore
import BarkEngines

/// First-run welcome + permission walkthrough. Shown in a window by the app
/// delegate when onboarding hasn't been completed.
struct OnboardingView: View {
    @Bindable var controller: DictationController
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "mic.circle.fill").font(.system(size: 40)).foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("Welcome to Bark").font(.title.bold())
                    Text("Offline AI dictation. Hold your hotkey, speak, get clean text — anywhere.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            Divider()

            Text("Grant three permissions to get started:").font(.headline)
            VStack(spacing: 10) {
                ForEach(PermissionKind.allCases, id: \.self) { kind in
                    PermissionRow(controller: controller, kind: kind)
                }
            }

            Divider()

            Label("Hold **fn (Globe)** to talk; release to insert. Change it anytime in Settings.",
                  systemImage: "keyboard")
                .font(.callout).foregroundStyle(.secondary)

            #if MLXCleanup
            // Optional, never gates onboarding: the flagship rewrite feature is a
            // ~2.5 GB download the user would otherwise only discover in Settings.
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("AI rewrite model (optional)").font(.body.weight(.medium))
                    Text("Qwen3-4B, ~2.5 GB download — runs fully offline. Also available later in Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                switch controller.llmStatus {
                case .notLoaded:
                    Button("Download") { controller.llmEnabled = true }   // opt-in + warm in one step
                case .failed:
                    Button("Retry") { controller.llmEnabled = true }
                default:
                    LLMStatusBadge(status: controller.llmStatus).font(.caption)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            #endif

            HStack {
                Text(controller.permissionsReady ? "You're ready!" : "Microphone is required to dictate.")
                    .font(.callout)
                    .foregroundStyle(controller.permissionsReady ? .green : .secondary)
                Spacer()
                Button("Start using Bark") {
                    controller.completeOnboarding()
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!controller.permissionsReady)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { controller.refreshPermissions() }
    }
}

private struct PermissionRow: View {
    @Bindable var controller: DictationController
    let kind: PermissionKind

    var body: some View {
        let state = controller.permissions.state(of: kind)
        HStack {
            Image(systemName: state == .granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(state == .granted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if state != .granted {
                Button("Grant") { controller.requestPermission(kind) }
                Button("Settings") { controller.permissions.openSettings(for: kind) }
                    .buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var title: String {
        switch kind { case .microphone: "Microphone"; case .accessibility: "Accessibility"; case .inputMonitoring: "Input Monitoring" }
    }
    private var subtitle: String {
        switch kind {
        case .microphone: "Capture your voice (audio stays on-device)."
        case .accessibility: "Insert text into the app you're using."
        case .inputMonitoring: "Detect the global push-to-talk hotkey."
        }
    }
}
