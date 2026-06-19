import SwiftUI
import AppKit
import BarkCore

@main
struct BarkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(controller: delegate.controller)
        } label: {
            Image(systemName: delegate.controller.phase.menuSymbol)
                .accessibilityLabel("Bark — \(delegate.controller.phase.title)")
        }
        .menuBarExtraStyle(.window)
        // No SwiftUI `Settings` scene: in a menu-bar .accessory app it opens
        // unfocused/unreliably. Settings is shown via WindowManager instead.
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = CompositionRoot.makeController()
    private var onboardingWindow: NSWindow?
    private lazy var windowManager = WindowManager(controller: controller)
    private lazy var hud = RecordingHUDController(controller: controller)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar utility: no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)
        controller.onOpenSettings = { [weak self] in self?.windowManager.openSettings() }
        controller.onPhaseChange = { [weak self] phase in self?.hud.handlePhase(phase) }
        controller.onHandsFreeChange = { [weak self] active in self?.hud.setHandsFree(active) }
        controller.activate()
        if !controller.hasCompletedOnboarding {
            showOnboarding()
        }
    }

    private func showOnboarding() {
        let view = OnboardingView(controller: controller) { [weak self] in
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
        }
        let hosting = NSHostingController(rootView: view)
        // Don't let SwiftUI drive the window's content-size extrema — that path
        // (`updateWindowContentSizeExtremaIfNecessary`) re-entrantly invalidates
        // constraints during the launch display cycle and throws (crash fix).
        hosting.sizingOptions = []

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 580),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Bark"
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 480, height: 580))
        window.center()
        onboardingWindow = window

        // Present after the current runloop turn, not mid-launch layout.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }
}

extension DictationPhase {
    var menuSymbol: String {
        switch self {
        case .idle, .completed: return "mic"
        case .listening: return "waveform"
        case .transcribing: return "ellipsis"
        case .cleaning: return "sparkles"
        case .injecting: return "text.cursor"
        case .failed: return "exclamationmark.triangle"
        }
    }

    var title: String {
        switch self {
        case .idle: return "Ready"
        case .listening: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .cleaning: return "Cleaning up…"
        case .injecting: return "Inserting…"
        case .completed: return "Done"
        case .failed(let m): return m
        }
    }
}
