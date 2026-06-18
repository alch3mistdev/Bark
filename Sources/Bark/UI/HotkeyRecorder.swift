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
            Button(recording ? "Press a key or modifier…" : "Record") {
                recording ? stop() : start()
            }
            .buttonStyle(.bordered)
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
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
        switch event.type {
        case .keyDown:
            // Only function/navigation keys may be a toggle: a printable key would
            // be consumed globally and become untypable. Ignore others (keep listening).
            guard isAllowedToggleKey(event) else { return }
            setting = HotkeySetting(kind: .keyToggle, keyCode: UInt16(event.keyCode), modifierFlags: 0)
            stop()
        case .flagsChanged:
            let flags = cgFlag(from: event.modifierFlags)
            if flags != 0 {
                setting = HotkeySetting(kind: .modifierHold, keyCode: 0, modifierFlags: flags)
                stop()
            }
        default:
            break
        }
    }

    /// Function/navigation keys live in the 0xF700–0xF8FF private-use range.
    private func isAllowedToggleKey(_ event: NSEvent) -> Bool {
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else { return true }
        return scalar.value >= 0xF700
    }

    private func cgFlag(from flags: NSEvent.ModifierFlags) -> UInt64 {
        if flags.contains(.function) { return HotkeySetting.fnFlag }
        if flags.contains(.command)  { return 0x100000 }
        if flags.contains(.option)   { return 0x80000 }
        if flags.contains(.control)  { return 0x40000 }
        if flags.contains(.shift)    { return 0x20000 }
        return 0
    }
}
