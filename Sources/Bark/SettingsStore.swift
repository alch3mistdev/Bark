import Foundation
import Observation
import BarkCore

/// Observable, `UserDefaults`-backed persistence for `Settings`. Mutations are
/// applied through `update` and written immediately as JSON.
@MainActor
@Observable
public final class SettingsStore {
    public private(set) var settings: Settings
    /// Set when an unreadable settings blob forced a reset to defaults; the menu
    /// popover shows a one-time notice. The raw blob is preserved under
    /// `<key>.backup` so custom modes/prompts/hotkeys aren't silently destroyed.
    public private(set) var didResetSettings = false
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "com.bark.settings.v1") {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key) {
            if let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
                self.settings = decoded
            } else {
                // Corrupt/incompatible blob: reset, but never silently — back up
                // the payload (the history store gets the same courtesy) and flag
                // the reset for the UI.
                defaults.set(data, forKey: key + ".backup")
                self.settings = .default
                self.didResetSettings = true
            }
        } else {
            self.settings = .default
        }
    }

    public func acknowledgeReset() { didResetSettings = false }

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
