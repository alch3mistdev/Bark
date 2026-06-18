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
