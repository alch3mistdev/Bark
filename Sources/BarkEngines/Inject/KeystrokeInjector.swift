import AppKit
import CoreGraphics
import BarkCore

/// Fallback injector: synthesizes Unicode keystrokes directly, leaving the
/// clipboard untouched. Used when paste is rejected or disabled.
///
/// Strips newlines entirely (joins with spaces) so a synthetic key event can
/// never submit a line in a terminal (T-006 / SEC-005). Never posts Return.
public final class KeystrokeInjector: TextInjector {
    private let chunkSize: Int

    public init(chunkSize: Int = 20) {
        self.chunkSize = max(1, chunkSize)
    }

    public func inject(_ text: String, plan: InjectionPlan) async throws {
        let safe = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        guard !safe.isEmpty else { throw InjectionError.emptyText }

        try await MainActor.run {
            try InjectionPreflight.check(plan)
            try Self.type(safe, chunkSize: chunkSize)
        }
    }

    @MainActor
    private static func type(_ text: String, chunkSize: Int) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw InjectionError.pasteFailed
        }
        let scalars = Array(text.utf16)
        var index = 0
        while index < scalars.count {
            let end = min(index + chunkSize, scalars.count)
            var chunk = Array(scalars[index..<end])
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else {
                throw InjectionError.pasteFailed
            }
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            down.post(tap: .cgAnnotatedSessionEventTap)
            up.post(tap: .cgAnnotatedSessionEventTap)
            index = end
        }
    }
}
