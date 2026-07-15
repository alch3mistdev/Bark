import SwiftUI
import BarkCore
import BarkEngines

let supportedLocales: [(String, String)] = [
    ("en-US", "English (US)"), ("en-GB", "English (UK)"), ("es-ES", "Spanish"),
    ("fr-FR", "French"), ("de-DE", "German"), ("it-IT", "Italian"),
    ("pt-BR", "Portuguese (BR)"), ("ja-JP", "Japanese"), ("zh-CN", "Chinese"), ("ko-KR", "Korean"),
]

struct GeneralPane: View {
    @Bindable var controller: DictationController

    var body: some View {
        Form {
            Section("Speech") {
                Picker("Language", selection: $controller.localeID) {
                    ForEach(supportedLocales, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("Engine", selection: $controller.sttBackend) {
                    ForEach(STTBackendID.allCases.filter { $0.isCompiledIn }) { id in
                        Text(id.displayName).tag(id)
                    }
                }
                .disabled(controller.phase.isActive)
                LabeledContent("Status", value: controller.isModelReady ? "Ready" : "Preparing…")
                if controller.sttBackend != .apple {
                    Text(controller.sttBackend.blurb)
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Models are downloaded over HTTPS and SHA-256 verified against a bundled "
                         + "manifest before they're allowed into the cache (SEC-003).")
                        .font(.caption).foregroundStyle(.secondary)
                }
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

                Toggle("Enable hold-to-refine (left-option)", isOn: $controller.holdToRefineEnabled)
                    .disabled(!controller.llmEnginePresent)
                if controller.llmEnginePresent {
                    Text("While holding fn to dictate, hold the left-option key and speak an instruction "
                         + "(e.g. \u{201C}make it more formal\u{201D}) to rewrite the text before it's "
                         + "inserted. Repeat to refine further; an empty tap undoes the last change. "
                         + "Needs the LLM rewrite turned on.")
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
                Toggle("Enhanced recording overlay", isOn: $controller.enhancedHUD)
                Text("Larger live text with a mic-level meter, anchored near the text cursor when the "
                     + "app supports it. Off uses the compact strip at the bottom of the screen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
