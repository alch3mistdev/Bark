import AppKit
import SwiftUI
import BarkCore
import BarkEngines

/// Shows/hides the discussion panel as the session progresses (017). Clone of
/// the 015 overlay mechanism: a **non-activating key panel** receives keys
/// while Bark never activates, so `NSWorkspace.frontmostApplication` keeps
/// naming the target app and the Confirm-time preflight's focus check passes.
///
/// Key-taking is phase-dependent: during `capturing` the panel is visible but
/// NOT key (the capture flow reads the system-wide AX focused element — the
/// target app must stay focused for the secure-field check to be honest);
/// from `thinking` onward it takes key so Esc/D/Return and the buttons work.
@MainActor
final class DiscussionOverlayController: NSObject, NSWindowDelegate {
    private let controller: DiscussionController
    private var panel: DiscussionPanel?
    private var positionToken = 0

    init(controller: DiscussionController) {
        self.controller = controller
    }

    func handleSession(_ session: DiscussionSession) {
        switch session.state {
        case .capturing:
            show(session, takeKey: false)
        case .thinking, .presenting, .awaitingUser, .listening, .transcribing,
             .turnFailed, .synthesizing, .synthesisFailed, .previewing:
            update(session, takeKey: true)
        case .idle, .injecting, .finished, .cancelled:
            hide()
        }
    }

    private func show(_ session: DiscussionSession, takeKey: Bool) {
        let panel = panel ?? makePanel()
        self.panel = panel
        resize(panel, for: session)
        panel.setFrameOrigin(HUDPlacement.bottomCenter(
            panelSize: panel.frame.size, visibleFrame: fallbackVisibleFrame()))
        if takeKey {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFront(nil)
        }

        positionToken += 1
        guard !SecureFieldDetector.secureInputActiveForFrontmostApp() else { return }
        let token = positionToken
        Task.detached {
            guard let caret = FocusProbe.focusedCaretRect() else { return }
            await MainActor.run { [weak self] in self?.applyCaretAnchor(caret, token: token) }
        }
    }

    private func update(_ session: DiscussionSession, takeKey: Bool) {
        guard let panel, panel.isVisible else { show(session, takeKey: takeKey); return }
        resize(panel, for: session)
        if takeKey, !panel.isKeyWindow { panel.makeKeyAndOrderFront(nil) }
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func resize(_ panel: NSPanel, for session: DiscussionSession) {
        let size = DiscussionOverlayView.size(for: session)
        guard panel.frame.size != size else { return }
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

    private func makePanel() -> DiscussionPanel {
        let hosting = NSHostingController(rootView: DiscussionOverlayView(controller: controller))
        hosting.sizingOptions = []
        let panel = DiscussionPanel(
            contentRect: NSRect(origin: .zero, size: DiscussionOverlayView.size(for: controller.session)),
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

    private func route(_ event: DiscussionKeyEvent) {
        switch event {
        case .cancel:  controller.cancel()
        case .confirm: controller.confirm()
        case .done:    controller.done()
        case .resume:  controller.resume()
        case .copy:
            if controller.session.state == .previewing {
                controller.copyPrompt()
            } else {
                controller.copyTranscript()
            }
        }
    }

    /// Clicking elsewhere takes key away. Unlike the one-shot suggestions
    /// picker, a discussion is long-lived state the user shouldn't lose to a
    /// stray click — so we do NOT cancel; the panel stays visible (floating,
    /// non-key) and the hotkey/buttons bring it back.
    func windowDidResignKey(_ notification: Notification) {}
}

/// Borderless non-activating panel that can become key and routes keys
/// through the pure `DiscussionKeyDecoder` table.
final class DiscussionPanel: NSPanel {
    var onKeyEvent: ((DiscussionKeyEvent) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if let decoded = DiscussionKeyDecoder.decode(keyCode: UInt16(event.keyCode)) {
            onKeyEvent?(decoded)
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onKeyEvent?(.cancel)
    }
}
