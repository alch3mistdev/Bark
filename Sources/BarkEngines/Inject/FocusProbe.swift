import AppKit
import ApplicationServices
import Carbon.HIToolbox
import BarkCore

/// Reads the currently focused app + field so the injector can verify the
/// target hasn't changed and isn't a secure field.
public enum FocusProbe {
    @MainActor
    public static func currentTarget() -> InjectionTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return InjectionTarget(pid: app.processIdentifier, bundleID: app.bundleIdentifier)
    }

    /// Best-effort screen rect of the text caret in the focused field, in AX
    /// top-left global coordinates. Used only to anchor the (non-activating) HUD;
    /// nil for apps that don't expose it, so the caller falls back to a fixed spot.
    /// Reads bounds only — never the field's contents.
    ///
    /// `nonisolated` so the caller can run it OFF the main actor: the AX IPC is
    /// synchronous and a hung/modal focused app would otherwise stall the main
    /// thread at HUD-show time (Codex/ADV-003). A short messaging timeout bounds
    /// the worst case regardless.
    nonisolated public static func focusedCaretRect() -> CGRect? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID()
        else { return nil }
        let el = element as! AXUIElement

        // Caret = bounds of the (possibly empty) selected range. Widen length to 1
        // so a zero-length insertion point still yields a rect.
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rr = rangeRef, CFGetTypeID(rr) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rr as! AXValue, .cfRange, &range) else { return nil }

        var query = CFRange(location: range.location, length: max(range.length, 1))
        guard let queryValue = AXValueCreate(.cfRange, &query) else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                el, kAXBoundsForRangeParameterizedAttribute as CFString, queryValue, &boundsRef) == .success,
              let br = boundsRef, CFGetTypeID(br) == AXValueGetTypeID()
        else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(br as! AXValue, .cgRect, &rect), rect.height > 0, rect.height < 2000 else { return nil }
        return rect
    }
}

/// Detects secure-input conditions so dictated text is never typed into a
/// password field (SEC-002 / T-005).
public enum SecureFieldDetector {
    /// macOS Secure Event Input is active (a password field is focused anywhere).
    public static func secureInputActive() -> Bool {
        IsSecureEventInputEnabled()
    }

    /// AX role/subrole of the system-wide focused element, if readable.
    @MainActor
    public static func focusedElementRole() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID()
        else { return nil }
        let axElement = element as! AXUIElement

        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(axElement, kAXSubroleAttribute as CFString, &subrole) == .success,
           let s = subrole as? String, !s.isEmpty {
            return s
        }
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &role) == .success,
           let r = role as? String {
            return r
        }
        return nil
    }
}
