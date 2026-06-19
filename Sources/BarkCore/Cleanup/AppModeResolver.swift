import Foundation

/// Resolves which `Mode` to use for a dictation, given the focused app's bundle
/// id and the user's app→mode map. Pure + unit-tested.
public enum AppModeResolver {
    /// Returns the mapped mode id for `bundleID` if the mapping exists AND that
    /// mode still exists in `availableModeIDs`; otherwise `fallback` (the user's
    /// manual selection).
    public static func modeID(
        forBundleID bundleID: String?,
        map: [String: String],
        availableModeIDs: Set<String>,
        fallback: String
    ) -> String {
        guard let bundleID, let mapped = map[bundleID], availableModeIDs.contains(mapped) else {
            return fallback
        }
        return mapped
    }
}
