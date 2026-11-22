import Foundation

// The archive's index entry for one session (`SessionArchiveEntry`): the
// quick-access metadata lists and trends read without loading the session.

/// Session archive entry with quick-access metadata
/// Sendable so background tasks (e.g.
/// HistoryViewModel's BFS dedup) can carry `[SessionArchiveEntry]`
/// across actor boundaries. All fields are value types or already
/// Sendable.
struct SessionArchiveEntry: Codable, Sendable {
    static let currentSchemaVersion = 1

    /// Schema version read from the index entry during decode (0 when the
    /// entry predates it); nil for an entry built in memory. Kept, not
    /// discarded, so an index written by a newer build can be told apart
    /// before this build re-saves it; `encode` writes `currentSchemaVersion`.
    /// An entry holding a `SessionType` or `HRVDataQuality` case this build
    /// does not know reads as one newer than `currentSchemaVersion`, as
    /// `HRVSession` reads it.
    var sourceSchemaVersion: Int?

    let sessionId: UUID
    let date: Date
    /// When the recording ended (for overnight sessions, this is the meaningful "reading time")
    let endDate: Date?
    let fileHash: String
    let filePath: String
    /// Composite recovery score (0-10 scale). See HRVSession.recoveryScore for details.
    let recoveryScore: Double?
    let meanRMSSD: Double?
    /// Mean heart rate (bpm) for trend computation without loading sessions
    let meanHR: Double?
    /// Stress index for trend computation without loading sessions
    let stressIndex: Double?
    /// SDNN value (ms) for Apple Watch Breathe sessions
    let meanSDNN: Double?
    let tags: [ReadingTag]
    let notes: String?
    let sessionType: SessionType
    /// IDs of sessions linked to this one (pause/resume chain). Nil for standalone sessions.
    let linkedSessionIds: [UUID]?
    /// Actual sleep end time from the snapshot (or resolved boundaries). Used
    /// as the display "wake time" in history. Falls back to `endDate` when
    /// nil (legacy entries, non-overnight sessions).
    let sleepEnd: Date?
    /// Number of meaningful sleep segments from the snapshot's effective
    /// segments (or stored `sleepSegments`). Used by history to decide
    /// whether to render the split-night badge — linked *recording* sessions
    /// alone don't prove the user's *sleep* was split. Nil/1 means single
    /// continuous sleep; badge suppressed.
    let sleepSegmentCount: Int?

    // MARK: - Sleep stage minutes (from session.sleepSnapshot)
    //
    // Mirrored into the lightweight index so trend queries and the AI
    // assistant can reason about deep / REM / core / awake across the full
    // 30-day archive without having to load each session's RR file.
    let deepSleepMinutes: Int?
    let remSleepMinutes: Int?
    let coreSleepMinutes: Int?
    let awakeMinutes: Int?

    // MARK: - Nocturnal HR dip (from session.nocturnalHRDip)
    //
    // Percentage drop from daytime resting HR to the median sleeping HR.
    // Healthy 10–20%; persistently low (<10%) suggests incomplete autonomic
    // recovery.
    let nocturnalDipPercent: Double?

    /// Mirrors `HRVSession.hrvDataQuality` into the lightweight index so the AI
    /// fact layer and the deterministic voice path can exclude untrustworthy
    /// readings (`.insufficient` / `.preSleep`) WITHOUT loading each session's
    /// RR file. Nil for legacy entries (back-fillable by re-archiving); nil is
    /// treated as reliable so legacy data is never wrongly hidden.
    let hrvDataQuality: HRVDataQuality?

    /// Mirrors `HRVSession.modifiedAt`, so an iCloud pull can tell whether a
    /// remote copy is newer than this device's without opening the file.
    let modifiedAt: Date?

    /// The date to display in history — prefers the actual sleep end so
    /// sessions whose recording ran long past wake (e.g. user forgot to
    /// stop) still show "wake time" in the row. Falls back to the recording
    /// end date, then the start date.
    var displayDate: Date {
        if sessionType == .overnight {
            if let sleepEnd { return sleepEnd }
            if let end = endDate { return end }
        }
        return date
    }

    /// Index-side mirror of `HRVSession.isReliableForHRVAggregates`, for
    /// aggregation paths that operate on `SessionArchiveEntry` (AI facts,
    /// voice intents) rather than full sessions.
    var isReliableForHRVAggregates: Bool {
        HRVDataQuality.allowsHRVAggregates(hrvDataQuality)
    }

