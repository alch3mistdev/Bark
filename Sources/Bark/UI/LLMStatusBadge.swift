import SwiftUI
import BarkCore

/// Compact LLM model status — shared by Settings › General, the menu popover's
/// model banner, and onboarding, so the story is identical everywhere.
struct LLMStatusBadge: View {
    let status: LLMStatus
    var body: some View {
        switch status {
        case .unavailable:
            Text("Not in this build").foregroundStyle(.secondary)
        case .notLoaded:
            Text("Qwen3-4B — not downloaded").foregroundStyle(.secondary)
        case .downloading(let p):
            HStack(spacing: 8) {
                ProgressView(value: p).frame(width: 90)
                Text("\(Int(p * 100))%").monospacedDigit().foregroundStyle(.secondary)
            }
        case .ready:
            Label("Qwen3-4B ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }
}
