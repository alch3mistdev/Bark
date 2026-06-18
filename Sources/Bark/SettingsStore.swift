import Foundation
import Observation
import BarkCore

/// Observable, `UserDefaults`-backed persistence for `Settings`. Mutations are
/// applied through `update` and written immediately as JSON.
@MainActor
@Observable
public final class SettingsStore {
    public private(set) var settings: Settings
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "com.bark.settings.v1") {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = .default
        }
    }

    public func update(_ mutate: (inout Settings) -> Void) {
        var next = settings
        mutate(&next)
        guard next != settings else { return }
        settings = next
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}
