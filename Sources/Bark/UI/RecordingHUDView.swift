import SwiftUI
import BarkCore

/// Floating status overlay shown while dictating. Observes the controller's
/// phase + live partial transcript. Rendered inside a non-activating panel, so
/// it never takes focus from the app you're dictating into.
///
/// Two layouts: the default **compact** strip, and an opt-in **enhanced** card
/// (Settings → enhanced overlay) with larger live text and a live mic-level
/// meter. The panel size is driven by `RecordingHUDView.size(enhanced:)`.
struct RecordingHUDView: View {
    @Bindable var controller: DictationController

    static func size(enhanced: Bool) -> CGSize {
        enhanced ? CGSize(width: 440, height: 132) : CGSize(width: 320, height: 64)
    }

    var body: some View {
        if controller.enhancedHUD {
            enhanced
        } else {
            compact
        }
    }

    private var title: String {
        controller.handsFreeActive && !controller.phase.isActive
            ? "Hands-free — listening…" : controller.phase.title
    }

    private var accent: Color {
        if controller.phase.isError { return .orange }
        if case .completed = controller.phase { return .green }
        return .accentColor
    }

    // 012: surface the hold-to-refine state + the evolving draft. The one-time
    // refine hint ("needs the LLM…") takes over the line while set — otherwise
    // the gesture fails silently.
    private var statusLine: String {
        if let hint = controller.refineHint { return hint }
        switch controller.refineActivity {
        case .capturingInstruction: return "Listening for instruction…"
        case .refining: return "Refining…"
        case .dictating, .none:
            // Honest completion: say when the LLM fell back to basic cleanup.
            if case .completed = controller.phase, let note = fallbackNote {
                return "Inserted — \(note)"
            }
            return title
        }
    }

    private var fallbackNote: String? {
        switch controller.lastCleanupOutcome {
        case .fallbackNotReady: return "basic cleanup (model not ready)"
        case .fallbackFailed: return "basic cleanup (rewrite failed)"
        default: return nil
        }
    }

    private var statusColor: Color { controller.refineHint != nil ? .orange : .primary }

    private var isCleaning: Bool { if case .cleaning = controller.phase { return true } else { return false } }

    /// Show the evolving refined draft once a refine session is under way; the
    /// live partial otherwise.
    private var bodyText: String {
        controller.refineActivity != .none && !controller.currentDraft.isEmpty
            ? controller.currentDraft : controller.liveText
    }

    // MARK: Compact (default)

    private var compact: some View {
        HStack(spacing: 10) {
            Image(systemName: controller.phase.menuSymbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(statusLine).font(.caption.weight(.semibold)).foregroundStyle(statusColor)
                    if isCleaning { ProgressView().controlSize(.mini) }
                }
                if !bodyText.isEmpty {
                    Text(bodyText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 320, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Dictation status")
    }

    // MARK: Enhanced (opt-in)

    private var enhanced: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: controller.phase.menuSymbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accent)
                Text(statusLine).font(.subheadline.weight(.semibold)).foregroundStyle(statusColor)
                if isCleaning { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                LevelBar(level: controller.inputLevel, active: controller.phase.isActive)
                    .frame(width: 96, height: 14)
            }
            Text(bodyText.isEmpty ? "Listening…" : bodyText)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(bodyText.isEmpty ? .secondary : .primary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeOut(duration: 0.12), value: bodyText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 440, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.10)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Dictation status")
    }
}

/// Segmented audio-level meter (green → yellow → red), lit proportionally to
/// `level` (0...1). Dims when not actively capturing.
struct LevelBar: View {
    var level: Float
    var active: Bool
    private let segments = 12

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 2
            let w = (geo.size.width - gap * CGFloat(segments - 1)) / CGFloat(segments)
            HStack(spacing: gap) {
                ForEach(0..<segments, id: \.self) { i in
                    let threshold = Float(i + 1) / Float(segments)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(color(for: i, lit: active && level >= threshold))
                        .frame(width: max(w, 1))
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Microphone level")
        .accessibilityValue(active ? "\(Int(level * 100))%" : "inactive")
    }

    private func color(for index: Int, lit: Bool) -> Color {
        guard lit else { return .secondary.opacity(0.18) }
        let frac = Double(index) / Double(segments - 1)
        if frac > 0.85 { return .red }
        if frac > 0.6 { return .yellow }
        return .green
    }
}

extension DictationPhase {
    var isError: Bool { if case .failed = self { return true } else { return false } }
}
