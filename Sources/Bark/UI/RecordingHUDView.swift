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

    private var accent: Color { controller.phase.isError ? .orange : .accentColor }

    // MARK: Compact (default)

    private var compact: some View {
        HStack(spacing: 10) {
            Image(systemName: controller.phase.menuSymbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold))
                if !controller.liveText.isEmpty {
                    Text(controller.liveText)
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
    }

    // MARK: Enhanced (opt-in)

    private var enhanced: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: controller.phase.menuSymbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accent)
                Text(title).font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                LevelBar(level: controller.inputLevel, active: controller.phase.isActive)
                    .frame(width: 96, height: 14)
            }
            Text(controller.liveText.isEmpty ? "Listening…" : controller.liveText)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(controller.liveText.isEmpty ? .secondary : .primary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeOut(duration: 0.12), value: controller.liveText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 440, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.10)))
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
