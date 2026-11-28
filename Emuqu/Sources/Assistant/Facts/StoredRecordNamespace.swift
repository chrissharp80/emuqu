import Foundation

// MARK: - stored.* namespace

/// Every stored session, of any kind, exactly as the app saved it: the
/// backstop behind the hand-built lookups. Those pick their fields; a field
/// nobody picked is still here, under its stored key
/// (`StoredSessionTree`), and so is any field added later.
///
/// Days follow the rules the other lookups use: an overnight, nap or quick
/// reading is filed under the local day its midpoint falls in (as
/// `hrv.by_date` files it), a workout under the day it started (as
/// `workout.by_date` does). Each record adds `date` (that day, yyyy-MM-dd)
/// and `session_type` beside the stored fields.
struct StoredRecordNamespace: FactNamespaceResolver {
    let namespace = "stored"
    let archive: SessionArchive

    var entries: [FactEntry] { [storedByDateEntry, storedByIdEntry, storedInPeriodEntry] }

    /// What every stored record holds and how the archive writes it. The
    /// scales are the stored ones; the named lookups convert some of them.
    static let storedRecordEncodingNote = """
        Every field the app saved for that session, under its stored camelCase key (startDate, endDate, sessionType, state, tags, notes, analysisResult, importedMetrics, deviceProvenance, dataSourceSummary, \
        sleepSnapshot, vitalsSnapshot, trainingSnapshot, scoreBreakdown, autoWindowResult, linkedSessionIds, morningFeelingTags, workoutMetadata and any other), plus date (the day it is filed under) and session_type. \
        Stored scales: recoveryScore, autoWindowScore and frozenReadiness are 0-10 (the app shows the recovery score as 0-100, so multiply by 10 as recovery.score.by_date does); analysisResult.ansMetrics.readinessScore is 1-10; \
        scoreBreakdown.compositeScore and each factor score are already 0-100, factor weight 0-1; perceivedReadiness is 0-1; morningFeeling and workoutMetadata.workoutFeeling are 1-5 (1 terrible, 5 great). \
        Fields ending in Ms are milliseconds from startDate; a workout's offsetSec and OffsetSec fields are seconds from its start, except hrrSamples, which count seconds after Stop. trainingSnapshot figures are on its loadScale (trimp or tss). \
        Dates are ISO 8601 in the user's time zone. Left out: the raw beats and per-second samples (hrv.timeline.by_date, workout.timeline.by_date), the GPS track, HealthKit offsets, the assistant's own context, and format and export bookkeeping.
        """

    private var storedByDateEntry: FactEntry {
        .parameterized(
            pattern: "stored.by_date($date)",
            paramExample: "2026-04-21",
            description: """
            The full stored record of every session filed under a local date (yyyy-MM-dd), any kind: overnight, nap, quick, breathe or workout, in the order recorded. Add a kind after a comma to keep one kind \
            ('2026-04-21,workout'). Use it when no other lookup has the field you need, or to check a value against what was saved. \(Self.storedRecordEncodingNote)
            """,
            availability: { self.storedAvailability() },
            resolve: { param, _ in self.storedRecordsOnDay(param) }
        )
    }

    private var storedByIdEntry: FactEntry {
        .parameterized(
            pattern: "stored.by_id($id)",
            paramExample: "A43B2C4F-0000-4000-8000-000000000000",
            description: """
            The full stored record of one session by its UUID, any kind (the id any other lookup gives). Tail tokens walk into it by stored key, e.g. stored.by_id(<uuid>).sleepSnapshot. \
            \(Self.storedRecordEncodingNote)
            """,
            availability: { self.storedAvailability() },
            resolve: { param, tail in SessionNamespace.field(of: self.storedRecord(id: param), tail: tail) }
        )
    }

    private var storedInPeriodEntry: FactEntry {
        .parameterized(
            pattern: "stored.in_period($period)",
            paramExample: "last_7d",
            description: """
            The full stored record of every session in a period, newest first, any kind; add a kind after a comma ('last_30d,nap'). Periods as every other lookup takes them: 7d, last_month, all_time, 2026, 2026-02, \
            2026-02-01..2026-02-28, since_2026-02-01. A long period comes back cut to the newest records that fit, with truncated and omitted_count saying so; pass fields or a shorter period for the rest. \
            \(Self.storedRecordEncodingNote)
            """,
            availability: { self.storedAvailability() },
            resolve: { param, _ in self.storedRecordsInPeriod(param) }
        )
    }

    // MARK: Selection

