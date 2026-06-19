import AppKit
import BarkCore

/// Places text on the clipboard without typing anything into the focused app.
/// Used when the user selects "copy to clipboard" output routing (for apps where
/// synthetic paste/keystrokes are unreliable). Nothing is typed, so the focus
/// guard is N/A and the clipboard is intentionally left set (the user pastes it
/// with ⌘V). The payload is marked concealed so clipboard managers can skip it.
///
/// It still honours the secure-field promise (ADV-001): if a password/secure
/// field is active, we refuse — leaving a transcript on the system clipboard
/// while a credential field is focused would defeat that invariant.
public final class ClipboardInjector: TextInjector {
    public init() {}

    public func inject(_ text: String, plan: InjectionPlan) async throws {
        guard !text.isEmpty else { throw InjectionError.emptyText }
        try await MainActor.run {
            let decision = SecureFieldPolicy.decide(
                secureInputEnabled: SecureFieldDetector.secureInputActive(),
                focusedElementRole: SecureFieldDetector.focusedElementRole()
            )
            if case .refuse(let reason) = decision {
                BarkLog.inject.error("refusing clipboard copy: \(reason, privacy: .public)")
                throw InjectionError.secureFieldBlocked
            }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            pb.setData(Data([1]), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        }
    }
}
