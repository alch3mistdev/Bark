import SwiftUI
import BarkCore

/// The discussion panel content (017): transcript, the AI's current question,
/// state indicators, and the action row (Recapture / Done / Cancel — or the
/// preview's Confirm / Resume / Copy / Cancel).
struct DiscussionOverlayView: View {
    let controller: DiscussionController

    static func size(for session: DiscussionSession) -> CGSize {
        switch session.state {
        case .previewing, .injecting:
            return CGSize(width: 460, height: 400)
        default:
            return CGSize(width: 460, height: 330)
        }
    }

    private var session: DiscussionSession { controller.session }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if session.state == .previewing || session.state == .injecting {
                preview
            } else {
                transcript
            }
            if let error = controller.lastError, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .lineLimit(2)
            }
            actions
        }
        .padding(12)
        .frame(width: Self.size(for: session).width, height: Self.size(for: session).height, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right")
                .foregroundStyle(Color.accentColor)
            Text("Discussion").font(.headline)
            Text(stateLabel).font(.caption).foregroundStyle(.secondary)
            Spacer()
            contextBadge
        }
    }

    /// States what Bark can currently see, and confirms a refresh actually
    /// happened — without it, a successful Recapture changed nothing on screen
    /// and read as a broken button.
    @ViewBuilder
    private var contextBadge: some View {
        if session.state == .idle || session.state == .capturing {
            EmptyView()
        } else if controller.isRecapturing {
            Label("Re-reading…", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption2).foregroundStyle(.secondary)
        } else if !session.hasContext {
            Label("No context", systemImage: "eye.slash")
                .font(.caption2).foregroundStyle(.secondary)
                .help("Bark couldn't read the window — the discussion runs without screen context.")
        } else if session.contextVersion > 0 {
            Label("Re-read ×\(session.contextVersion)", systemImage: "eye")
                .font(.caption2).foregroundStyle(Color.accentColor)
                .help("The window was re-read; the next question uses its current content.")
        } else {
            Label("Reading window", systemImage: "eye")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Shared Done button — inert until the user has actually said something,
    /// since drafting from a transcript containing only the AI's own opening
    /// question invents content.
    private var doneButton: some View {
        Button("Done — draft it (D)") { controller.done() }
            .disabled(!session.canSynthesize)
            .help(session.canSynthesize
                  ? "Write the final text from this conversation."
                  : "Say something first — there's nothing to draft from yet.")
    }

    /// Shared Recapture button — enabled exactly when the controller will act
    /// on it, so it can never look live while being inert.
    @ViewBuilder
    private var recaptureButton: some View {
        Button(controller.isRecapturing ? "Re-reading…" : "Recapture") { controller.recapture() }
            .disabled(!controller.canRecapture || controller.isRecapturing)
            .help("Re-read the target window so the next question sees its current content.")
    }

    private var stateLabel: String {
        switch session.state {
        case .idle: return ""
        case .capturing: return "Reading the window…"
        case .thinking: return "Thinking…"
        case .presenting: return "Speaking…"
        case .awaitingUser:
            return controller.micMode == .ptt ? "Your turn — tap the hotkey to talk" : "Your turn — just speak"
        case .listening: return controller.micMode == .ptt ? "Listening — tap again to finish" : "Listening…"
        case .transcribing: return "Transcribing…"
        case .turnFailed: return "The engine failed"
        case .synthesizing: return "Drafting…"
        case .synthesisFailed: return "Drafting failed"
        case .previewing: return "Review the draft"
        case .injecting: return "Inserting…"
        case .finished, .cancelled: return ""
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(session.transcript.enumerated()), id: \.offset) { index, turn in
                        turnRow(turn, isCurrent: index == session.transcript.count - 1)
                            .id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: session.transcript.count) { _, count in
                if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func turnRow(_ turn: DialogueTurn, isCurrent: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(turn.role == .user ? "You" : "AI")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(turn.role == .user ? Color.secondary : Color.accentColor)
                .frame(width: 26, alignment: .trailing)
            Text(turn.text)
                .font(turn.role == .assistant && isCurrent ? .body.weight(.medium) : .callout)
                .foregroundStyle(turn.role == .assistant && isCurrent ? .primary : .secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Final draft").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                Text(session.synthesizedPrompt ?? "")
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch session.state {
        case .previewing:
            HStack {
                Button("Confirm ⏎") { controller.confirm() }
                    .buttonStyle(.borderedProminent)
                Button("Resume (R)") { controller.resume() }
                Button("Copy (C)") { controller.copyPrompt() }
                Spacer()
                Button("Cancel (Esc)", role: .cancel) { controller.cancel() }
            }
            .controlSize(.small)
        case .turnFailed:
            HStack {
                Button("Retry") { controller.retryTurn() }
                    .buttonStyle(.borderedProminent)
                Button("Done — draft it (D)") { controller.done() }
                recaptureButton
                Spacer()
                Button("Cancel (Esc)", role: .cancel) { controller.cancel() }
            }
            .controlSize(.small)
        case .synthesisFailed:
            HStack {
                Button("Retry draft") { controller.retrySynthesis() }
                    .buttonStyle(.borderedProminent)
                if session.synthesisFailures >= 2 {
                    Button("Copy transcript (C)") { controller.copyTranscript() }
                }
                Spacer()
                Button("Cancel (Esc)", role: .cancel) { controller.cancel() }
            }
            .controlSize(.small)
        case .awaitingUser, .presenting, .listening, .transcribing, .thinking:
            HStack {
                if session.readySignaled {
                    doneButton.buttonStyle(.borderedProminent)
                } else {
                    doneButton.buttonStyle(.bordered)
                }
                recaptureButton
                Spacer()
                Button("Cancel (Esc)", role: .cancel) { controller.cancel() }
            }
            .controlSize(.small)
        default:
            EmptyView()
        }
    }
}
