import Foundation

/// One node of an accessibility tree, as the text walk sees it. Kept as a
/// protocol so the collection *policy* is pure and unit-testable while the
/// `AXUIElement` plumbing stays in `BarkEngines` (constitution III).
///
/// `children` must be computed lazily by conformers: the caps below bound the
/// *work*, not just the output, and materializing the whole tree first would
/// do every expensive AX round-trip before any limit applied.
public protocol AXTextNode {
    var role: String { get }
    var subrole: String? { get }
    var value: String? { get }
    var title: String? { get }
    var children: [any AXTextNode] { get }
}

/// Extracts visible text from an accessibility tree.
///
/// The first implementation used a role ALLOW-LIST of `AXStaticText`,
/// `AXTextArea`, `AXTextField` and read only `AXValue`. That returns almost
/// nothing from the apps people actually discuss into: Chromium and Electron
/// expose `AXWebArea`, `AXGroup`, `AXHeading`, `AXLink`, `AXCell`, and plenty
/// of `AXUnknown`, and a great deal of real text lives in `AXTitle` rather
/// than `AXValue`. This is now a DENY-list — take text from anything that has
/// some, and skip only pure chrome.
public enum WindowTextCollector {
    /// Pure chrome: never carries content, and nothing below it does either.
    public static let skippedRoles: Set<String> = [
        "AXScrollBar", "AXSplitter", "AXGrowArea", "AXIncrementor", "AXProgressIndicator",
    ]

    /// Secure fields are never read, at any depth, regardless of the caller's
    /// own checks (defense in depth — SEC-002).
    public static let secureRoles: Set<String> = ["AXSecureTextField"]

    /// Roles that carry a document's or terminal's OWN content, as opposed to
    /// the app's chrome (tab labels, sidebars, status bars — all `AXStaticText`).
    /// Tracking this is what lets a caller tell "we read the content" from "we
    /// read the furniture around an unreadable canvas".
    public static let contentRoles: Set<String> = [
        "AXTextArea", "AXTextField", "AXWebArea", "AXDocument",
    ]

    public struct Limits: Sendable {
        public var maxNodes: Int
        public var maxCharacters: Int
        public var maxDepth: Int

        public init(maxNodes: Int = 2_000, maxCharacters: Int = 20_000, maxDepth: Int = 40) {
            self.maxNodes = maxNodes
            self.maxCharacters = maxCharacters
            self.maxDepth = maxDepth
        }

        public static let `default` = Limits()
    }

    public struct Result: Sendable, Equatable {
        public var text: String
        public var nodeCount: Int
        /// A cap stopped the walk — the text is a prefix of what was there.
        public var truncated: Bool
        /// At least one `contentRoles` node contributed text. False with
        /// non-empty `text` means we only got chrome — see
        /// `CapturedContext.isChromeOnly`.
        public var hasContentRoleText: Bool

        public var isEmpty: Bool { text.isEmpty }
    }

    public static func extract(from root: any AXTextNode, limits: Limits = .default) -> Result {
        var lines: [String] = []
        var characters = 0
        var nodes = 0
        var truncated = false
        var contentRoleText = false

        func visit(_ node: any AXTextNode, depth: Int) {
            guard !truncated else { return }
            guard depth <= limits.maxDepth else { truncated = true; return }
            guard nodes < limits.maxNodes else { truncated = true; return }
            nodes += 1

            let role = node.role
            // Prune: chrome and secure fields, subtree included.
            guard !skippedRoles.contains(role) else { return }
            guard !secureRoles.contains(role),
                  !secureRoles.contains(node.subrole ?? "") else { return }

            // Value first, then title: a control carrying both usually repeats
            // itself, and the value is the live one (what is typed, not what
            // the field is called).
            if let text = (node.value ?? node.title)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty,
               text != lines.last {   // web trees repeat a label across nested nodes
                // The separator counts too — a bound that isn't the bound it
                // states is the start of not trusting any of them.
                let addition = text.count + (lines.isEmpty ? 0 : 1)
                if characters + addition > limits.maxCharacters {
                    truncated = true
                    return
                }
                characters += addition
                lines.append(text)
                if contentRoles.contains(role) { contentRoleText = true }
            }

            for child in node.children {
                guard !truncated else { return }
                visit(child, depth: depth + 1)
            }
        }

        visit(root, depth: 0)
        return Result(text: lines.joined(separator: "\n"), nodeCount: nodes,
                      truncated: truncated, hasContentRoleText: contentRoleText)
    }
}
