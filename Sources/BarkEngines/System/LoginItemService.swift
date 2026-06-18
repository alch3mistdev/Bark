import Foundation
import ServiceManagement

/// Registers the app as a Login Item via `SMAppService` so Bark is always in the
/// menu bar. Only works from an installed, signed `.app` bundle — from a bare
/// CLI binary `register()` throws, which the UI surfaces.
public enum LoginItemService {
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        }
    }
}
