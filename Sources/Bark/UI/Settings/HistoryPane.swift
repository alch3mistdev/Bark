import SwiftUI
import BarkCore

struct HistoryPane: View {
    @Bindable var controller: DictationController
    @State private var records: [HistoryRecord] = []
    @State private var query = ""
    @State private var copiedID: UUID?

    var body: some View {
        Form {
            Section {
                Toggle("Keep history (encrypted, on-device)", isOn: $controller.historyEnabled)
                Text("Off by default. When on, transcripts are stored encrypted (AES-GCM, key in Keychain).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("History") {
                TextField("Search", text: $query)
                    .textFieldStyle(.roundedBorder)
                if records.isEmpty {
                    Text(query.isEmpty ? "No history." : "No matches.").foregroundStyle(.secondary)
                }
                ForEach(records) { r in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.output).lineLimit(2)
                            Text(r.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(copiedID == r.id ? "Copied" : "Copy") {
                            Task { await controller.copyToClipboard(r.output); copiedID = r.id }
                        }
                        .buttonStyle(.borderless)
                    }
                    .contextMenu {
                        Button("Copy to clipboard") {
                            Task { await controller.copyToClipboard(r.output); copiedID = r.id }
                        }
                    }
                }
                if !records.isEmpty {
                    Button("Purge all history", role: .destructive) {
                        Task { await controller.purgeHistory(); await reload() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await reload() }
        .onChange(of: query) { _, _ in copiedID = nil; Task { await reload() } }
    }

    private func reload() async {
        records = await controller.searchHistory(query)
    }
}
