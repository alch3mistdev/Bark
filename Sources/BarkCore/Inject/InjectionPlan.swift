import Foundation

/// The app focused when dictation started. We re-verify it is still focused
/// immediately before injecting so text never lands in the wrong window
/// (SEC-004 / T-004).
public struct InjectionTarget: Sendable, Equatable {
    public var pid: Int32
    public var bundleID: String?

    public init(pid: Int32, bundleID: String?) {
        self.pid = pid
        self.bundleID = bundleID
    }

    public var isTerminal: Bool { TerminalDetector.isTerminal(bundleID) }
}

public enum InjectionStrategy: Sendable, Equatable {
    case paste       // pasteboard + ⌘V (default; fast, Unicode-safe)
    case keystroke   // synthesize Unicode keystrokes (fallback)
}

/// Everything the injector needs to act safely.
public struct InjectionPlan: Sendable, Equatable {
    public var target: InjectionTarget
    public var strategy: InjectionStrategy
    /// Always strip trailing newlines; we also never synthesize Return (T-006/SEC-005).
    public var stripTrailingNewlines: Bool

    public init(target: InjectionTarget, strategy: InjectionStrategy = .paste, stripTrailingNewlines: Bool = true) {
        self.target = target
        self.strategy = strategy
        self.stripTrailingNewlines = stripTrailingNewlines
    }
}

/// Pure focus-stability check used before injecting.
public enum FocusGuard {
    public static func targetUnchanged(captured: InjectionTarget, current: InjectionTarget?) -> Bool {
        guard let current else { return false }
        return captured.pid == current.pid
    }
}

/// Known terminal/shell apps where an accidental newline could execute a command.
/// For these we are extra conservative (never auto-submit; default to keystroke).
public enum TerminalDetector {
    static let bundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "co.zeit.hyper",
        "com.github.wez.wezterm",
        "org.tabby",
        "com.mitchellh.ghostty",
    ]

    public static func isTerminal(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleIDs.contains(bundleID)
    }
}
