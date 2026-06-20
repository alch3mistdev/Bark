import AppKit
import ApplicationServices
import BarkCore

/// Best-effort `ContextProvider`: reads the focused app's on-screen text via the
/// Accessibility API so Bark can suggest replies grounded in the latest message.
///
/// RESIDUAL (documented, NON-unit-testable): "the latest message" is heuristic —
/// we collect readable text from the focused window's subtree and keep the tail.
/// Apps expose their content differently (native vs. web/Electron views), and
/// some expose nothing, in which case we return nil and the UI shows "no context".
/// We read **bounds-free content** here (unlike `FocusProbe`), so this is gated by
/// the Smart Replies opt-in by the caller (Principle I & IV). Reads are bounded in
/// depth, node count, and total characters, and use a short AX messaging timeout
/// so a hung/modal app can't stall us.
public struct AccessibilityContextReader: ContextProvider {
    private let maxDepth: Int
    private let maxNodes: Int
    private let maxChars: Int

    public init(maxDepth: Int = 24, maxNodes: Int = 1500, maxChars: Int = 4000) {
        self.maxDepth = maxDepth
        self.maxNodes = maxNodes
        self.maxChars = maxChars
    }

    public func currentContext() async -> ConversationContext? {
        // Run the synchronous AX IPC off the main actor; a short messaging timeout
        // bounds the worst case regardless (mirrors FocusProbe.focusedCaretRect).
        let snapshot = readFocusedWindowText()
        guard let snapshot, !snapshot.text.isEmpty else { return nil }
        return ConversationContext(lastMessage: snapshot.text, appBundleID: snapshot.bundleID)
    }

    private struct Snapshot { let text: String; let bundleID: String? }

    private func readFocusedWindowText() -> Snapshot? {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)

        // Prefer the focused element's enclosing window; fall back to the focused
        // window of the frontmost app.
        guard let root = focusedWindow(system) else { return nil }

        var collected: [String] = []
        var budget = maxNodes
        collectText(from: root, depth: 0, into: &collected, budget: &budget)

        let joined = collected.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { return nil }

        // Keep the tail — the most recent content is what the user replies to.
        let tail = joined.count > maxChars ? String(joined.suffix(maxChars)) : joined
        return Snapshot(text: tail, bundleID: bundleID)
    }

    private func focusedWindow(_ system: AXUIElement) -> AXUIElement? {
        // Focused UI element → walk up to its AXWindow.
        if let focused = copyElement(system, kAXFocusedUIElementAttribute),
           let window = enclosingWindow(of: focused) {
            return window
        }
        // Fallback: focused application's focused window.
        if let app = copyElement(system, kAXFocusedApplicationAttribute),
           let window = copyElement(app, kAXFocusedWindowAttribute) {
            return window
        }
        return nil
    }

    private func enclosingWindow(of element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        var hops = 0
        while let el = current, hops < maxDepth {
            if role(of: el) == kAXWindowRole { return el }
            current = copyElement(el, kAXParentAttribute)
            hops += 1
        }
        // No window ancestor found; use the element itself as the subtree root.
        return element
    }

    /// Depth-first gather of value/title/static-text strings, bounded by budget.
    private func collectText(from element: AXUIElement, depth: Int, into out: inout [String], budget: inout Int) {
        guard depth <= maxDepth, budget > 0 else { return }
        budget -= 1

        if let s = stringValue(element), !s.isEmpty {
            out.append(s)
        }

        guard let children = copyElements(element, kAXChildrenAttribute) else { return }
        for child in children {
            if budget <= 0 { break }
            collectText(from: child, depth: depth + 1, into: &out, budget: &budget)
        }
    }

    /// The best human-readable string for a node: AXValue (text fields/areas) or
    /// AXTitle/AXDescription for static text and labels.
    private func stringValue(_ element: AXUIElement) -> String? {
        for attr in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
               let s = ref as? String {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private func role(of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let value = ref, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private func copyElements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let array = ref as? [AnyObject]
        else { return nil }
        return array.compactMap { obj -> AXUIElement? in
            guard CFGetTypeID(obj) == AXUIElementGetTypeID() else { return nil }
            return (obj as! AXUIElement)
        }
    }
}
