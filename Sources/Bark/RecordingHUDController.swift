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
    private var positionToken = 0   // invalidates stale async caret-anchor results

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

        // Position at the safe fallback immediately — show() must never block on an
        // Accessibility probe (it runs synchronously from the phase setter; a hung
        // focused app would otherwise stall dictation start/stop) (Codex/ADV-003).
        panel.setFrameOrigin(HUDPlacement.bottomCenter(panelSize: size, visibleFrame: fallbackVisibleFrame()))
        panel.orderFront(nil)   // never makeKey — keep focus on the target app

        // Enhanced overlay: refine to a caret anchor OFF the main actor, then
        // reposition. Skip entirely for secure fields (don't anchor over a password
        // field) (ADV-004).
        positionToken += 1
        guard controller.enhancedHUD, !SecureFieldDetector.secureInputActive() else { return }
        let token = positionToken
        Task.detached {
            guard let caret = FocusProbe.focusedCaretRect() else { return }
            await MainActor.run { [weak self] in self?.applyCaretAnchor(caret, token: token, size: size) }
        }
    }

    /// Reposition under the caret if the probe is still current and lands on a real
    /// screen; otherwise keep the bottom-center fallback already applied in show().
    private func applyCaretAnchor(_ caret: CGRect, token: Int, size: CGSize) {
        guard token == positionToken, let panel, panel.isVisible else { return }   // stale or hidden
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first,
              let screen = screenContaining(caretAX: caret, primaryHeight: primary.frame.height),  // nil → keep fallback (ADV-002)
              let origin = HUDPlacement.underCaret(caretAX: caret, panelSize: size,
                                                   visibleFrame: screen.visibleFrame,
                                                   primaryHeight: primary.frame.height)
        else { return }
        panel.setFrameOrigin(origin)
    }

    private func fallbackVisibleFrame() -> CGRect {
        (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
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

    /// Screen whose frame contains the caret (caret converted AX→AppKit).
    private func screenContaining(caretAX: CGRect, primaryHeight: CGFloat) -> NSScreen? {
        let appKitY = primaryHeight - caretAX.maxY
        let point = CGPoint(x: caretAX.midX, y: appKitY)
        return NSScreen.screens.first { $0.frame.contains(point) }
    }
}
