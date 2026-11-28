import Foundation

// `session.recent(period)`: every overnight recording in a period, the
// partial ones included, and the provenance fields of the overnight record
// (tags, notes, import source, strap, beat count). The per-night HRV, sleep
// and vitals lists keep only reliable nights, so a short or partial night
// is reachable only through this list.
extension SessionNamespace {
    /// The top-level fields of the overnight record `session.latest`,
    /// `session.by_date`, `session.by_ordinal` and `session.by_id` return.
    static let overnightFields: [String] = [
        "id", "session_type", "date", "end_date", "duration_sec", "mean_hr_bpm", "data_quality", "reliable_for_trends",
        "overnights_that_day", "tags", "notes", "import_source", "strap_model", "strap_firmware", "beat_count", "reconnect_count",
        "hrv", "recovery", "sleep", "vitals"
    ]

    static var overnightFieldsSentence: String {
        RecordFields.sentence(overnightFields)
            + " tags (the night's tag names), notes, import_source (the app a night was imported from, e.g. Elite HRV), strap_model, strap_firmware, beat_count (beats analysed) and reconnect_count"
            + " (strap reconnections) appear only when recorded. hrv (rmssd_ms, sdnn_ms, …), recovery (score 0–100, training_readiness, morning_feeling), sleep and vitals are nested records."
    }

    /// Where the night's data came from and what the user wrote on it; each
    /// only when stored.
    static func overnightProvenanceFields(_ session: HRVSession) -> [String: FactValue] {
        let summary = session.dataSourceSummary
        return present([
            ("tags", session.tags.isEmpty ? nil : .list(session.tags.map { .string($0.name) })),
            ("notes", nonEmpty(session.notes).map(FactValue.string)),
            ("import_source", session.importedMetrics.map { .string($0.source) }),
            ("strap_model", (session.deviceProvenance?.deviceModel ?? summary?.deviceModel).map(FactValue.string)),
            ("strap_firmware", nonEmpty(session.deviceProvenance?.firmwareVersion).map(FactValue.string)),
            ("beat_count", summary.map { .integer($0.totalBeats) }),
            ("reconnect_count", summary.map { .integer($0.reconnectCount) })
        ])
    }

    /// The fields whose value is present; a list of optional fields stays
    /// small when most are not stored.
    static func present(_ pairs: [(String, FactValue?)]) -> [String: FactValue] {
        var out: [String: FactValue] = [:]
        for (key, value) in pairs {
            if let value { out[key] = value }
        }
        return out
    }

    static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    // MARK: session.recent

    static let recentFields: [String] = [
        "id", "ordinal", "day", "date", "end_date", "duration_sec", "mean_hr_bpm", "data_quality", "reliable_for_trends",
        "overnights_that_day", "tags", "notes"
    ]

    var sessionRecentPeriodEntry: FactEntry {
        .parameterized(
            pattern: "session.recent($period)",
            paramExample: "last_30d",
            description: Self.sessionRecentDescription,
            availability: { self.overnightAvailability() },
            resolve: { param, _ in self.recentOvernights(param) }
        )
    }

    private static var sessionRecentDescription: String {
        """
        Every overnight recording in a period, newest night first, INCLUDING partial, short and unreliable recordings (reliable_for_trends false, data_quality preSleep or insufficient) that hrv.recent, sleep.recent and \
        vitals.recent leave out. Answers 'which nights did I record', 'list my nights this month', 'was there a partial night', 'how many nights did I record', 'which nights did I tag or write a note on'. One small item per \
        recording. \(RecordFields.sentence(recentFields)) day is the local day the night is filed under (pass it to session.by_date), ordinal is its session.by_ordinal index, id is for session.by_id; those return the full \
        night. tags and notes appear only when recorded. Periods: last_7d / last_14d / last_30d / last_90d / last_month / last_year / all_time.
        """
    }

    /// The overnights whose midpoint falls in the period (the day rule
    /// `session.by_date` files them by), in `session.by_ordinal` order.
    private func recentOvernights(_ period: String) -> FactValue {
        guard let interval = PeriodParser.interval(for: period) else { return PeriodParser.unknownPeriod(period) }
        let all = overnightEntries()
        let calendar = Calendar.current
        let perDay = Dictionary(grouping: all) { Self.day(of: $0, calendar: calendar) }.mapValues(\.count)
        let items = all.enumerated()
            .filter { interval.containsBeforeEnd(OvernightArchive.midpoint(of: $0.element)) }
            .map { Self.recentItem($0.element, ordinal: $0.offset, sameDay: perDay[Self.day(of: $0.element, calendar: calendar)] ?? 1) }
        guard !items.isEmpty else {
            return .missing(reason: .notRecorded, detail: "no overnight recordings in \(period)")
        }
        return .list(items)
    }

    /// One night from the archive index: no session file is read.
    private static func recentItem(_ entry: SessionArchiveEntry, ordinal: Int, sameDay: Int) -> FactValue {
        let fields: [String: FactValue] = [
            "id": .string(entry.sessionId.uuidString),
            "ordinal": .integer(ordinal),
            "day": .string(FactLocalDay.formatter().string(from: day(of: entry, calendar: .current))),
            "date": .date(entry.date),
            "duration_sec": .integer(Int(OvernightArchive.duration(of: entry))),
            "reliable_for_trends": .boolean(entry.isReliableForHRVAggregates),
            "overnights_that_day": .integer(sameDay)
        ]
        return .record(fields.merging(recentOptionalFields(entry)) { current, _ in current })
    }

    private static func recentOptionalFields(_ entry: SessionArchiveEntry) -> [String: FactValue] {
        present([
            ("end_date", entry.endDate.map(FactValue.date)),
            ("mean_hr_bpm", entry.meanHR.map { .integer(Int($0.rounded())) }),
            ("data_quality", entry.hrvDataQuality.map { .string($0.rawValue) }),
            ("tags", entry.tags.isEmpty ? nil : .list(entry.tags.map { .string($0.name) })),
            ("notes", nonEmpty(entry.notes).map(FactValue.string))
        ])
    }
}
