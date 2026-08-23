import AppKit
import ApplicationServices
import BarkCore

/// Reads on-screen context from the accessibility tree (015 FR-002) — the
/// first content-reading AX path in Bark (FocusProbe deliberately reads bounds
/// only). Callers gate on the secure-field checks BEFORE invoking this
/// (`ContextCaptureService`), and the walk itself skips secure elements.
///
/// `nonisolated` like `FocusProbe.focusedCaretRect`: the AX IPC is synchronous,
/// so run this OFF the main actor with a short messaging timeout bounding a
/// hung/modal target app.
public enum AXContextReader {
    public static let maxDepth = 8
    public static let maxElements = 200
    static let axTimeout: Float = 0.25

    /// Roles whose values are visible text worth collecting.
    static let textRoles: Set<String> = ["AXStaticText", "AXTextArea", "AXTextField"]

    nonisolated public static func read(target: InjectionTarget) -> CapturedContext? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, axTimeout)

        // Focused element: value, label, placeholder, role (FR-002).
        var fieldLabel: String?
        var fieldValue: String?
        var fieldPlaceholder: String?
        var fieldRole: String?
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
           let ref = focusedRef, CFGetTypeID(ref) == AXUIElementGetTypeID() {
            let focused = ref as! AXUIElement
            fieldRole = string(of: focused, kAXRoleAttribute)
            // Never read a secure field's content, even if the caller's check raced.
            if fieldRole != "AXSecureTextField", string(of: focused, kAXSubroleAttribute) != "AXSecureTextField" {
                fieldValue = clipped(string(of: focused, kAXValueAttribute), isTerminal: target.isTerminal)
                fieldPlaceholder = string(of: focused, "AXPlaceholderValue")
                fieldLabel = string(of: focused, kAXTitleAttribute)
                    ?? string(of: focused, kAXDescriptionAttribute)
                    ?? titleElementText(of: focused)
            }
        }

        // Focused window of the target app: title + visible text walk.
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, axTimeout)
        var windowTitle: String?
        var collected: [String] = []
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
           let ref = windowRef, CFGetTypeID(ref) == AXUIElementGetTypeID() {
            let window = ref as! AXUIElement
            windowTitle = string(of: window, kAXTitleAttribute)
            var visited = 0
            collect(window, target: target, depth: 0, visited: &visited, into: &collected)
        }

        let strategy = ContextBudget.strategy(isTerminal: target.isTerminal)
        let windowText = ContextBudget.clip(collected.joined(separator: "\n"), strategy: strategy)

        return CapturedContext(
            source: .accessibility,
            appBundleID: target.bundleID,
            windowTitle: windowTitle,
            fieldLabel: fieldLabel,
            fieldValue: fieldValue,
            fieldPlaceholder: fieldPlaceholder,
            fieldRole: fieldRole,
            windowText: windowText
        )
    }

    /// DFS, bounded by depth and element count so a huge tree can't stall the
    /// capture stage (SC-001: capture ≤ 1 s).
    private static func collect(
        _ element: AXUIElement,
        target: InjectionTarget,
        depth: Int,
        visited: inout Int,
        into out: inout [String]
    ) {
        guard depth <= maxDepth, visited < maxElements else { return }
        visited += 1

        let role = string(of: element, kAXRoleAttribute)
        let subrole = string(of: element, kAXSubroleAttribute)
        // Never collect secure-field content.
        guard role != "AXSecureTextField", subrole != "AXSecureTextField" else { return }

        if let role, textRoles.contains(role),
           let value = clipped(string(of: element, kAXValueAttribute), isTerminal: target.isTerminal),
           !value.isEmpty {
            out.append(value)
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let anyChildren = childrenRef as? [AnyObject] else { return }
        for child in anyChildren {
            guard visited < maxElements else { return }
            guard CFGetTypeID(child) == AXUIElementGetTypeID() else { continue }
            collect(child as! AXUIElement, target: target, depth: depth + 1, visited: &visited, into: &out)
        }
    }

    /// Label via the focused element's `AXTitleUIElement` (how AppKit exposes a
    /// `NSTextField` label bound to an input).
    private static func titleElementText(of element: AXUIElement) -> String? {
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXTitleUIElement" as CFString, &titleRef) == .success,
              let ref = titleRef, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        let titleElement = ref as! AXUIElement
        return string(of: titleElement, kAXValueAttribute) ?? string(of: titleElement, kAXTitleAttribute)
    }

    private static func string(of element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let value = ref as? String, !value.isEmpty else { return nil }
        return value
    }

    /// Pre-clip a single huge value (terminal scrollback is one giant AXValue)
    /// so string assembly stays cheap; the final budget clip still applies.
    private static func clipped(_ value: String?, isTerminal: Bool) -> String? {
        guard let value else { return nil }
        return ContextBudget.clip(value, strategy: ContextBudget.strategy(isTerminal: isTerminal))
    }
}
