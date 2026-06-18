import AppKit
import SwiftUI

/// Owns the app's auxiliary AppKit windows. For a menu-bar `.accessory` app the
/// SwiftUI `Settings` scene + `openSettings()` is unreliable (opens unfocused or
/// not at all), so we host `SettingsView` in a real `NSWindow` we control and
/// bring to the front ourselves — the same pattern that fixed the onboarding
/// crash (`sizingOptions = []`, explicit contentRect).
@MainActor
final class WindowManager {
    private let controller: DictationController
    private var settingsWindow: NSWindow?

    init(controller: DictationController) {
        self.controller = controller
    }

    func openSettings() {
        if let window = settingsWindow {
            present(window)
            return
        }
        let hosting = NSHostingController(rootView: SettingsView(controller: controller))
        hosting.sizingOptions = []

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 430),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Bark Settings"
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 480, height: 430))
        window.center()
        settingsWindow = window
        present(window)
    }

    private func present(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
