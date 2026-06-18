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

        Settings {
            SettingsView(controller: delegate.controller)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = CompositionRoot.makeController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar utility: no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)
        controller.activate()
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
