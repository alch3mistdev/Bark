import SwiftUI
import BarkCore
import BarkEngines

struct HotkeyPane: View {
    @Bindable var controller: DictationController
    // UI selection is local so "Custom" can show the recorder WITHOUT first
    // overwriting the persisted hotkey (the recorder commits the real key).
    @State private var mode: HotkeyPreset = .fn
    @State private var enrollment: SpeakerEnrollmentController?
    @State private var showEnroll = false

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

            // Speaker gate (011). Hidden entirely when the capability isn't compiled
            // into this build, rather than shown as broken (FR-013).
            if controller.speakerGateAvailable {
                Section("Speaker gate") {
                    Toggle("Only type my voice (hands-free)", isOn: $controller.speakerGateEnabled)
                    Picker("Strictness", selection: $controller.speakerSensitivity) {
                        ForEach(SpeakerVerificationSensitivity.allCases) { Text($0.label).tag($0) }
                    }
                    .disabled(!controller.speakerGateEnabled)

                    LabeledContent("Voiceprint") {
                        if controller.speakerEnrolled {
                            Label("Enrolled", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        } else {
                            Text("Not set up").foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Button(controller.speakerEnrolled ? "Re-enroll…" : "Enroll voice…") {
                            enrollment = controller.makeEnrollmentController()
                            showEnroll = (enrollment != nil)
                        }
                        if controller.speakerEnrolled {
                            Button("Delete voiceprint", role: .destructive) {
                                Task { await controller.deleteVoiceprint() }
                            }
                        }
                    }
                    Text("In hands-free mode, Bark types only utterances that match your enrolled voice "
                         + "and silently ignores other speakers. It’s a convenience filter, not security: "
                         + "it does NOT stop a recording, imitation, or clone of your own voice, and is not "
                         + "authentication or liveness. If matching can’t run, your own dictation is always "
                         + "typed. The voiceprint is encrypted on-device and never leaves your Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { mode = HotkeyPreset.from(controller.hotkeySetting) }
        .sheet(isPresented: $showEnroll) {
            if let enrollment {
                SpeakerEnrollmentSheet(enrollment: enrollment) {
                    showEnroll = false
                    Task { await controller.loadSpeakerProfile() }
                }
            }
        }
    }
}

/// Guided voice-enrollment sheet. Drives a `SpeakerEnrollmentController`: the user
/// reads each prompted phrase, the sheet reflects capture progress and re-record
/// requests, and saves the voiceprint when enough good takes are collected.
struct SpeakerEnrollmentSheet: View {
    @Bindable var enrollment: SpeakerEnrollmentController
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Enroll your voice").font(.headline)
            ProgressView(value: Double(enrollment.capturedCount),
                         total: Double(max(enrollment.requiredCount, 1)))
                .frame(maxWidth: .infinity)
            status
            HStack {
                Button("Cancel") { enrollment.cancel(); onClose() }
                Spacer()
                switch enrollment.phase {
                case .done:
                    Button("Done") { onClose() }.keyboardShortcut(.defaultAction)
                case .failed:
                    Button("Retry") { enrollment.start() }
                default:
                    EmptyView()
                }
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { enrollment.start() }
    }

    @ViewBuilder private var status: some View {
        switch enrollment.phase {
        case .idle, .listening:
            VStack(spacing: 6) {
                Text("Read this phrase aloud (\(enrollment.capturedCount + 1) of \(enrollment.requiredCount)):")
                    .font(.caption).foregroundStyle(.secondary)
                Text("“\(enrollment.currentPrompt)”")
                    .font(.title3).multilineTextAlignment(.center)
            }
        case .evaluating, .saving:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Working…").foregroundStyle(.secondary) }
        case .redo(let reason, _):
            VStack(spacing: 6) {
                Label(reason, systemImage: "arrow.counterclockwise")
                    .foregroundStyle(.orange).font(.caption)
                Text("“\(enrollment.currentPrompt)”")
                    .font(.title3).multilineTextAlignment(.center)
            }
        case .done:
            Label("Voiceprint saved", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
        }
    }
}
