import SwiftUI
import AppKit
import BarkCore

/// Captures the next key press or modifier hold and writes it as a `HotkeySetting`.
struct HotkeyRecorder: View {
    @Binding var setting: HotkeySetting
    @State private var recording = false
    @State private var monitor: Any?
    @State private var rejectionNote: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                Text(setting.displayName)
                    .font(.body.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Current hotkey")
                    .accessibilityValue(setting.displayName)
                Button(recording ? "Press a function key or ⌃⌥⌘ + key…" : "Record") {
                    recording ? stop() : start()
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(recording ? "Recording, press a hotkey now" : "Record new hotkey")
                .accessibilityHint("A function key, or a chord such as control-option and a letter")
            }
            if let rejectionNote {
                Text(rejectionNote)
                    .font(.caption2).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        rejectionNote = nil
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
        guard event.type == .keyDown else { return }
        if event.keyCode == 53, chordFlags(event) == 0 { stop(); return }   // bare Esc cancels

        let chord = chordFlags(event)
        if isFunctionKey(event), chord == 0 {
            // A bare function key: fine as before.
            commit(keyCode: event.keyCode, modifierFlags: 0)
            return
        }
        // Otherwise require a chord with at least one of ⌃⌥⌘ — a bare printable
        // key (or ⇧-only) would be consumed globally and become untypable.
        if chord & 0x1C0000 != 0 {   // control | option | command
            commit(keyCode: event.keyCode, modifierFlags: chord)
            return
        }
        rejectionNote = "Use a function key, or hold ⌃, ⌥, or ⌘ with another key "
            + "(a bare key would become untypable everywhere). Esc cancels."
    }

    private func commit(keyCode: UInt16, modifierFlags: UInt64) {
        rejectionNote = nil
        setting = HotkeySetting(kind: .keyToggle, keyCode: keyCode, modifierFlags: modifierFlags)
        stop()
    }

    /// The ⌃⌥⌘⇧ subset held, as `HotkeySetting`/`CGEventFlags` raw bits.
    private func chordFlags(_ event: NSEvent) -> UInt64 {
        var flags: UInt64 = 0
        if event.modifierFlags.contains(.control) { flags |= 0x40000 }
        if event.modifierFlags.contains(.option)  { flags |= 0x80000 }
        if event.modifierFlags.contains(.command) { flags |= 0x100000 }
        if event.modifierFlags.contains(.shift)   { flags |= 0x20000 }
        return flags
    }

    /// Function/navigation keys live in the 0xF700–0xF8FF private-use range.
    private func isFunctionKey(_ event: NSEvent) -> Bool {
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else { return false }
        return scalar.value >= 0xF700
    }
}
