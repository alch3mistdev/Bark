import SwiftUI
import AppKit
import BarkCore
import BarkEngines

/// Settings › Discuss (017): master switch, hotkey, mic mode, spoken replies,
/// and the shared-engine note with the strengthened ADR-010 privacy copy
/// (a discussion transcript reveals multi-turn intent, more than a one-shot
/// suggestion capture).
struct DiscussionPane: View {
    @Bindable var controller: DictationController
    @Bindable var discussion: DiscussionController

    var body: some View {
        Form {
            Section("Socratic discussion") {
                Toggle("Enable discussion sessions", isOn: $discussion.enabled)
                LabeledContent("Hotkey") {
                    HotkeyRecorder(setting: $discussion.hotkeySetting)
                }
                .disabled(!discussion.enabled)
                Text("Press the hotkey (default F7) in any text field and Bark opens a short "
                     + "back-and-forth: it asks clarifying questions, you answer by voice, and when "
                     + "the goal is clear it drafts the final text, shows it for review, and inserts "
                     + "it where your cursor was. In-session the same key runs the conversation: it "
                     + "skips speech, and in push-to-talk it opens and closes your turn. The "
                     + "conversation and anything read from the screen stay in memory and are never "
                     + "saved.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Your voice") {
                Picker("Speak your turns with", selection: $discussion.micMode) {
                    ForEach(DiscussionMicMode.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!discussion.enabled)
                Text(discussion.micMode == .ptt
                     ? "Tap the discussion hotkey to start talking, tap again to finish."
                     : "Just speak when it's your turn; a pause ends the turn. Uses the hands-free "
                       + "sensitivity from Settings › Hotkey. Note: the speaker gate does NOT "
                       + "filter discussion turns yet — anyone audible can answer.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Spoken replies") {
                Toggle("Read the AI's questions aloud", isOn: $discussion.ttsEnabled)
                    .disabled(!discussion.enabled)

                Picker("Voice", selection: $discussion.voiceID) {
                    Text(automaticLabel).tag("")
                    ForEach(discussion.voiceOptions) { voice in
                        Text(voiceLabel(voice)).tag(voice.identifier)
                    }
                }
                .disabled(!discussion.enabled || !discussion.ttsEnabled)

                HStack {
                    Text("Rate")
                    Slider(value: $discussion.speechRate, in: 0.3...0.7)
                    Button("Preview") { discussion.previewVoice() }
                }
                .disabled(!discussion.enabled || !discussion.ttsEnabled)

                if discussion.shouldSuggestVoiceDownload {
                    // The stock Mac state: only compact voices installed, which
                    // is what makes Apple's synthesizer sound robotic.
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Only basic voices are installed, which is why speech sounds robotic. "
                              + "Downloading an Enhanced or Premium voice (about 200 MB, one time) "
                              + "is the single biggest quality improvement available.",
                              systemImage: "arrow.down.circle")
                            .font(.caption).foregroundStyle(.orange)
                        Button("Open Spoken Content settings…") { openSpokenContentSettings() }
                            .controlSize(.small)
                    }
                }

                Text("Uses the on-device system voice — nothing leaves your Mac. The microphone is "
                     + "always closed while Bark speaks, so it never hears itself. Tap the hotkey to "
                     + "skip the speech.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Engine") {
                if discussion.localEngineUsable {
                    Text("Uses the engine selected in Settings › Suggest (on-device by default).")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("Requires the LLM rewrite (Settings › Models) or a custom endpoint "
                          + "(Settings › Suggest).",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                // ADR-010 / Principle I, strengthened for multi-turn content.
                Label("Privacy: with a custom endpoint selected in Settings › Suggest, the ENTIRE "
                      + "discussion — everything you say, every AI reply, and the captured screen "
                      + "text — is sent to that endpoint on every turn. That reveals far more than a "
                      + "single suggestion request. On-device stays fully offline.",
                      systemImage: "hand.raised")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
    }

    /// Names the voice auto-selection actually resolved to, so "Automatic"
    /// isn't opaque about what you're hearing.
    private var automaticLabel: String {
        guard let resolved = discussion.resolvedVoice else { return "Automatic" }
        return "Automatic (\(resolved.name) · \(resolved.tier.label))"
    }

    private func voiceLabel(_ voice: VoiceOption) -> String {
        var label = "\(voice.name) · \(voice.tier.label)"
        if voice.isNovelty { label += " · novelty" }
        else if voice.isLegacyFormant { label += " · retro" }
        return label
    }

    private func openSpokenContentSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent") else { return }
        NSWorkspace.shared.open(url)
    }
}
