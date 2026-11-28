import Foundation

// One rule for which workout a single-workout lookup reads (`WorkoutSelector`)
// and for the same-day fields every such record carries, so a day with a run
// and a walk answers "my run" and says the walk is there too.

extension WorkoutNamespace {
    /// Runs `body` on the workout `param` selects, or answers why none is.
    func withWorkout(_ param: String, _ body: (HRVSession) -> FactValue) -> FactValue {
        switch pickWorkout(param) {
        case let .picked(session): body(session)
        case let .notPicked(reply): reply
        }
    }

    func pickWorkout(_ param: String) -> WorkoutPick {
        let selector: WorkoutSelector
        do throws(FactArgumentError) {
            selector = try WorkoutSelector.parseSelector(param)
        } catch {
            return .notPicked(error.factValue)
        }
        switch selector.target {
        case let .workoutID(uuid): return pickByID(uuid)
        case let .localDay(iso): return pickOnDay(iso, selector: selector)
        }
    }

    /// A workout UUID; an overnight's or a reading's id is the wrong tool.
    private func pickByID(_ uuid: UUID) -> WorkoutPick {
        guard let entry = archive.store.entries.first(where: { $0.sessionId == uuid }) else {
            return .notPicked(.missing(reason: .notRecorded, detail: "no workout with id \(uuid.uuidString)"))
        }
        guard entry.sessionType == .workout else {
            let detail = "\(uuid.uuidString) is a \(entry.sessionType.rawValue) session, not a workout; get_session reads overnights"
            return .notPicked(.missing(reason: .invalidParameter, detail: detail))
        }
        return load(entry)
    }

    private func load(_ entry: SessionArchiveEntry) -> WorkoutPick {
        guard let session = archive.retrieveLightweightOrLog(entry.sessionId) else {
            let detail = "the workout \(entry.sessionId.uuidString) is in the archive index but couldn't be read"
            return .notPicked(.missing(reason: .internalError, detail: detail))
        }
        return .picked(session)
    }

    /// The day's latest workout, or the one the sport and position name.
    private func pickOnDay(_ iso: String, selector: WorkoutSelector) -> WorkoutPick {
        let day = entriesOnDay(iso)
        guard !day.isEmpty else { return .notPicked(.missing(reason: .notRecorded, detail: "no workout on \(iso)")) }
        guard let sport = selector.sport else {
            guard let entry = Self.chosen(day, position: selector.position) else {
                return .notPicked(.missing(reason: .notRecorded, detail: "only \(day.count) workout(s) on \(iso)"))
            }
            return load(entry)
        }
        let sessions = day.compactMap { archive.retrieveLightweightOrLog($0.sessionId) }
        let matching = sessions.filter { $0.workoutMetadata?.sport == sport }
        guard let session = Self.chosen(matching, position: selector.position) else {
            return .notPicked(Self.noSportMatch(sport, on: iso, matching: matching.count, read: sessions, indexed: day.count))
        }
        return .picked(session)
    }

    /// The last item when no position is named, else the position-th (1-based).
    private static func chosen<T>(_ items: [T], position: Int?) -> T? {
        guard let position else { return items.last }
        return items.indices.contains(position - 1) ? items[position - 1] : nil
    }

    /// Why no workout of `sport` answers: none of that sport that day (the
    /// day's others named, so the model can pick one), or some unreadable.
    private static func noSportMatch(_ sport: Sport, on iso: String, matching: Int, read: [HRVSession], indexed: Int) -> FactValue {
        if matching > 0 {
            return .missing(reason: .notRecorded, detail: "only \(matching) \(sport.rawValue) workout(s) on \(iso)")
        }
        if read.count < indexed {
            return .missing(reason: .internalError, detail: "\(indexed - read.count) workout(s) on \(iso) are in the archive index but couldn't be read")
        }
        let others = read.map { "\($0.workoutMetadata?.sport.rawValue ?? "unknown") (id \($0.id.uuidString))" }
        return .missing(reason: .notRecorded, detail: "no \(sport.rawValue) on \(iso); workouts that day: \(others.joined(separator: ", "))")
    }

