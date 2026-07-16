import AppKit
import SwiftUI
import BarkCore
import BarkEngines

/// Shows/hides the suggestion picker panel as the session progresses (015).
///
/// Unlike the recording HUD (never key), this panel ACCEPTS keyboard input via
/// a **non-activating key panel** (R3): `.nonactivatingPanel` + `canBecomeKey`
/// means it receives keys while Bark never activates, so
/// `NSWorkspace.frontmostApplication` keeps naming the target app and the
/// injection preflight's focus check passes. While the panel is key the AX
/// focused element IS the panel — so injection runs only after the panel is
/// ordered out (the controller adds a settle delay).
@MainActor
final class SuggestionOverlayController: NSObject, NSWindowDelegate {
    private let controller: SuggestionController
    private var panel: SuggestionPanel?
    private var positionToken = 0

    init(controller: SuggestionController) {
        self.controller = controller
    }

    func handleSession(_ session: SuggestionSession) {
        switch session.phase {
        case .capturing:
            // Show WITHOUT taking key: while the flow reads the system-wide AX
            // focused element (secure-field check + field metadata), the target
            // app must stay focused. A key panel would make Bark's own panel the
            // focused element and defeat the secure-field guard (R3).
            show(session, takeKey: false)
        case .generating:
            update(session, takeKey: false)
        case .presenting, .failed:
            // Capture is done; now take key so 1–4/arrows/Return/Esc work.
            update(session, takeKey: true)
        case .idle, .injecting, .dictating:
            hide()
        }
    }

    private func show(_ session: SuggestionSession, takeKey: Bool) {
        let panel = panel ?? makePanel()
        self.panel = panel
        resize(panel, for: session)

        // Fallback position immediately (never block on an AX probe), then
        // refine to a caret anchor off the main actor — the HUD's pattern.
        panel.setFrameOrigin(HUDPlacement.bottomCenter(
            panelSize: panel.frame.size, visibleFrame: fallbackVisibleFrame()))
        if takeKey {
            panel.makeKeyAndOrderFront(nil)   // key WITHOUT activating Bark (R3)
        } else {
            panel.orderFront(nil)             // visible but never key — keep target focus
        }

        positionToken += 1
        guard !SecureFieldDetector.secureInputActive() else { return }
        let token = positionToken
        Task.detached {
            guard let caret = FocusProbe.focusedCaretRect() else { return }
            await MainActor.run { [weak self] in self?.applyCaretAnchor(caret, token: token) }
        }
    }

    private func update(_ session: SuggestionSession, takeKey: Bool) {
        guard let panel, panel.isVisible else { show(session, takeKey: takeKey); return }
        resize(panel, for: session)
        if takeKey, !panel.isKeyWindow { panel.makeKeyAndOrderFront(nil) }
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func resize(_ panel: NSPanel, for session: SuggestionSession) {
        let size = SuggestionOverlayView.size(for: session)
        guard panel.frame.size != size else { return }
        // Grow upward-stable: keep the top-left corner fixed so rows appear
        // below the header instead of the panel jumping.
        let topLeft = CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
        panel.setContentSize(size)
        panel.setFrameTopLeftPoint(topLeft)
    }

    private func applyCaretAnchor(_ caret: CGRect, token: Int) {
        guard token == positionToken, let panel, panel.isVisible else { return }
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first,
              let screen = screenContaining(caretAX: caret, primaryHeight: primary.frame.height),
              let origin = HUDPlacement.underCaret(caretAX: caret, panelSize: panel.frame.size,
                                                   visibleFrame: screen.visibleFrame,
                                                   primaryHeight: primary.frame.height)
        else { return }
        panel.setFrameOrigin(origin)
    }

    private func fallbackVisibleFrame() -> CGRect {
        (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func screenContaining(caretAX: CGRect, primaryHeight: CGFloat) -> NSScreen? {
        let appKitY = primaryHeight - caretAX.maxY
        let point = CGPoint(x: caretAX.midX, y: appKitY)
        return NSScreen.screens.first { $0.frame.contains(point) }
    }

    private func makePanel() -> SuggestionPanel {
        let hosting = NSHostingController(rootView: SuggestionOverlayView(controller: controller))
        hosting.sizingOptions = []
        let panel = SuggestionPanel(
            contentRect: NSRect(origin: .zero, size: SuggestionOverlayView.size(for: controller.session)),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = false
        panel.delegate = self
        panel.onKeyEvent = { [weak self] event in self?.route(event) }
        return panel
    }

    private func route(_ event: SuggestionKeyEvent) {
        switch event {
        case .choose(let index): controller.choose(index)
        case .moveUp:            controller.moveHighlight(-1)
        case .moveDown:          controller.moveHighlight(1)
        case .accept:            controller.acceptHighlighted()
        case .dismiss:           controller.dismiss()
        case .other:             controller.chooseOther()
        }
    }

    /// Clicking elsewhere / app switch takes key away → dismiss, unless WE
    /// took it away by hiding for injection/dictation.
    func windowDidResignKey(_ notification: Notification) {
        switch controller.session.phase {
        case .capturing, .generating, .presenting, .failed:
            controller.dismiss()
        default:
            break
        }
    }
}

/// Borderless non-activating panel that can become key (R3) and routes keys
/// through the pure `SuggestionKeyDecoder` table.
final class SuggestionPanel: NSPanel {
    var onKeyEvent: ((SuggestionKeyEvent) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if let decoded = SuggestionKeyDecoder.decode(keyCode: UInt16(event.keyCode)) {
            onKeyEvent?(decoded)
            return
        }
        super.keyDown(with: event)
    }

    /// Escape also arrives as the standard cancel action.
    override func cancelOperation(_ sender: Any?) {
        onKeyEvent?(.dismiss)
    }
}
