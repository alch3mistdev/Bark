import SwiftUI
import BarkCore

/// Floating status overlay shown while dictating. Observes the controller's
/// phase + live partial transcript. Rendered inside a non-activating panel, so
/// it never takes focus from the app you're dictating into.
struct RecordingHUDView: View {
    @Bindable var controller: DictationController

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: controller.phase.menuSymbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(controller.phase.isError ? Color.orange : Color.accentColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(controller.handsFreeActive && !controller.phase.isActive
                     ? "Hands-free — listening…" : controller.phase.title)
                    .font(.caption.weight(.semibold))
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
}

extension DictationPhase {
    var isError: Bool { if case .failed = self { return true } else { return false } }
}
