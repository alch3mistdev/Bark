import Foundation

/// Pure, case/diacritic-insensitive search over history records, with optional
/// mode/app facets. No I/O — `HistoryStore.search` composes this with `all()`.
public enum HistoryQuery {
    /// Records whose transcript OR output contains `text` (case/diacritic-insensitive),
    /// optionally narrowed to a mode and/or app. Empty `text` matches everything (so
    /// callers get "recent" when the search box is blank). Result is unsorted; the
    /// store sorts/trims via `RetentionPolicy`.
    public static func filter(
        _ records: [HistoryRecord],
        matching text: String,
        modeID: String? = nil,
        bundleID: String? = nil
    ) -> [HistoryRecord] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return records.filter { record in
            if let modeID, record.modeID != modeID { return false }
            if let bundleID, record.appBundleID != bundleID { return false }
            guard !needle.isEmpty else { return true }
            return contains(record.transcript, needle) || contains(record.output, needle)
        }
    }

    /// Locale-aware substring match, ignoring case and diacritics.
    private static func contains(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
