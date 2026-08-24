import SwiftUI
import BarkCore

/// Content of the suggestion picker panel (015 FR-009): numbered candidate
/// rows + "Other…" row, with loading and honest error states. Keyboard events
/// are handled by `SuggestionPanel` (via `SuggestionKeyDecoder`); this view
/// adds mouse selection and hover highlight.
struct SuggestionOverlayView: View {
    @Bindable var controller: SuggestionController

    static let width: CGFloat = 460
    static let rowHeight: CGFloat = 34
    static let chromeHeight: CGFloat = 20

    static let footerHeight: CGFloat = 22

    static func size(for session: SuggestionSession) -> CGSize {
        switch session.phase {
        case .presenting, .generating:
            // 016: rows fill progressively — .generating shows the Other… row
            // alone; a footer advertises that more candidates are coming.
            let rows = CGFloat(session.candidates.count + 1)   // + Other…
            let footer = session.isStreaming ? footerHeight : 0
            return CGSize(width: width, height: rows * rowHeight + chromeHeight + footer)
        case .failed:
            return CGSize(width: width, height: 72)
        default:
            return CGSize(width: 300, height: 52)
        }
    }

    var body: some View {
        Group {
            switch controller.session.phase {
            case .capturing:
                statusRow("eye", "Reading screen…")
            case .generating, .presenting:
                candidateList
            case .failed(let message):
                errorRow(message)
            default:
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggested responses")
    }

    private var candidateList: some View {
        VStack(spacing: 2) {
            ForEach(Array(controller.session.candidates.enumerated()), id: \.offset) { index, text in
                row(badge: "\(index + 1)", text: text,
                    highlighted: controller.session.highlightedIndex == index,
                    accessibilityHint: "Press \(index + 1) or Return to insert") {
                    controller.choose(index)
                }
            }
            row(badge: "O", text: "Other… (dictate your own)",
                highlighted: controller.session.highlightedIndex == controller.session.otherRowIndex,
                accessibilityHint: "Press O to dictate a custom reply") {
                controller.chooseOther()
            }
            if controller.session.isStreaming {
                generatingFooter
            }
        }
        .padding(8)
    }

    /// 016 FR-004: subtle "still generating" affordance under the rows.
    private var generatingFooter: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(controller.session.candidates.isEmpty ? "Thinking…" : "More coming…")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: Self.footerHeight - 4)
        .accessibilityLabel("Still generating suggestions")
    }

    private func row(badge: String, text: String, highlighted: Bool,
                     accessibilityHint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(badge)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .frame(width: 18, height: 18)
                    .background(Color.secondary.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                Text(text)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: Self.rowHeight - 4)
            .background(highlighted ? Color.accentColor.opacity(0.22) : .clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text)
        .accessibilityHint(accessibilityHint)
    }

    private func statusRow(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Label(text, systemImage: symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .labelStyle(.titleOnly)
        }
        .padding(12)
        .accessibilityLabel(text)
    }

    private func errorRow(_ message: String) -> some View {
        VStack(spacing: 4) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text("Press Esc to dismiss")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .accessibilityLabel("Suggestions failed: \(message)")
    }
}