    /// The day's workouts in start order, oldest first.
    func entriesOnDay(_ iso: String) -> [SessionArchiveEntry] {
        guard let target = FactLocalDay.formatter().date(from: iso) else { return [] }
        let cal = Calendar.current
        return workoutEntries().filter { cal.isDate($0.date, inSameDayAs: target) }.reversed()
    }

    // MARK: - Same-day fields

    /// Every workout grouped by its local start day, oldest first within a
    /// day. Built once per lookup so a period list doesn't rescan per item.
    func workoutsByDay() -> [Date: [SessionArchiveEntry]] {
        let cal = Calendar.current
        return Dictionary(grouping: workoutEntries().reversed()) { cal.startOfDay(for: $0.date) }
    }

    /// `workouts_that_day`, `position_that_day` (1 = first started) and the
    /// ids of the day's other workouts, which `workout.by_id` reads.
    func sameDayFields(for session: HRVSession, days: [Date: [SessionArchiveEntry]]) -> [String: FactValue] {
        let day = days[Calendar.current.startOfDay(for: session.startDate)] ?? []
        let others = day.filter { $0.sessionId != session.id }.map { FactValue.string($0.sessionId.uuidString) }
        var fields: [String: FactValue] = [
            "workouts_that_day": .integer(max(day.count, 1)),
            "other_workout_ids_that_day": .list(others)
        ]
        if let index = day.firstIndex(where: { $0.sessionId == session.id }) {
            fields["position_that_day"] = .integer(index + 1)
        }
        return fields
    }

    /// `value` with the same-day fields added, when it is a record.
    func withSameDay(_ value: FactValue, for session: HRVSession, days: [Date: [SessionArchiveEntry]]? = nil) -> FactValue {
        guard case var .record(fields) = value else { return value }
        fields.merge(sameDayFields(for: session, days: days ?? workoutsByDay())) { current, _ in current }
        return .record(fields)
    }

    /// A workout.list item: the record without its splits and laps;
    /// split_count and lap_count still say how many there are.
    func workoutListItem(for session: HRVSession, days: [Date: [SessionArchiveEntry]]) -> FactValue {
        let whole = workoutRecord(for: session, days: days)
        guard case let .record(fields) = whole else { return whole }
        return .record(fields.filter { !WorkoutRecordFields.listLeavesOut.contains($0.key) })
    }

    /// The full workout record plus the same-day fields.
    func workoutRecord(for session: HRVSession, days: [Date: [SessionArchiveEntry]]? = nil) -> FactValue {
        withSameDay(SessionNamespace.fullRecord(for: session, ftp: loadAnchors), for: session, days: days)
    }
}

// MARK: - Period lists with a sport

extension WorkoutNamespace {
    /// Runs `body` on the period's workouts (of the sport, when named), or
    /// answers why there are none.
    func withWorkoutsInPeriod(_ raw: String, _ body: (WorkoutPeriodFilter, [HRVSession]) -> FactValue) -> FactValue {
        let filter: WorkoutPeriodFilter
        do throws(FactArgumentError) {
            filter = try WorkoutPeriodFilter.parsePeriodFilter(raw)
        } catch {
            return error.factValue
        }
        let sessions = entriesInPeriod(filter.period).compactMap { archive.retrieveLightweightOrLog($0.sessionId) }.filter(filter.keeps)
        guard !sessions.isEmpty else { return .missing(reason: .notRecorded, detail: "no workouts in \(raw)") }
        return body(filter, sessions)
    }

    /// How many workouts in the period: from the index alone unless a sport
    /// is named, which needs each workout's sport.
    func workoutCount(_ raw: String) -> FactValue {
        let filter: WorkoutPeriodFilter
        do throws(FactArgumentError) {
            filter = try WorkoutPeriodFilter.parsePeriodFilter(raw)
        } catch {
            return error.factValue
        }
        let entries = entriesInPeriod(filter.period)
        guard filter.sport != nil else { return .integer(entries.count) }
        return .integer(entries.compactMap { archive.retrieveLightweightOrLog($0.sessionId) }.filter(filter.keeps).count)
    }
}