    /// Metadata-only: whether the archive holds any session, and their span.
    private func storedAvailability() -> Availability {
        let dates = archive.store.entries.map(\.date)
        guard let earliest = dates.min(), let latest = dates.max() else { return .unavailable }
        return Availability(hasData: true, validRange: earliest ... latest, lastUpdated: latest)
    }

    /// The moment a session is filed by: an HRV reading's midpoint, a
    /// workout's start.
    static func storedFilingMoment(of entry: SessionArchiveEntry) -> Date {
        entry.sessionType == .workout ? entry.date : OvernightArchive.midpoint(of: entry)
    }

    private func storedRecordsOnDay(_ param: String) -> FactValue {
        let parsed = Self.storedSelectorAndKind(param)
        if let failure = parsed.failure { return failure }
        guard let target = FactLocalDay.formatter().date(from: parsed.selector) else {
            return .missing(reason: .invalidParameter, detail: "expected yyyy-MM-dd, got '\(parsed.selector)'")
        }
        let calendar = Calendar.current
        let matched = storedEntries(kind: parsed.kind)
            .filter { entry in calendar.isDate(Self.storedFilingMoment(of: entry), inSameDayAs: target) }
            .sorted { lhs, rhs in lhs.date < rhs.date }
        return storedList(matched, empty: "no stored session on \(parsed.selector)")
    }

    private func storedRecordsInPeriod(_ param: String) -> FactValue {
        let parsed = Self.storedSelectorAndKind(param)
        if let failure = parsed.failure { return failure }
        guard let interval = PeriodParser.interval(for: parsed.selector) else { return PeriodParser.unknownPeriod(parsed.selector) }
        let matched = storedEntries(kind: parsed.kind)
            .filter { entry in interval.containsBeforeEnd(Self.storedFilingMoment(of: entry)) }
            .sorted { lhs, rhs in lhs.date > rhs.date }
        return storedList(matched, empty: "no stored session in \(parsed.selector)")
    }

    /// Every archived session, or only those of `kind`.
    private func storedEntries(kind: SessionType?) -> [SessionArchiveEntry] {
        archive.store.entries.filter { entry in kind == nil || entry.sessionType == kind }
    }

    private func storedRecord(id idString: String) -> FactValue {
        guard let uuid = UUID(uuidString: idString.trimmingCharacters(in: .whitespaces)) else {
            return .missing(reason: .invalidParameter, detail: "expected a session UUID, got '\(idString)'")
        }
        guard let entry = archive.store.entries.first(where: { $0.sessionId == uuid }) else {
            return .missing(reason: .notRecorded, detail: "no stored session with id \(idString)")
        }
        return storedRecord(for: entry)
    }

    private func storedList(_ matched: [SessionArchiveEntry], empty: String) -> FactValue {
        let records = matched.map(storedRecord(for:)).filter { !$0.isMissing }
        guard !records.isEmpty else {
            return matched.isEmpty ? .missing(reason: .notRecorded, detail: empty) : .missing(reason: .unreadable, detail: "the stored sessions could not be read just now")
        }
        return .list(records)
    }

    /// One session's stored tree with its filing day and kind beside it.
    private func storedRecord(for entry: SessionArchiveEntry) -> FactValue {
        guard let session = archive.retrieveLightweightOrLog(entry.sessionId) else {
            return .missing(reason: .unreadable, detail: "the stored session could not be read just now")
        }
        guard case var .record(fields) = StoredSessionTree.storedRecordTree(of: session) else {
            return .missing(reason: .internalError, detail: "the stored session could not be read")
        }
        fields["date"] = .string(FactLocalDay.formatter().string(from: Self.storedFilingMoment(of: entry)))
        fields["session_type"] = .string(session.sessionType.rawValue)
        return .record(fields)
    }

    /// A day or period, optionally followed by a comma and a session kind:
    /// the two apart. An unknown kind is the caller's error.
    static func storedSelectorAndKind(_ param: String) -> (selector: String, kind: SessionType?, failure: FactValue?) {
        let parts = param.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let selector = parts.first ?? ""
        guard parts.count > 1, !parts[1].isEmpty else { return (selector, nil, nil) }
        guard let kind = SessionType(rawValue: parts[1].lowercased()) else {
            let kinds = SessionType.allCases.map(\.rawValue).joined(separator: ", ")
            return (selector, nil, .missing(reason: .invalidParameter, detail: "unknown kind '\(parts[1])'; use one of \(kinds)"))
        }
        return (selector, kind, nil)
    }
}
