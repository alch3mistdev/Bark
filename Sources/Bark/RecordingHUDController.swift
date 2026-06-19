import AppKit
import SwiftUI
import BarkCore
import BarkEngines

/// Shows/hides a floating, **non-activating** HUD panel as dictation runs. The
/// panel never becomes key, so the focused app (and Bark's focus/secure-field
/// checks at injection time) are unaffected.
@MainActor
final class RecordingHUDController {
    private let controller: DictationController
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?
    private var handsFree = false

    init(controller: DictationController) {
        self.controller = controller
    }

    func handlePhase(_ phase: DictationPhase) {
        if phase.isActive || handsFree {
            hideWorkItem?.cancel()
            show()
        } else {
            // Linger briefly on completed/failed so the user sees the outcome.
            scheduleHide(after: phase.isError ? 2.5 : 0.8)
        }
    }

    /// Keep the HUD visible for the whole hands-free session (between utterances too).
    func setHandsFree(_ active: Bool) {
        handsFree = active
        if active {
            hideWorkItem?.cancel()
            show()
        } else {
            scheduleHide(after: 0.4)
        }
    }

    private func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        let size = RecordingHUDView.size(enhanced: controller.enhancedHUD)
        if panel.frame.size != size { panel.setContentSize(size) }
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
        let size = panel.frame.size

        // Enhanced HUD anchors near the text caret when the focused field exposes
        // one; everything else (and any failure) falls back to bottom-center.
        if controller.enhancedHUD,
           let caret = FocusProbe.focusedCaretRect(),
           let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first {
            let screen = screenContaining(caretAX: caret, primaryHeight: primary.frame.height) ?? NSScreen.main ?? primary
            if let origin = HUDPlacement.underCaret(caretAX: caret, panelSize: size,
                                                    visibleFrame: screen.visibleFrame,
                                                    primaryHeight: primary.frame.height) {
                panel.setFrameOrigin(origin)
                return
            }
        }

        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? .init(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrameOrigin(HUDPlacement.bottomCenter(panelSize: size, visibleFrame: visible))
    }

    /// Screen whose frame contains the caret (caret converted AX→AppKit).
    private func screenContaining(caretAX: CGRect, primaryHeight: CGFloat) -> NSScreen? {
        let appKitY = primaryHeight - caretAX.maxY
        let point = CGPoint(x: caretAX.midX, y: appKitY)
        return NSScreen.screens.first { $0.frame.contains(point) }
    }
}
