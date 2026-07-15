import SwiftUI
import BarkCore
import BarkEngines

/// Inspects the SHA-256-verified model cache. The pane lets the user see what
/// has been downloaded for the WhisperKit / Parakeet backends, re-verify any
/// cached bundle, reveal it in Finder, or delete it. Always uses
/// `ModelInspector` (an actor) — no main-thread disk I/O on the UI thread.
@MainActor
struct ModelsPane: View {
    @State private var inspector = ModelInspector()
    @State private var snapshot = ModelCacheSnapshot.empty
    @State private var loadError: String?

    var body: some View {
        Form {
            Section("Cache") {
                HStack {
                    Text(snapshot.models.isEmpty
                         ? "No models cached yet."
                         : "\(snapshot.models.count) cached · \(snapshot.displaySize)")
                    Spacer()
                    Button("Reveal in Finder") { Task { await inspector.reveal() } }
                }
                Text("Models live in ~/Library/Application Support/Bark/models/. "
                     + "Bundles are SHA-256 verified against a bundled manifest before they land here "
                     + "(SEC-003). Tap Re-verify below to re-check any cached bundle.")
                    .font(.caption).foregroundStyle(.secondary)
                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).font(.caption)
                }
            }
            if snapshot.models.isEmpty {
                Section {
                    Text("To cache a model, pick a non-Apple engine in General ▸ Speech ▸ Engine "
                         + "and trigger a dictation. The first utterance downloads and verifies the "
                         + "weights.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section("Cached models") {
                    ForEach(snapshot.models) { model in
                        ModelRow(model: model, inspector: inspector, snapshot: $snapshot)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await reload() }
    }

    private func reload() async {
        snapshot = await inspector.snapshot()
        loadError = nil
    }
}

@MainActor
struct ModelRow: View {
    let model: CachedModel
    let inspector: ModelInspector
    @Binding var snapshot: ModelCacheSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(model.backend.displayName).font(.headline)
                Spacer()
                Text(model.displaySize).monospacedDigit().foregroundStyle(.secondary)
            }
            Text(model.modelID).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                verificationBadge
                Spacer()
                Button("Re-verify") { Task { await reVerify() } }
                Button("Reveal") { Task { await inspector.reveal(model) } }
                Button(role: .destructive) {
                    Task { await remove() }
                } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var verificationBadge: some View {
        switch model.verification {
        case .verified:
            Label("Verified", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green).font(.caption)
        case .hashMismatch(_, let actual):
            Label("Hash mismatch: \(actual.prefix(12))…", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.caption)
        case .noManifestFound:
            Label("No manifest bundled", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary).font(.caption)
        case .notVerified(let reason):
            Label(reason, systemImage: "circle.dashed")
                .foregroundStyle(.secondary).font(.caption)
        }
    }

    private func reVerify() async {
        let updated = await inspector.verify(model)
        if let i = snapshot.models.firstIndex(where: { $0.id == updated.id }) {
            snapshot.models[i] = updated
        }
    }

    private func remove() async {
        await inspector.remove(model)
        snapshot = await inspector.snapshot()
    }
}