    // spec:long-function A memberwise initializer is one assignment per stored
    // property and nothing else — no branches, no calls, no logic to extract.
    // Swift additionally forbids calling a helper on `self` before every stored
    // property is initialized, so the body cannot be split even mechanically.
    // Splitting the TYPE would be the real fix; that is tracked separately and
    // is not a formatting change.
    init(
        sessionId: UUID,
        date: Date,
        endDate: Date? = nil,
        fileHash: String,
        filePath: String,
        recoveryScore: Double? = nil,
        meanRMSSD: Double? = nil,
        meanHR: Double? = nil,
        stressIndex: Double? = nil,
        meanSDNN: Double? = nil,
        tags: [ReadingTag] = [],
        notes: String? = nil,
        sessionType: SessionType = .overnight,
        linkedSessionIds: [UUID]? = nil,
        sleepEnd: Date? = nil,
        sleepSegmentCount: Int? = nil,
        deepSleepMinutes: Int? = nil,
        remSleepMinutes: Int? = nil,
        coreSleepMinutes: Int? = nil,
        awakeMinutes: Int? = nil,
        nocturnalDipPercent: Double? = nil,
        hrvDataQuality: HRVDataQuality? = nil,
        modifiedAt: Date? = nil
    ) {
        self.sessionId = sessionId
        self.date = date
        self.endDate = endDate
        self.fileHash = fileHash
        self.filePath = filePath
        self.recoveryScore = recoveryScore
        self.meanRMSSD = meanRMSSD
        self.meanHR = meanHR
        self.stressIndex = stressIndex
        self.meanSDNN = meanSDNN
        self.tags = tags
        self.notes = notes
        self.sessionType = sessionType
        self.linkedSessionIds = linkedSessionIds
        self.deepSleepMinutes = deepSleepMinutes
        self.remSleepMinutes = remSleepMinutes
        self.coreSleepMinutes = coreSleepMinutes
        self.awakeMinutes = awakeMinutes
        self.nocturnalDipPercent = nocturnalDipPercent
        self.sleepEnd = sleepEnd
        self.sleepSegmentCount = sleepSegmentCount
        self.hrvDataQuality = hrvDataQuality
        self.modifiedAt = modifiedAt
    }

