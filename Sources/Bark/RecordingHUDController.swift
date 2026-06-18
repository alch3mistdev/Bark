import AppKit
import SwiftUI
import BarkCore

/// Shows/hides a floating, **non-activating** HUD panel as dictation runs. The
/// panel never becomes key, so the focused app (and Bark's focus/secure-field
/// checks at injection time) are unaffected.
@MainActor
final class RecordingHUDController {
    private let controller: DictationController
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    init(controller: DictationController) {
        self.controller = controller
    }

    func handlePhase(_ phase: DictationPhase) {
        if phase.isActive {
            hideWorkItem?.cancel()
            show()
        } else {
            // Linger briefly on completed/failed so the user sees the outcome.
            scheduleHide(after: phase.isError ? 2.5 : 0.8)
        }
    }

    private func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.orderFront(nil)   // never makeKey — keep focus on the target app
    }

    private func scheduleHide(after seconds: Double) {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func makePanel() -> NSPanel {
        let hosting = NSHostingController(rootView: RecordingHUDView(controller: controller))
        hosting.sizingOptions = []
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 64),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.setContentSize(NSSize(width: 320, height: 64))
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 120))
    }
}
