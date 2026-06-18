import AppKit
import CoreGraphics
import BarkCore

/// Shared safety preflight for any injector. Runs on the main actor.
enum InjectionPreflight {
    /// Verifies focus is unchanged and the field is safe, or throws.
    @MainActor
    static func check(_ plan: InjectionPlan) throws {
        let current = FocusProbe.currentTarget()
        guard FocusGuard.targetUnchanged(captured: plan.target, current: current) else {
            BarkLog.inject.error("focus changed before injection — aborting")
            throw InjectionError.focusChanged
        }
        let decision = SecureFieldPolicy.decide(
            secureInputEnabled: SecureFieldDetector.secureInputActive(),
            focusedElementRole: SecureFieldDetector.focusedElementRole()
        )
        if case .refuse(let reason) = decision {
            BarkLog.inject.error("refusing injection: \(reason, privacy: .public)")
            throw InjectionError.secureFieldBlocked
        }
    }
}

/// Default injector: snapshot clipboard → set text → synthesize ⌘V → restore.
///
/// Restores ALL pasteboard item types (not just string — that would be data
/// loss) and only restores if the user didn't copy something in between
/// (`changeCount` guard). Marks the injected payload concealed so clipboard
/// managers don't retain the transcript (ARCH-001 / SEC-007 / T-007).
public final class PasteboardInjector: TextInjector {
    private let restoreDelay: Duration

    public init(restoreDelay: Duration = .milliseconds(250)) {
        self.restoreDelay = restoreDelay
    }

    public func inject(_ text: String, plan: InjectionPlan) async throws {
        guard !text.isEmpty else { throw InjectionError.emptyText }
        try await MainActor.run {
            try InjectionPreflight.check(plan)
            try Self.paste(text, restoreDelay: restoreDelay)
        }
    }

    @MainActor
    private static func paste(_ text: String, restoreDelay: Duration) throws {
        let pb = NSPasteboard.general

        // Deep snapshot of every current item / type.
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
        let baseline = pb.changeCount

        pb.clearContents()
        pb.setString(text, forType: .string)
        // Hint to clipboard managers: do not persist this (transcript privacy).
        pb.setData(Data([1]), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let afterWrite = pb.changeCount

        try synthesizePaste()

        // Restore later, but only if our write is still the latest (user didn't copy).
        Task { @MainActor in
            try? await Task.sleep(for: restoreDelay)
            guard pb.changeCount == afterWrite else {
                BarkLog.inject.info("clipboard changed by user — leaving it, not restoring")
                return
            }
            pb.clearContents()
            if !saved.isEmpty {
                pb.writeObjects(saved)
            }
            _ = baseline
        }
    }

    /// Posts ⌘V. Never posts Return/Enter (T-006 / SEC-005).
    @MainActor
    static func synthesizePaste() throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw InjectionError.pasteFailed
        }
        let vKey: CGKeyCode = 0x09 // 'v'
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else {
            throw InjectionError.pasteFailed
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }
}
