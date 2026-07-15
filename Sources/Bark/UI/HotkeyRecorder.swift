import SwiftUI
import AppKit
import BarkCore

/// Captures the next key press or modifier hold and writes it as a `HotkeySetting`.
struct HotkeyRecorder: View {
    @Binding var setting: HotkeySetting
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(setting.displayName)
                .font(.body.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Current hotkey")
                .accessibilityValue(setting.displayName)
            Button(recording ? "Press a key or modifier…" : "Record") {
                recording ? stop() : start()
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(recording ? "Recording, press a function key now" : "Record new hotkey")
            .accessibilityHint("Only function keys (F1–F20) can be a global hotkey")
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handle(event)
            return nil   // swallow while recording
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        // Modifier-hold triggers are chosen via the preset picker; the recorder
        // only captures a function/navigation key as a toggle (a printable key
        // would be consumed globally and become untypable).
        guard event.type == .keyDown, isAllowedToggleKey(event) else { return }
        setting = HotkeySetting(kind: .keyToggle, keyCode: UInt16(event.keyCode), modifierFlags: 0)
        stop()
    }

    /// Function/navigation keys live in the 0xF700–0xF8FF private-use range.
    private func isAllowedToggleKey(_ event: NSEvent) -> Bool {
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else { return false }
        return scalar.value >= 0xF700
    }
}
