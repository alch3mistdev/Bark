import AppKit
import BarkCore

/// Places text on the clipboard without typing anything into the focused app.
/// Used when the user selects "copy to clipboard" output routing (for apps where
/// synthetic paste/keystrokes are unreliable). Nothing is injected into a field,
/// so it skips the focus/secure-field preflight and never restores the clipboard
/// (leaving the result there is the whole point). Marks the payload concealed.
public final class ClipboardInjector: TextInjector {
    public init() {}

    public func inject(_ text: String, plan: InjectionPlan) async throws {
        guard !text.isEmpty else { throw InjectionError.emptyText }
        await MainActor.run {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            pb.setData(Data([1]), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        }
    }
}
