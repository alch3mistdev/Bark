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
///
/// The text policy lives in `WindowTextCollector` (pure, unit-tested); this
/// type is only the `AXUIElement` plumbing that feeds it.
public enum AXContextReader {
    /// Deeper than the original 8: web and Electron trees nest heavily, and
    /// the interesting text sits well below the old ceiling.
    public static let maxDepth = 40
    public static let maxElements = 2_000
    /// 0.5 s, matching the sibling scrim project: the 0.25 s default was tight
    /// for a Chromium tree that has just been asked to materialize itself.
    static let axTimeout: Float = 0.5

    /// Apps already asked to expose their web content, so the ~400 ms build
    /// cost is paid once per process rather than per capture.
    private static let enabledLock = NSLock()
    nonisolated(unsafe) private static var webContentEnabled: Set<pid_t> = []

    /// Ask a Chromium/Electron app to build its accessibility tree.
    ///
    /// Chromium-derived apps (Chrome, Brave, VS Code, Cursor, Slack, Electron
    /// generally) withhold their render tree until a client sets
    /// `AXManualAccessibility`; some versions gate on `AXEnhancedUserInterface`
    /// instead. Neither constant is in the SDK, hence the raw strings.
    ///
    /// Returns true when this call was the one that opted the app in — the
    /// caller must then let the app build the tree before reading, because the
    /// very next read still sees the old empty one.
    nonisolated public static func prepare(target: InjectionTarget) -> Bool {
        enabledLock.lock()
        let alreadyEnabled = webContentEnabled.contains(target.pid)
        if !alreadyEnabled { webContentEnabled.insert(target.pid) }
        enabledLock.unlock()
        guard !alreadyEnabled else { return false }

        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, axTimeout)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        return true
    }

    /// Forget the opt-in cache (test seam; also correct if a pid is recycled).
    nonisolated public static func resetWebContentCache() {
        enabledLock.lock()
        webContentEnabled.removeAll()
        enabledLock.unlock()
    }

    nonisolated public static func read(target: InjectionTarget) -> CapturedContext? {
        // Focused element scoped to the TARGET APP, not system-wide (017
        // recapture fix). System-wide focus is whatever holds key right now —
        // and during a discussion session that is Bark's own overlay panel, so
        // a mid-session recapture used to read field metadata off Bark's UI
        // instead of the app being discussed. Asking the target app for its
        // own focused element is correct whoever holds focus, which also makes
        // the 015 path (captured before the panel takes key) read identically.
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, axTimeout)

        // Focused element: value, label, placeholder, role (FR-002).
        var fieldLabel: String?
        var fieldValue: String?
        var fieldPlaceholder: String?
        var fieldRole: String?
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
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

        // Window to read: the app's focused window, else its first real window
        // (some apps — and any app that isn't frontmost — report no focused
        // window at all, which previously yielded an empty capture).
        var windowTitle: String?
        var windowText = ""
        var hasContentRoleText = false
        if let window = focusedWindow(of: app) ?? mainWindow(of: app) ?? firstStandardWindow(of: app) {
            windowTitle = string(of: window, kAXTitleAttribute)
            let result = WindowTextCollector.extract(
                from: Node(element: window),
                limits: .init(maxNodes: maxElements,
                              maxCharacters: ContextBudget.maxChars,
                              maxDepth: maxDepth)
            )
            let strategy = ContextBudget.strategy(isTerminal: target.isTerminal)
            windowText = ContextBudget.clip(result.text, strategy: strategy)
            hasContentRoleText = result.hasContentRoleText
        }

        return CapturedContext(
            source: .accessibility,
            appBundleID: target.bundleID,
            windowTitle: windowTitle,
            fieldLabel: fieldLabel,
            fieldValue: fieldValue,
            fieldPlaceholder: fieldPlaceholder,
            fieldRole: fieldRole,
            windowText: windowText,
            hasContentRoleText: hasContentRoleText
        )
    }

    /// Adapts an `AXUIElement` to the pure walk. `children` is computed lazily
    /// so the collector's caps bound the AX round-trips, not just the output.
    struct Node: AXTextNode {
        let element: AXUIElement

        var role: String { AXContextReader.string(of: element, kAXRoleAttribute) ?? "" }
        var subrole: String? { AXContextReader.string(of: element, kAXSubroleAttribute) }
        var value: String? { AXContextReader.string(of: element, kAXValueAttribute) }
        var title: String? { AXContextReader.string(of: element, kAXTitleAttribute) }

        var children: [any AXTextNode] {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
                  let raw = ref as? [AnyObject] else { return [] }
            return raw.compactMap { child in
                guard CFGetTypeID(child) == AXUIElementGetTypeID() else { return nil }
                return Node(element: child as! AXUIElement)
            }
        }
    }

    private static func focusedWindow(of app: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let value = ref, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// The app's main window — the right answer when the app isn't frontmost
    /// and so reports no focused window.
    private static func mainWindow(of app: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &ref) == .success,
              let value = ref, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// First STANDARD window. `kAXWindows` is not a list of windows: it also
    /// carries tooltips, popovers, transient dialogs and helper windows, which
    /// on a busy desktop outnumber the real ones — taking `windows[0]` blindly
    /// measured 50 characters out of an editor that had thousands, because the
    /// first entry was an 8-node palette.
    private static func firstStandardWindow(of app: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
              let raw = ref as? [AnyObject] else { return nil }
        for candidate in raw {
            guard CFGetTypeID(candidate) == AXUIElementGetTypeID() else { continue }
            let window = candidate as! AXUIElement
            guard string(of: window, kAXRoleAttribute) == kAXWindowRole as String,
                  string(of: window, kAXSubroleAttribute) == kAXStandardWindowSubrole as String
            else { continue }
            return window
        }
        return nil
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

    /// Reads a string attribute, coercing the three shapes `AXValue` actually
    /// arrives in. A plain `as? String` — the original — silently dropped every
    /// rich-text view (`NSAttributedString`) and every numeric cell
    /// (`NSNumber`), which is a lot of real content in editors and spreadsheets.
    static func string(of element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let raw = ref else { return nil }
        let text: String?
        if let s = raw as? String {
            text = s
        } else if let attributed = raw as? NSAttributedString {
            text = attributed.string
        } else if let number = raw as? NSNumber {
            text = number.stringValue
        } else {
            text = nil
        }
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    /// Pre-clip a single huge value (terminal scrollback is one giant AXValue)
    /// so one element can't blow the whole budget before clipping runs.
    private static func clipped(_ value: String?, isTerminal: Bool) -> String? {
        guard let value else { return nil }
        let strategy = ContextBudget.strategy(isTerminal: isTerminal)
        return ContextBudget.clip(value, strategy: strategy)
    }
}