    // spec:long-function A Codable decoder cannot be decomposed in Swift:
    // every stored property must be initialized before any method on `self`
    // may be called, so a `private mutating func decodeX(...)` helper is
    // rejected outright, and `let` properties can only be assigned by `init`.
    // The alternatives are defaulting every property in its declaration (which
    // turns a missing assignment from a compile error into a silent nil) or
    // restructuring the on-disk JSON (a data migration, for a formatting rule).
    // Body is one assignment per field, in the same order as the encoder.
    /// Custom decoder to handle missing fields in old data.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceSchemaVersion = try Self.entrySchemaVersion(in: container)
        sessionId = try container.decode(UUID.self, forKey: .sessionId)
        date = try container.decode(Date.self, forKey: .date)
        endDate = try container.decodeIfPresent(Date.self, forKey: .endDate)
        fileHash = try container.decode(String.self, forKey: .fileHash)
        filePath = try container.decode(String.self, forKey: .filePath)
        recoveryScore = try container.decodeIfPresent(Double.self, forKey: .recoveryScore)
        meanRMSSD = try container.decodeIfPresent(Double.self, forKey: .meanRMSSD)
        meanHR = try container.decodeIfPresent(Double.self, forKey: .meanHR)
        stressIndex = try container.decodeIfPresent(Double.self, forKey: .stressIndex)
        meanSDNN = try container.decodeIfPresent(Double.self, forKey: .meanSDNN)
        tags = try container.decodeIfPresent([ReadingTag].self, forKey: .tags) ?? []
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        // Default to overnight for existing data that doesn't have sessionType
        sessionType = try container.decodeKnownIfPresent(SessionType.self, forKey: .sessionType, unknown: .quick) ?? .overnight
        linkedSessionIds = try container.decodeIfPresent([UUID].self, forKey: .linkedSessionIds)
        sleepEnd = try container.decodeIfPresent(Date.self, forKey: .sleepEnd)
        sleepSegmentCount = try container.decodeIfPresent(Int.self, forKey: .sleepSegmentCount)
        // Sleep stages + nocturnal dip — nil for legacy entries (back-fillable
        // by re-archiving any session whose snapshot has them).
        deepSleepMinutes = try container.decodeIfPresent(Int.self, forKey: .deepSleepMinutes)
        remSleepMinutes = try container.decodeIfPresent(Int.self, forKey: .remSleepMinutes)
        coreSleepMinutes = try container.decodeIfPresent(Int.self, forKey: .coreSleepMinutes)
        awakeMinutes = try container.decodeIfPresent(Int.self, forKey: .awakeMinutes)
        nocturnalDipPercent = try container.decodeIfPresent(Double.self, forKey: .nocturnalDipPercent)
        hrvDataQuality = try container.decodeKnownIfPresent(HRVDataQuality.self, forKey: .hrvDataQuality, unknown: .insufficient)
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt)
    }

    /// The entry's schema version (0 when absent in legacy data), or one
    /// newer than `currentSchemaVersion` when it holds a `SessionType` or
    /// `HRVDataQuality` case this build does not know: those read as
    /// `.quick` and `.insufficient`, and a re-save must not write that over
    /// the newer build's value.
    private static func entrySchemaVersion(in container: KeyedDecodingContainer<CodingKeys>) throws -> Int {
        let stated = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        let unknownCase = try container.holdsUnknownCase(SessionType.self, forKey: .sessionType)
            || container.holdsUnknownCase(HRVDataQuality.self, forKey: .hrvDataQuality)
        return unknownCase ? max(stated, currentSchemaVersion + 1) : stated
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try encodeIdentity(into: &container)
        try encodeMetrics(into: &container)
        try encodeSleepSummary(into: &container)
    }

    /// Schema, identity and where the session's file lives.
    private func encodeIdentity(into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(date, forKey: .date)
        try container.encodeIfPresent(endDate, forKey: .endDate)
        try container.encode(fileHash, forKey: .fileHash)
        try container.encode(filePath, forKey: .filePath)
    }

    /// The summary metrics History rows and charts read without
    /// deserializing the whole session.
    private func encodeMetrics(into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        try container.encodeIfPresent(recoveryScore, forKey: .recoveryScore)
        try container.encodeIfPresent(meanRMSSD, forKey: .meanRMSSD)
        try container.encodeIfPresent(meanHR, forKey: .meanHR)
        try container.encodeIfPresent(stressIndex, forKey: .stressIndex)
        try container.encodeIfPresent(meanSDNN, forKey: .meanSDNN)
        try container.encode(tags, forKey: .tags)
        try container.encodeIfPresent(notes, forKey: .notes)
    }

    /// Session type, links, and the per-stage sleep rollup.
    private func encodeSleepSummary(into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        try container.encode(sessionType, forKey: .sessionType)
        try container.encodeIfPresent(linkedSessionIds, forKey: .linkedSessionIds)
        try container.encodeIfPresent(sleepEnd, forKey: .sleepEnd)
        try container.encodeIfPresent(sleepSegmentCount, forKey: .sleepSegmentCount)
        try container.encodeIfPresent(deepSleepMinutes, forKey: .deepSleepMinutes)
        try container.encodeIfPresent(remSleepMinutes, forKey: .remSleepMinutes)
        try container.encodeIfPresent(coreSleepMinutes, forKey: .coreSleepMinutes)
        try container.encodeIfPresent(awakeMinutes, forKey: .awakeMinutes)
        try container.encodeIfPresent(nocturnalDipPercent, forKey: .nocturnalDipPercent)
        // Written so a pre-sleep or insufficient partial still reads back as
        // unreliable for HRV aggregates after the index is reloaded.
        try container.encodeIfPresent(hrvDataQuality, forKey: .hrvDataQuality)
        try container.encodeIfPresent(modifiedAt, forKey: .modifiedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sessionId, date, endDate, fileHash, filePath, recoveryScore, meanRMSSD, meanHR, stressIndex, meanSDNN, tags, notes, sessionType, linkedSessionIds
        case sleepEnd, sleepSegmentCount
        case deepSleepMinutes, remSleepMinutes, coreSleepMinutes, awakeMinutes
        case nocturnalDipPercent
        case hrvDataQuality
        case modifiedAt
    }
}
