import Foundation

/// One stored dictation. May contain sensitive content, so it is only ever
/// persisted encrypted, opt-in (`Settings.historyEnabled`).
public struct HistoryRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public var transcript: String   // raw STT
    public var output: String       // what was injected (cleaned)
    public var modeID: String
    public var appBundleID: String?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        transcript: String,
        output: String,
        modeID: String,
        appBundleID: String?
    ) {
        self.id = id
        self.createdAt = createdAt
        self.transcript = transcript
        self.output = output
        self.modeID = modeID
        self.appBundleID = appBundleID
    }
}

/// Encrypted, opt-in transcript history. Concrete impl (`EncryptedHistoryStore`)
/// lives in `BarkEngines`.
public protocol HistoryStore: Sendable {
    func append(_ record: HistoryRecord) async throws
    func all() async -> [HistoryRecord]
    func purge() async throws
}

/// Pure retention logic: keep the most recent `limit` records (newest first).
public enum RetentionPolicy {
    public static let defaultLimit = 200

    /// Returns records sorted newest-first and trimmed to `limit`.
    public static func trim(_ records: [HistoryRecord], limit: Int = defaultLimit) -> [HistoryRecord] {
        let sorted = records.sorted { $0.createdAt > $1.createdAt }
        return Array(sorted.prefix(max(0, limit)))
    }
}
