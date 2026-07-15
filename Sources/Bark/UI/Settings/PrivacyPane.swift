import SwiftUI

struct PrivacyPane: View {
    var body: some View {
        Form {
            Section("Fully offline by default") {
                Label("Audio never leaves your Mac", systemImage: "mic.slash")
                Label("Transcription runs on the Apple Neural Engine", systemImage: "cpu")
                Label("No telemetry, analytics, or accounts", systemImage: "network.slash")
            }
            Section("Safety") {
                Label("Avoids detected password / secure fields", systemImage: "key")
                Label("Never presses Return (won't run terminal commands)", systemImage: "terminal")
                Label("Restores your clipboard after pasting", systemImage: "doc.on.clipboard")
                Label("History is off by default, encrypted when on", systemImage: "lock.doc")
            }
        }
        .formStyle(.grouped)
    }
}
