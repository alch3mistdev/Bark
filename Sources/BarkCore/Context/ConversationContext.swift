import Foundation

/// What Bark read from the focused app to ground reply suggestions on. Holds
/// only the latest message we could recover — never a full transcript — and is
/// discarded as soon as the menu closes (never persisted; see Privacy, 009).
public struct ConversationContext: Sendable, Equatable {
    /// The other party's latest message (best-effort; the tail of the focused
    /// window's accessible text).
    public var lastMessage: String
    /// Bundle id of the app it was read from, if known.
    public var appBundleID: String?

    public init(lastMessage: String, appBundleID: String? = nil) {
        self.lastMessage = lastMessage
        self.appBundleID = appBundleID
    }

    /// Bound the text we feed the model (privacy + latency): keep the tail, since
    /// the most recent message is what the user is replying to.
    public func bounded(maxCharacters: Int = 2000) -> ConversationContext {
        guard lastMessage.count > maxCharacters else { return self }
        let tail = String(lastMessage.suffix(maxCharacters))
        return ConversationContext(lastMessage: tail, appBundleID: appBundleID)
    }
}

/// One offered reply. `label` is shown in the menu; `payload` is the text typed
/// into the app when picked. `id` is stable for SwiftUI; equality is by value so
/// tests can compare suggestions without minting matching ids.
public struct BranchOption: Identifiable, Sendable {
    public let id: UUID
    public let label: String
    public let payload: String

    public init(id: UUID = UUID(), label: String, payload: String) {
        self.id = id
        self.label = label
        self.payload = payload
    }

    /// Convenience for options where the shown text is also what's typed.
    public init(_ text: String) {
        self.init(label: text, payload: text)
    }
}

extension BranchOption: Equatable {
    public static func == (lhs: BranchOption, rhs: BranchOption) -> Bool {
        lhs.label == rhs.label && lhs.payload == rhs.payload
    }
}

/// Reads the focused app to recover the latest message Bark should suggest
/// replies to. The runtime backend (`AccessibilityContextReader`) reads on-device
/// via the Accessibility API; tests inject a fake. Reads content, so callers must
/// gate it behind the Smart Replies opt-in (Principle I & IV).
public protocol ContextProvider: Sendable {
    /// Best-effort context for the currently focused app, or nil if none is
    /// readable. Async because the underlying AX IPC may block briefly.
    func currentContext() async -> ConversationContext?
}
