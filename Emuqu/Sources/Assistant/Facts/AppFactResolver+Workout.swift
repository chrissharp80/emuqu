import CoreLocation
import CoreMotion
import Foundation
import os

// Split out from AppFactResolver.swift to keep the primary file
// under budget. Holds the workout.* namespace and
// workout.live.* namespace.

// MARK: - workout.* namespace
//
// Individual-workout lookups. The `session.*` namespace already exposes
// full session records; this namespace adds a few narrower convenience
// facts that the model commonly asks for without having to pull the full
// record and index into it.

struct WorkoutNamespace: FactNamespaceResolver {
    let namespace = "workout"
    let archive: SessionArchive

    func workoutEntries() -> [SessionArchiveEntry] {
        archive.entries
            .filter { $0.sessionType == .workout }
            .sorted { $0.date > $1.date }
    }

    func sessionByDate(_ iso: String) -> HRVSession? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        guard let target = formatter.date(from: iso) else { return nil }
        let cal = Calendar.current
        let day = cal.startOfDay(for: target)
        guard let next = cal.date(byAdding: .day, value: 1, to: day) else { return nil }
        let entry = workoutEntries().first { $0.date >= day && $0.date < next }
        return entry.flatMap { archive.retrieveLightweightOrLog($0.sessionId) }
    }

    func sessionByOrdinal(_ n: Int) -> HRVSession? {
        let entries = workoutEntries()
        guard n >= 0, n < entries.count else { return nil }
        return archive.retrieveLightweightOrLog(entries[n].sessionId)
    }

    func workoutAvailability() -> Availability {
        let entries = workoutEntries()
        guard !entries.isEmpty,
              let earliest = entries.map(\.date).min(),
              let latest = entries.map(\.date).max()
        else { return .unavailable }
        return Availability(hasData: true, validRange: earliest ... latest, lastUpdated: latest)
    }

    /// Cutoff date for a period token. Same vocabulary as
    /// `walks.list($period)` etc. so the AI doesn't have to learn two
    /// different period grammars.
    func cutoffForPeriod(_ raw: String) -> Date? {
        PeriodParser.cutoff(for: raw)
    }

    func entriesInPeriod(_ raw: String) -> [SessionArchiveEntry] {
        guard let cutoff = cutoffForPeriod(raw) else { return [] }
        return workoutEntries().filter { $0.date >= cutoff }
    }

    /// Single-call composite snapshot of a workout — TRIMP, hrTSS,
    /// decoupling, EF, IF, time-in-α1-regime per zone, AT1 crossing,
    /// dominant α1 band + HR zone, calories, calorie rate, VAM,
    /// grade-adjusted pace, relative-effort label, recognized route,
    /// elevation loss. Shared by `workout.most_recent.snapshot` and
    /// `workout.deep_dive.by_date($date)` so both return the same shape.
    static func deepDiveRecord(for session: HRVSession) -> FactValue {
        let meta = session.workoutMetadata
        var record: [String: FactValue] = [
            "session_id": .string(session.id.uuidString),
            "date": .from(session.startDate),
            "sport": .from(meta?.sport.displayName)
        ]
        record.merge(present(metadataFields(meta))) { current, _ in current }
        record.merge(present(snapshotFields(meta?.analysisSnapshot))) { current, _ in current }
        return .record(record)
    }

    /// Drop the absent entries. Every field in the two tables below is
    /// present-or-absent with no other logic, so a per-field `if let` would be
    /// forty branches expressing one rule. Stating the rule once keeps the
    /// tables lists, and a missing key still means "we do not have this"
    /// rather than a null the model has to interpret.
    private static func present(_ pairs: [(String, FactValue?)]) -> [String: FactValue] {
        var out: [String: FactValue] = [:]
        for (key, value) in pairs {
            out[key] = value
        }
        return out
    }

    /// Fields carried directly on the workout metadata.
    ///
    /// `partial_data_reason` maps the optional enum rather than its
    /// `?.rawValue`: that yields a non-optional String, and String is a
    /// Collection — so `.map` would map over its *characters* and hand back
    /// `[FactValue]`.
    ///
    /// Elevation loss is the one field with a real condition: zero is a
    /// measurement, not a descent, and reporting it invites the model to
    /// narrate a flat run as having lost no height.
    private static func metadataFields(_ meta: WorkoutMetadata?) -> [(String, FactValue?)] {
        [
            ("trimp", meta?.luciaTRIMP.map(FactValue.double)),
            ("hr_tss", meta?.hrTSS.map(FactValue.double)),
            ("decoupling_percent", meta?.decouplingPercent.map(FactValue.double)),
            ("efficiency_factor", meta?.efficiencyFactor.map(FactValue.double)),
            ("intensity_factor", meta?.intensityFactor.map(FactValue.double)),
            ("variability_index", meta?.variabilityIndex.map(FactValue.double)),
            ("recognized_route", meta?.recognizedRouteName.map(FactValue.string)),
            ("partial_data_reason", meta?.partialDataReason.map { FactValue.string($0.rawValue) }),
            ("elevation_loss_meters", meta?.elevationLossMeters.flatMap { $0 > 0 ? FactValue.double($0) : nil })
        ]
    }

    /// Fields derived at analysis time and frozen on the snapshot.
    private static func snapshotFields(_ snap: WorkoutAnalysisSnapshot?) -> [(String, FactValue?)] {
        [
            ("seconds_in_easy_α1", snap?.secondsBelowAT1.map(FactValue.integer)),
            ("seconds_in_threshold_α1", snap?.secondsBetweenAT1AT2.map(FactValue.integer)),
            ("seconds_in_hard_α1", snap?.secondsAboveAT2.map(FactValue.integer)),
            ("first_at1_crossing_offset_sec", snap?.firstAT1CrossingOffsetSec.map(FactValue.integer)),
            ("first_at1_crossing_hr", snap?.firstAT1CrossingHR.map(FactValue.integer)),
            ("dominant_α1_band", snap?.dominantAlpha1BandRaw.map(FactValue.string)),
            ("dominant_hr_zone", snap?.dominantHRZone.map(FactValue.integer)),
            ("estimated_total_calories", snap?.estimatedTotalCalories.map(FactValue.double)),
            ("calorie_rate_per_hour", snap?.calorieRatePerHour.map(FactValue.double)),
            ("vam_meters_per_hour", snap?.vamMetersPerHour.map(FactValue.double)),
            ("grade_adjusted_pace_sec_per_km", snap?.gradeAdjustedPaceSecPerKm.map(FactValue.double)),
            ("relative_effort_label", snap?.relativeEffortLabel.map(FactValue.string))
        ]
    }

    var entries: [FactEntry] {
        lookupEntries + detailEntries + timelineEntries
    }

    /// By-date and by-ordinal record lookups, plus the history list/count facts.
    private var lookupEntries: [FactEntry] {
        return [
            workoutByDateDateEntry,
            // ── Workout history (list / count / recent) ──────────────
            // **The biggest catalog gap before today.** Without these
            // the AI couldn't answer "what workouts did I do this week?"
            // or "how many workouts last month?" — only by-date /
            workoutListPeriodEntry,
            workoutCountPeriodEntry,
            workoutRecentPeriodEntry,
            workoutByOrdinalOrdinalEntry,
            workoutHrr1minDropByDateDateEntry,
            workoutHrr2minDropByDateDateEntry,
            workoutPowerAvgByDateDateEntry,
            workoutPowerNormalizedByDateDateEntry,
            workoutPowerPeakByDateDateEntry,
            workoutPowerTssByDateDateEntry,
            powerIntensityFactorByDateEntry,
            workoutPowerVariabilityByDateDateEntry
        ]
    }

    private var workoutByDateDateEntry: FactEntry {
        .parameterized(
            pattern: "workout.by_date($date)",
            paramExample: "2026-04-21",
            description: "Full workout record for a given date (yyyy-MM-dd, local). Includes sport, duration, avg/max HR, TRIMP, distance, calories, HRR, power, feeling.",
            availability: { self.workoutAvailability() },
            resolve: { param, tail in
                SessionNamespace.resolveSessionField(self.sessionByDate(param), tail: tail)
            }
        )
    }

    // by-ordinal lookups were available, forcing per-day calls.
    private var workoutListPeriodEntry: FactEntry {
        .parameterized(
            pattern: "workout.list($period)",
            paramExample: "last_7d",
            description: """
            List of ALL workouts in the period (any sport — walk, run, hike, bike, row, etc.). Each item is a session summary record with date, sport, duration, distance, TRIMP, hrTSS, avg/max HR, HRR drops if captured, route name if \
            recognized, feeling rating if logged. Period vocabulary: today / yesterday / last_7d / last_week / last_14d / last_30d / last_month / last_90d / last_year / all_time. Use this for 'what workouts did I do this week?' / 'show \
            me my recent activity' / 'list workouts since X'. Compare to walks.list which is walk-only.
            """,
            availability: { self.workoutAvailability() },
            resolve: { param, _ in
                let sessions = self.entriesInPeriod(param).compactMap { self.archive.retrieveLightweightOrLog($0.sessionId) }
                if sessions.isEmpty {
                    return .missing(reason: .notRecorded, detail: "no workouts in \(param)")
                }
                return .list(sessions.map { SessionNamespace.fullRecord(for: $0) })
            }
        )
    }

    private var workoutCountPeriodEntry: FactEntry {
        .parameterized(
            pattern: "workout.count($period)",
            paramExample: "last_7d",
            description: "How many workouts the user did in the period. Cheap; call this first when you only need a count or to gate a list call. Period vocabulary same as workout.list.",
            availability: { self.workoutAvailability() },
            resolve: { param, _ in
                .integer(self.entriesInPeriod(param).count)
            }
        )
    }

    private var workoutRecentPeriodEntry: FactEntry {
        .parameterized(
            pattern: "workout.recent($period)",
            paramExample: "last_30d",
            description: Self.workoutRecentPeriodDescription,
            availability: { self.workoutAvailability() },
            resolve: { param, _ in self.resolveWorkoutRecentPeriod(param) }
        )
    }

    private func resolveWorkoutRecentPeriod(_ param: String) -> FactValue {
        let sessions = self.entriesInPeriod(param).compactMap { self.archive.retrieveLightweightOrLog($0.sessionId) }
        if sessions.isEmpty {
            return .missing(reason: .notRecorded, detail: "no workouts in \(param)")
        }
        var record = periodTotals(param, sessions: sessions)
        record.merge(periodPowerTotals(sessions, period: param)) { _, new in new }
        record["sport_breakdown"] = .list(sportBreakdown(sessions))
        addHardestWorkout(&record, sessions: sessions)
        return .record(record)
    }

    private func periodTotals(_ param: String, sessions: [HRVSession]) -> [String: FactValue] {
        [
            "period": .string(param),
            "workout_count": .integer(sessions.count),
            "total_distance_m": .double(sessions.compactMap(\.workoutMetadata?.distanceMeters).reduce(0, +)),
            "total_trimp": .double(sessions.compactMap(\.workoutMetadata?.luciaTRIMP).reduce(0, +)),
            "total_hr_tss": .double(sessions.compactMap(\.workoutMetadata?.hrTSS).reduce(0, +))
        ]
    }

    // Power aggregates. Without them "how does this week's
    // power compare to last week's" answers "no data" even
    // when every workout has power-TSS / NP recorded, and
    // cloud providers calling this aggregate are forced into
    // a per-session loop via workout.list — most just give up.
    private func periodPowerTotals(_ sessions: [HRVSession], period param: String) -> [String: FactValue] {
        let powerTssValues = sessions.compactMap(\.workoutMetadata?.powerTSS)
        let totalPowerTss = powerTssValues.reduce(0, +)
        let npValues = sessions.compactMap(\.workoutMetadata?.normalizedPowerWatts)
        let avgNP: Double? = npValues.isEmpty ? nil : npValues.reduce(0, +) / Double(npValues.count)
        let ifValues = sessions.compactMap(\.workoutMetadata?.intensityFactor)
        let maxIF = ifValues.max()
        let peakPowerValues = sessions.compactMap(\.workoutMetadata?.peakPowerWatts)
        let maxPeakPower = peakPowerValues.max()
        let powerCapableCount = sessions.filter { ($0.workoutMetadata?.powerTSS ?? 0) > 0 || ($0.workoutMetadata?.normalizedPowerWatts ?? 0) > 0 }.count
        return [
            // Power aggregates. Each is nil-aware:
            // if NO session in the period had power, the field
            // is .missing so the AI doesn't fabricate a zero.
            "power_capable_workout_count": .integer(powerCapableCount),
            "total_power_tss": powerTssValues.isEmpty ? .missing(reason: .notRecorded, detail: "no power-capable workouts in \(param)") : .double(totalPowerTss),
            "avg_normalized_power_w": avgNP.map { .double($0) } ?? .missing(reason: .notRecorded, detail: "no NP captured in \(param)"),
            "max_intensity_factor": maxIF.map { .double($0) } ?? .missing(reason: .notRecorded, detail: "no IF captured in \(param)"),
            "max_peak_power_w": maxPeakPower.map { .integer($0) } ?? .missing(reason: .notRecorded, detail: "no peak power captured in \(param)")
        ]
    }

    private func sportBreakdown(_ sessions: [HRVSession]) -> [FactValue] {
        var sportCounts: [String: Int] = [:]
        for s in sessions {
            let sport = s.workoutMetadata?.sport.displayName ?? "(unknown)"
            sportCounts[sport, default: 0] += 1
        }
        return sportCounts
            .sorted { $0.value > $1.value }
            .map { .record(["sport": .string($0.key), "count": .integer($0.value)]) }
    }

    private func addHardestWorkout(_ record: inout [String: FactValue], sessions: [HRVSession]) {
        let hardest = sessions.max { ($0.workoutMetadata?.luciaTRIMP ?? 0) < ($1.workoutMetadata?.luciaTRIMP ?? 0) }
        guard let h = hardest else { return }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        record["hardest_workout"] = .record([
            "date": .string(f.string(from: h.startDate)),
            "sport": .from(h.workoutMetadata?.sport.displayName),
            "trimp": .from(h.workoutMetadata?.luciaTRIMP),
            "hr_tss": .from(h.workoutMetadata?.hrTSS),
            "distance_m": .from(h.workoutMetadata?.distanceMeters),
            // Power on the hardest workout
            // record, in case the AI follow-up question is
            // "what was the power on that one."
            "power_tss": .from(h.workoutMetadata?.powerTSS),
            "normalized_power_w": .from(h.workoutMetadata?.normalizedPowerWatts),
            "intensity_factor": .from(h.workoutMetadata?.intensityFactor)
        ])
    }

    private static let workoutRecentPeriodDescription = """
    Aggregate summary across the period: total workouts, total distance (m), total TRIMP, total hrTSS, total power-TSS, average normalized power (W), max intensity factor, max peak power (W), count of power-capable workouts, \
    sport breakdown (count per sport), hardest workout (highest TRIMP) with date + sport + power. Use this for 'how have I been training?' / 'show me my last month's training summary' / 'how does my power this week compare to \
    last week' — one tool call answers most weekly/monthly review questions including power.
    """

    private var workoutByOrdinalOrdinalEntry: FactEntry {
        .parameterized(
            pattern: "workout.by_ordinal($ordinal)",
            paramExample: "0",
            description: "Workout by recency index from the archive (0 = most recent, 1 = previous, …).",
            availability: { self.workoutAvailability() },
            resolve: { param, tail in
                guard let n = Int(param) else {
                    return .missing(reason: .invalidParameter, detail: "invalid ordinal '\(param)'")
                }
                return SessionNamespace.resolveSessionField(self.sessionByOrdinal(n), tail: tail)
            }
        )
    }

    private var workoutHrr1minDropByDateDateEntry: FactEntry {
        .parameterized(
            pattern: "workout.hrr_1min_drop.by_date($date)",
            paramExample: "2026-04-21",
            description: "1-minute heart rate recovery drop (bpm) for a workout on a given date. Best-of-provenance (strap > Watch > HealthKit).",
            availability: { self.workoutAvailability() },
            resolve: { param, _ in
                guard let session = self.sessionByDate(param) else {
                    return .missing(reason: .notRecorded, detail: "no workout on \(param)")
                }
                guard let drop = session.workoutMetadata?.hrrSamples?.bestAtOneMinute?.drop else {
                    return .missing(reason: .notRecorded, detail: "no 1-min HRR sample captured")
                }
                return .integer(drop)
            }
        )
    }

    private var workoutHrr2minDropByDateDateEntry: FactEntry {
        .parameterized(
            pattern: "workout.hrr_2min_drop.by_date($date)",
            paramExample: "2026-04-21",
            description: "2-minute heart rate recovery drop (bpm) for a workout on a given date.",
            availability: { self.workoutAvailability() },
            resolve: { param, _ in
                guard let session = self.sessionByDate(param) else {
                    return .missing(reason: .notRecorded, detail: "no workout on \(param)")
                }
                guard let drop = session.workoutMetadata?.hrrSamples?.bestAtTwoMinutes?.drop else {
                    return .missing(reason: .notRecorded, detail: "no 2-min HRR sample captured")
                }
                return .integer(drop)
            }
        )
    }

    private var workoutPowerAvgByDateDateEntry: FactEntry {
        .parameterized(
            pattern: "workout.power.avg.by_date($date)",
            paramExample: "2026-04-21",
            description: "Average power (watts) for a workout on a given date. Requires a connected power-capable foot pod.",
            availability: { self.workoutAvailability() },
            resolve: { param, _ in
                guard let session = self.sessionByDate(param) else {
                    return .missing(reason: .notRecorded, detail: "no workout on \(param)")
                }
                return .from(session.workoutMetadata?.averagePowerWatts, detail: "no power data captured")
            }
        )
    }

    private var workoutPowerNormalizedByDateDateEntry: FactEntry {
        .parameterized(
            pattern: "workout.power.normalized.by_date($date)",
            paramExample: "2026-04-21",
            description: "Normalized power (watts) for a workout on a given date — 4th-root-mean-4th-power smoothing, TrainingPeaks convention.",
            availability: { self.workoutAvailability() },
            resolve: { param, _ in
                guard let session = self.sessionByDate(param) else {
                    return .missing(reason: .notRecorded, detail: "no workout on \(param)")
                }
                return .from(session.workoutMetadata?.normalizedPowerWatts, detail: "no power data captured")
            }
        )
    }

    private var workoutPowerPeakByDateDateEntry: FactEntry {
        .parameterized(
            pattern: "workout.power.peak.by_date($date)",
            paramExample: "2026-04-21",
            description: "Peak instantaneous power (watts) observed during a workout on a given date.",
            availability: { self.workoutAvailability() },
            resolve: { param, _ in
                guard let session = self.sessionByDate(param) else {
                    return .missing(reason: .notRecorded, detail: "no workout on \(param)")
                }
                return .from(session.workoutMetadata?.peakPowerWatts, detail: "no power data captured")
            }
        )
    }

    private var workoutPowerTssByDateDateEntry: FactEntry {
        .parameterized(
            pattern: "workout.power.tss.by_date($date)",
            paramExample: "2026-04-21",
            description: "Power-based Training Stress Score for a workout on a given date. (NP/FTP)² × duration_hours × 100 — Coggan / TrainingPeaks definition. 100 = 1 hour at FTP. Requires the user to have set their FTP for the workout's sport.",
            availability: { self.workoutAvailability() },
            resolve: { param, _ in
                guard let session = self.sessionByDate(param) else {
                    return .missing(reason: .notRecorded, detail: "no workout on \(param)")
                }
                return .from(session.workoutMetadata?.powerTSS, detail: "FTP not set for this workout's sport — power-TSS skipped")
            }
        )
    }

    private var powerIntensityFactorByDateEntry: FactEntry {
        .parameterized(
            pattern: "workout.power.intensity_factor.by_date($date)",
            paramExample: "2026-04-21",
            description: "Intensity Factor (IF) for a workout on a given date. NP / FTP. 1.00 = at-threshold for the duration; > 1.05 sustained is unsustainable; < 0.75 is recovery / endurance pace.",
            availability: { self.workoutAvailability() },
            resolve: { param, _ in
                guard let session = self.sessionByDate(param) else {
                    return .missing(reason: .notRecorded, detail: "no workout on \(param)")
                }
                return .from(session.workoutMetadata?.intensityFactor, detail: "FTP not set for this workout's sport")
            }
        )
    }

    private var workoutPowerVariabilityByDateDateEntry: FactEntry {
        .parameterized(
            pattern: "workout.power.variability.by_date($date)",
            paramExample: "2026-04-21",
            description: "Variability Index (VI) for a workout on a given date. NP / Avg Power. ~1.00 = perfectly steady (TT, flat course); > 1.10 = real surges (intervals, rolling terrain). Tells the user whether their NP came from a steady push or from spikes.",
            availability: { self.workoutAvailability() },
            resolve: { param, _ in
                guard let session = self.sessionByDate(param) else {
                    return .missing(reason: .notRecorded, detail: "no workout on \(param)")
                }
                return .from(session.workoutMetadata?.variabilityIndex, detail: "no power data captured")
            }
        )
    }
}
