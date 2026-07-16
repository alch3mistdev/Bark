import SwiftUI
import BarkCore
import BarkEngines

/// Settings › Suggest (015): master switch, hotkey, engine backend (with the
/// ADR-010 privacy warning for the external endpoint), and the opt-in
/// auto-submit exception with its warning copy.
struct SuggestionsPane: View {
    @Bindable var controller: DictationController
    @Bindable var suggestions: SuggestionController
    @State private var apiKey: String = ""

    var body: some View {
        Form {
            Section("Suggested responses") {
                Toggle("Enable suggested responses", isOn: $suggestions.enabled)
                LabeledContent("Hotkey") {
                    HotkeyRecorder(setting: $suggestions.hotkeySetting)
                }
                .disabled(!suggestions.enabled)
                Text("Press the hotkey (default ⌃⌥S) and Bark reads the frontmost window, proposes a few "
                     + "replies, and inserts the one you pick — or choose “Other…” and dictate your own. "
                     + "What Bark reads stays in memory and is never saved.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Engine") {
                Picker("Generate with", selection: $suggestions.backend) {
                    ForEach(SuggestionBackendID.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!suggestions.enabled)

                switch suggestions.backend {
                case .local:
                    if suggestions.localEngineUsable {
                        Text("Uses the on-device rewrite model. Nothing leaves your Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label("Requires the LLM rewrite — turn it on in Settings › Models.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                case .external:
                    TextField("Endpoint URL", text: $suggestions.externalEndpoint,
                              prompt: Text("http://localhost:11434/v1"))
                        .textFieldStyle(.roundedBorder)
                    TextField("Model", text: $suggestions.externalModel,
                              prompt: Text("e.g. qwen3:8b"))
                        .textFieldStyle(.roundedBorder)
                    SecureField("API key (optional — Ollama needs none)", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: apiKey) { _, newValue in
                            suggestions.externalAPIKey = newValue
                        }
                    // ADR-010 / Principle I: name exactly what is transmitted.
                    Label("Privacy: when this backend is selected, the captured screen text, the focused "
                          + "field's label and value, and any matched history snippets are SENT to this "
                          + "endpoint for each suggestion request. The key is stored in your Keychain. "
                          + "If the endpoint fails, Bark falls back to the on-device model.",
                          systemImage: "hand.raised")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Section("After inserting") {
                Toggle("Auto-submit (press Return for me)", isOn: $suggestions.autoSubmit)
                    .disabled(!suggestions.enabled)
                // ADR-010 / Principle IV exception: spell out the behavior.
                Text("When on, Bark presses Return once after inserting a suggestion you explicitly "
                     + "picked — including in terminals, where that runs the reply. It never fires for "
                     + "dictated (“Other…”) replies, clipboard-only routing, or secure fields, and it "
                     + "re-checks focus first. Off by default.")
                    .font(.caption).foregroundStyle(suggestions.autoSubmit ? .orange : .secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { apiKey = suggestions.externalAPIKey }
    }
}
