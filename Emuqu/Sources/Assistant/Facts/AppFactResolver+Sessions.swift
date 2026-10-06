import Foundation

// The session, walks, training-load and heat namespaces, split out of
// `AppFactResolver.swift` at a top-level type boundary. The period
// parser, the factory, and the user/app namespaces stay behind.

// MARK: - session.* namespace

/// One recorded overnight session as a single record: identity and timing,
/// the HRV analysis, the recovery score, sleep and vitals. Overnights only;
/// workouts are `workout.*`, and naps and quick readings come through
/// `hrv.*` / `sleep.*`, which label them by `session_type`.
///
/// Days follow the midpoint rule `hrv.by_date`, `sleep.by_date` and
/// `recovery.score.by_date` use, so `session.by_date(D)` is the same night
/// those return for D. Within a day the main recording comes first: a
/// reliable recording before a partial one, then the longest.
struct SessionNamespace: FactNamespaceResolver {
    let namespace = "session"
    let archive: SessionArchive
    let settings: @Sendable () -> UserSettings

    /// Metadata-only: whether any overnight exists, and the range of their
    /// start dates. Reads the in-memory archive index — no disk I/O, no
    /// HealthKit call — which satisfies the synchronous, metadata-only
    /// `availability` contract.
    private func overnightAvailability() -> Availability {
        let dates = archive.entries.filter { $0.sessionType == .overnight }.map(\.date)
        guard let earliest = dates.min(), let latest = dates.max() else { return .unavailable }
        return Availability(hasData: true, validRange: earliest ... latest, lastUpdated: latest)
    }

    /// Every overnight: newest local day first, and within a day reliable
    /// before partial, then longest first.
    private func overnightEntries() -> [SessionArchiveEntry] {
        let calendar = Calendar.current
        return archive.entries
            .filter { $0.sessionType == .overnight }
            .sorted { Self.precedes($0, $1, calendar: calendar) }
    }

    private static func precedes(_ lhs: SessionArchiveEntry, _ rhs: SessionArchiveEntry, calendar: Calendar) -> Bool {
        let lhsDay = day(of: lhs, calendar: calendar)
        let rhsDay = day(of: rhs, calendar: calendar)
        if lhsDay != rhsDay { return lhsDay > rhsDay }
        if lhs.isReliableForHRVAggregates != rhs.isReliableForHRVAggregates { return lhs.isReliableForHRVAggregates }
        return OvernightArchive.duration(of: lhs) > OvernightArchive.duration(of: rhs)
    }

    private static func day(of entry: SessionArchiveEntry, calendar: Calendar) -> Date {
        calendar.startOfDay(for: OvernightArchive.midpoint(of: entry))
    }

    /// The newest reliable overnight — the night `hrv.latest` and
    /// `sleep.latest` report — or the newest overnight of any quality when
    /// none is reliable.
    private func latestEntry() -> SessionArchiveEntry? {
        let entries = overnightEntries()
        return entries.first { $0.isReliableForHRVAggregates } ?? entries.first
    }

    private func entry(atOrdinal n: Int) -> SessionArchiveEntry? {
        let entries = overnightEntries()
        return entries.indices.contains(n) ? entries[n] : nil
    }

    /// The main overnight filed under that local day.
    private func entry(onDate iso: String) -> SessionArchiveEntry? {
        guard let target = FactLocalDay.formatter().date(from: iso) else { return nil }
        let calendar = Calendar.current
        return overnightEntries().first { calendar.isDate(Self.day(of: $0, calendar: calendar), inSameDayAs: target) }
    }

    var entries: [FactEntry] {
        return [
            sessionLatestEntry,
            sessionLatestIdEntry,
            sessionLatestDateEntry,
            sessionByOrdinalNEntry,
            sessionByIdIdEntry,
            sessionByDateDateEntry
        ]
    }

    // --- latest convenience ---
    private var sessionLatestEntry: FactEntry {
        .fixed(
            key: "session.latest",
            description: """
            The latest overnight session as one record — the newest reliable night, the one hrv.latest and sleep.latest report (a partial recording only when no night is reliable). Fields: id, date, end_date, duration_sec, mean_hr_bpm, data_quality, \
            reliable_for_trends, overnights_that_day, plus nested hrv (rmssd_ms, sdnn_ms, …), recovery (score 0–100, training_readiness, morning_feeling), sleep and vitals records.
            """,
            valueType: "Record",
            availability: { self.overnightAvailability() },
            resolve: { self.record(for: self.latestEntry()) }
        )
    }

    private var sessionLatestIdEntry: FactEntry {
        .fixed(
            key: "session.latest.id",
            description: "UUID of the latest overnight session (the one session.latest returns).",
            valueType: "String",
            availability: { self.overnightAvailability() },
            resolve: { .from(self.latestEntry()?.sessionId.uuidString) }
        )
    }

    private var sessionLatestDateEntry: FactEntry {
        .fixed(
            key: "session.latest.date",
            description: "Start date of the latest overnight session (the one session.latest returns).",
            valueType: "Date",
            availability: { self.overnightAvailability() },
            resolve: { .from(self.latestEntry()?.date) }
        )
    }

    // --- parameterized: session.by_ordinal(N).* ---
    private var sessionByOrdinalNEntry: FactEntry {
        .parameterized(
            pattern: "session.by_ordinal($n)",
            paramExample: "0",
            description: """
            An overnight session by recency (0 = newest night, 1 = the one before, …), including partial recordings, which come after the night's main recording. Same record as session.latest; tail tokens reach any field, e.g. \
            session.by_ordinal(2).hrv.rmssd_ms.
            """,
            availability: { self.overnightAvailability() },
            resolve: { param, tail in
                do throws(FactArgumentError) {
                    let n = try FactNumericArgument.ordinal.integer(param)
                    return Self.field(of: self.record(for: self.entry(atOrdinal: n)), tail: tail)
                } catch {
                    return error.factValue
                }
            }
        )
    }

    private var sessionByIdIdEntry: FactEntry {
        .parameterized(
            pattern: "session.by_id($id)",
            paramExample: "A43B2C4F-0000-4000-8000-000000000000",
            description: "An overnight session by UUID. A workout, nap or quick-reading UUID is rejected with the tool to use instead. Tail tokens reach any field.",
            availability: { self.overnightAvailability() },
            resolve: { param, tail in self.resolveByID(param, tail: tail) }
        )
    }

    private var sessionByDateDateEntry: FactEntry {
        .parameterized(
            pattern: "session.by_date($date)",
            paramExample: "2026-04-21",
            description: """
            The overnight session filed under a local date (yyyy-MM-dd): the night whose midpoint falls on that day, so '2026-04-21' is the night ending that morning — the same night hrv.by_date and sleep.by_date return. \
            When overnights_that_day is above 1, the others are reachable through session.by_ordinal.
            """,
            availability: { self.overnightAvailability() },
            resolve: { param, tail in
                Self.field(of: self.record(for: self.entry(onDate: param)), tail: tail)
            }
        )
    }

    /// Only an overnight's UUID resolves; any other session type names the
    /// lookup that does cover it rather than returning a record of the wrong
    /// shape.
    private func resolveByID(_ idString: String, tail: FactKey?) -> FactValue {
        guard let uuid = UUID(uuidString: idString) else {
            return .missing(reason: .invalidParameter, detail: "expected a session UUID, got '\(idString)'")
        }
        guard let entry = archive.entries.first(where: { $0.sessionId == uuid }) else {
            return .missing(reason: .notRecorded, detail: "session not found")
        }
        guard entry.sessionType == .overnight else {
            return .missing(reason: .invalidParameter, detail: Self.wrongTypeDetail(idString, entry: entry))
        }
        return Self.field(of: record(for: entry), tail: tail)
    }

    private static func wrongTypeDetail(_ idString: String, entry: SessionArchiveEntry) -> String {
        let day = FactLocalDay.formatter().string(from: entry.date)
        let instead = entry.sessionType == .workout
            ? "get_workout with which='by_date', date='\(day)' (workout.by_date(\(day)))"
            : "get_hrv with which='recent' (hrv.recent), whose items carry session_type"
        return "\(idString) is a \(entry.sessionType.rawValue) session; get_session (session.*) reads overnights only — use \(instead)"
    }

    // MARK: Overnight record

    /// The night as one record. The nested records are the ones the
    /// `hrv.*`, `recovery.*`, `sleep.*` and `vitals.*` facts return for this
    /// same session, so the two routes cannot disagree.
    private func record(for entry: SessionArchiveEntry?) -> FactValue {
        guard let entry, let session = archive.retrieveLightweightOrLog(entry.sessionId) else {
            return .missing(reason: .notRecorded, detail: "no overnight session matched")
        }
        let cfg = settings()
        var fields = Self.overnightIdentityFields(session)
        fields["overnights_that_day"] = .integer(overnightsSharingDay(with: entry))
        fields["hrv"] = HRVNamespace.hrvRecord(for: session)
        fields["recovery"] = RecoveryNamespace.scoreRecord(for: session)
        fields["sleep"] = SleepNamespace.sleepRecord(for: session, userAge: cfg.age, typicalSleepHours: cfg.typicalSleepHours)
        fields["vitals"] = VitalsNamespace.vitalsRecord(for: session)
        return .record(fields)
    }

    private static func overnightIdentityFields(_ session: HRVSession) -> [String: FactValue] {
        [
            "id": .string(session.id.uuidString),
            "session_type": .string(session.sessionType.rawValue),
            "date": .date(session.startDate),
            "end_date": .from(session.endDate),
            "duration_sec": .from(session.duration.map { Int($0) }),
            "mean_hr_bpm": .from(session.meanHR.map { Int($0) }),
            "data_quality": .from(session.hrvDataQuality?.rawValue),
            "reliable_for_trends": .boolean(session.isReliableForHRVAggregates)
        ]
    }

    private func overnightsSharingDay(with entry: SessionArchiveEntry) -> Int {
        let calendar = Calendar.current
        let day = Self.day(of: entry, calendar: calendar)
        return overnightEntries().filter { Self.day(of: $0, calendar: calendar) == day }.count
    }

    /// Walks `tail` down `record`, one field per step; with no tail, the whole
    /// record. Shared by the overnight record here and the workout record
    /// below.
    static func field(of record: FactValue, tail: FactKey?) -> FactValue {
        guard let tail, case .record = record else { return record }
        let tokens = tail.tokens
        var cursor = record
        var index = 0
        while index < tokens.count {
            guard case .record(let dict) = cursor else {
                return .missing(reason: .invalidParameter, detail: "cannot descend into non-record at '\(tokens[index].rendered)'")
            }
            guard let step = fieldStep(dict, tokens: tokens, at: index) else {
                return .missing(reason: .invalidParameter, detail: "no field '\(tokens[index].rendered)' on session record")
            }
            cursor = step.value
            index += step.tokensUsed
        }
        return cursor
    }
}

// MARK: - Workout record

/// The workout record `workout.*` and `walks.*` return. It lives with the
/// session namespace because both walk a key tail the same way
/// (`SessionNamespace.field(of:tail:)`).
extension SessionNamespace {
    /// Full record for a workout — every persisted field the analysis
    /// snapshot captures, plus the core identity / timing fields. This is
    /// what the AI sees for `workout.by_date(X)`, `workout.list(P)` or
    /// `walks.hardest(P)` without a tail.
    static func fullRecord(for s: HRVSession?) -> FactValue {
        guard let s else { return .missing(reason: .notRecorded, detail: "session not found") }
        let meta = s.workoutMetadata
        var record = identityFields(s, meta: meta)
        record.merge(loadFields(meta)) { current, _ in current }
        record.merge(analysisSnapshotFields(meta?.analysisSnapshot)) { current, _ in current }
        record.merge(hrrFields(meta?.hrrSamples)) { current, _ in current }
        return .record(record)
    }

    /// Identity, timing, and the shape of the effort.
    private static func identityFields(_ s: HRVSession, meta: WorkoutMetadata?) -> [String: FactValue] {
        [
            "id": .string(s.id.uuidString),
            "date": .date(s.startDate),
            "sport": .from(meta?.sport.displayName),
            "duration_sec": .from(s.duration.map { Int($0) }),
            "distance_m": .from(meta?.distanceMeters),
            "elevation_gain_m": .from(meta?.elevationGainMeters),
            "elevation_loss_m": .from(meta?.elevationLossMeters),
            "mean_hr_bpm": .from(s.meanHR.map { Int($0) }),
            "max_hr_bpm": .from(meta?.samples?.compactMap(\.heartRate).max()),
            "recognized_route": .from(meta?.recognizedRouteName),
            "workout_feeling": .from(meta?.workoutFeeling),
            "workout_feeling_note": .from(meta?.workoutFeelingNote)
        ]
    }

    /// `load` is the preferred (power-first) number
    /// the AI should anchor on. `trimp` and `hr_tss` stay exposed
    /// for back-compat / debugging, but `load` + `load_source`
    /// is the canonical pair. `preferredTrainingLoad` is
    /// MainActor-isolated (touches Settings + auto-FTP cache),
    /// so it's wrapped in `assumeIsolated` — the same pattern used
    /// elsewhere in this resolver for MainActor-isolated reads.
    private static func loadFields(_ meta: WorkoutMetadata?) -> [String: FactValue] {
        [
            "load": .from(MainActor.assumeIsolated { meta?.preferredTrainingLoad?.value }),
            "load_source": .from(MainActor.assumeIsolated { meta?.preferredTrainingLoad?.source.rawValue }),
            "trimp": .from(meta?.luciaTRIMP),
            "hr_tss": .from(meta?.hrTSS),
            "power_tss": .from(meta?.powerTSS),
            "decoupling_percent": .from(meta?.decouplingPercent),
            "efficiency_factor": .from(meta?.efficiencyFactor),
            "average_power_w": .from(meta?.averagePowerWatts),
            "normalized_power_w": .from(meta?.normalizedPowerWatts),
            "peak_power_w": .from(meta?.peakPowerWatts.map(Double.init))
        ]
    }

    /// α1 / zones / splits pulled from the persisted analysis snapshot.
    private static func analysisSnapshotFields(_ snap: WorkoutAnalysisSnapshot?) -> [String: FactValue] {
        guard let snap else { return [:] }
        return [
            "alpha1_mean": .from(snap.alpha1Mean), "alpha1_max": .from(snap.alpha1Max),
            "alpha1_min": .from(snap.alpha1Min),
            "seconds_below_at1": .from(snap.secondsBelowAT1),
            "seconds_between_at1_at2": .from(snap.secondsBetweenAT1AT2),
            "seconds_above_at2": .from(snap.secondsAboveAT2),
            "first_at1_crossing_offset_sec": .from(snap.firstAT1CrossingOffsetSec),
            "first_at1_crossing_hr": .from(snap.firstAT1CrossingHR), "dominant_alpha1_band": .from(snap.dominantAlpha1BandRaw),
            "dominant_hr_zone": .from(snap.dominantHRZone),
            "dominant_hr_zone_percent": .from(snap.dominantHRZonePercent),
            "fastest_split_index": .from(snap.fastestSplitIndex),
            "fastest_split_pace_sec_per_km": .from(snap.fastestSplitPaceSecPerKm),
            "vam_m_per_hr": .from(snap.vamMetersPerHour),
            "calorie_rate_per_hr": .from(snap.calorieRatePerHour),
            "estimated_total_calories": .from(snap.estimatedTotalCalories),
            "stride_length_m": .from(snap.strideLengthMeters),
            "grade_adjusted_pace_sec_per_km": .from(snap.gradeAdjustedPaceSecPerKm),
            "how_you_did_narrative": .from(snap.howYouDidNarrative)
        ]
    }

    /// Heart-rate recovery drops, with provenance on the 1-minute reading.
    private static func hrrFields(_ hrr: [HRRSample]?) -> [String: FactValue] {
        var out: [String: FactValue] = [:]
        if let one = hrr?.bestAtOneMinute {
            out["hrr_1min_drop_bpm"] = .integer(one.drop)
            out["hrr_1min_source"] = .string(one.provenance.rawValue)
        }
        if let two = hrr?.bestAtTwoMinutes { out["hrr_2min_drop_bpm"] = .integer(two.drop) }
        return out
    }

    /// Given an optional workout and a tail key like .alpha1.mean or
    /// .trimp, return that field's FactValue. When tail is nil, returns
    /// the full record (useful for small dumps).
    static func resolveSessionField(_ session: HRVSession?, tail: FactKey?) -> FactValue {
        guard let session else { return .missing(reason: .notRecorded, detail: "session not found") }
        return field(of: fullRecord(for: session), tail: tail)
    }

    /// One step down the record: the field and how many tail tokens it used.
    /// Record keys are flat snake_case, so two tokens are first tried joined
    /// ("alpha1.mean" → "alpha1_mean"); then the token itself, then the
    /// conventional alias ("alpha1" → "alpha1_mean").
    private static func fieldStep(_ dict: [String: FactValue], tokens: [FactKey.Token], at index: Int) -> (value: FactValue, tokensUsed: Int)? {
        let name = tokens[index].name
        if index + 1 < tokens.count, let joined = dict[name + "_" + tokens[index + 1].name] {
            return (joined, 2)
        }
        guard let next = dict[name] ?? dict[name + "_mean"] else { return nil }
        return (next, 1)
    }
}

// MARK: - walks.* namespace

/// Walk and hike workouts only. Runs, rides and every other sport are on
/// `workout.*`. TRIMP here is the heart-rate TRIMP stored on each recording;
/// CTL/ATL use the power-aware load and also count HealthKit-only workouts,
/// so these totals can be lower than the Load page's.
struct WalksNamespace: FactNamespaceResolver {
    let namespace = "walks"
    let archive: SessionArchive

    private static let walkSports: Set<Sport> = [.walk, .hike]

    /// Walk and hike sessions in the period, newest first. The sport lives on
    /// the session, not the index, so each workout in the period is loaded.
    private func walksInPeriod(_ period: String) -> [HRVSession] {
        guard let interval = PeriodParser.interval(for: period) else { return [] }
        return archive.entries
            .filter { $0.sessionType == .workout && interval.containsBeforeEnd($0.date) }
            .sorted { $0.date > $1.date }
            .compactMap { archive.retrieveLightweightOrLog($0.sessionId) }
            .filter { $0.workoutMetadata.map { Self.walkSports.contains($0.sport) } ?? false }
    }

    /// Drops the whole walks namespace from the schema when there isn't a
    /// single workout in the archive. The index has no sport, so a user with
    /// only runs still sees these tools; they answer with a zero count.
    private func walksAvailability() -> Availability {
        .workouts(in: archive)
    }

    var entries: [FactEntry] {
        return [
            walksCountPeriodEntry,
            walksTotalDistanceMPeriodEntry,
            walksTotalTrimpPeriodEntry,
            walksHardestPeriodEntry,
            walksListPeriodEntry
        ]
    }

    private var walksCountPeriodEntry: FactEntry {
        .parameterized(
            pattern: "walks.count($period)",
            paramExample: "last_7d",
            description: "Number of walks and hikes in the given period (other sports: workout.count). Period accepts last_7d / last_14d / last_30d / last_90d / all_time.",
            availability: { self.walksAvailability() },
            resolve: { param, _ in
                .integer(self.walksInPeriod(param).count)
            }
        )
    }

    private var walksTotalDistanceMPeriodEntry: FactEntry {
        .parameterized(
            pattern: "walks.total_distance_m($period)",
            paramExample: "last_7d",
            description: "Sum of distance across walks and hikes in the period. Metres.",
            availability: { self.walksAvailability() },
            resolve: { param, _ in
                let total = self.walksInPeriod(param).compactMap(\.workoutMetadata?.distanceMeters).reduce(0, +)
                return total > 0 ? .double(total) : .missing(reason: .notRecorded, detail: "no distance-bearing walks in period")
            }
        )
    }

    private var walksTotalTrimpPeriodEntry: FactEntry {
        .parameterized(
            pattern: "walks.total_trimp($period)",
            paramExample: "last_7d",
            description: "Sum of heart-rate TRIMP across walks and hikes in the period. Not the load CTL/ATL use (that one is power-aware and includes HealthKit-only workouts), so don't compare it to the Load page's totals.",
            availability: { self.walksAvailability() },
            resolve: { param, _ in
                let total = self.walksInPeriod(param).compactMap(\.workoutMetadata?.luciaTRIMP).reduce(0, +)
                return total > 0 ? .double(total) : .missing(reason: .notRecorded, detail: "no TRIMP data on walks in period")
            }
        )
    }

    private var walksHardestPeriodEntry: FactEntry {
        .parameterized(
            pattern: "walks.hardest($period)",
            paramExample: "last_30d",
            description: "Walk or hike with the highest heart-rate TRIMP in the period, as a full session record.",
            availability: { self.walksAvailability() },
            resolve: { param, _ in
                let sessions = self.walksInPeriod(param)
                guard let hardest = sessions.max(by: { ($0.workoutMetadata?.luciaTRIMP ?? 0) < ($1.workoutMetadata?.luciaTRIMP ?? 0) }) else {
                    return .missing(reason: .notRecorded, detail: "no walks in period")
                }
                return SessionNamespace.fullRecord(for: hardest)
            }
        )
    }

    private var walksListPeriodEntry: FactEntry {
        .parameterized(
            pattern: "walks.list($period)",
            paramExample: "last_7d",
            description: "List of walks and hikes in the period (every sport: workout.list). Each item is a session summary record.",
            availability: { self.walksAvailability() },
            resolve: { param, _ in
                .list(self.walksInPeriod(param).map { SessionNamespace.fullRecord(for: $0) })
            }
        )
    }
}
// MARK: - training.load.* namespace

struct TrainingLoadNamespace: FactNamespaceResolver {
    let namespace = "training"
    let archive: SessionArchive
    let settings: @Sendable () -> UserSettings

    /// Live-first, cache-fallback. Reads the shared metrics cache (same
    /// source the dashboard uses) so the AI and the UI can never disagree.
    ///
    /// Reads `dailySeries[today]` instead of
    /// `snapshot()`. The dashboard's Load & Trajectory page renders the
    /// last entry of `dailySeries` as "current", but `snapshot()` returns
    /// `cache.current` — a separately-computed value via
    /// `calculateTrainingMetrics(...)` that can disagree by a meaningful
    /// margin (real user case: dashboard 44.2/28.7/-15.5, AI quoted
    /// 58/29/-29 from `snapshot()`). Reading the daily-series entry
    /// guarantees the AI and the dashboard pull from the same row of
    /// the same EWMA replay.
    ///
    /// Falls back to `snapshot()` if the daily series hasn't populated
    /// yet (cold cache), then to the latest session's `trainingSnapshot`
    /// if even that's nil. The fallbacks may be slightly off from the
    /// dashboard during the brief window between launch and the first
    /// dailySeries build, but never return `.notRecorded` when we
    /// clearly have data.
    func liveOrCached() -> TrainingLoadState? {
        // Route through `TrainingLoadRegistry.live()`.
        // The registry is the single source of truth for any "live"
        // training-load read across the app — dashboard card, AI live
        // block, AI atomic tools (this function), Load & Trajectory
        // numbers. See TrainingLoadRegistry.swift's header for the
        // surface→source map. Don't give this function its own
        // fallback chain: a local copy drifts from the dashboard's.
        guard let load = MainActor.assumeIsolated({ TrainingLoadRegistry.live() }) else {
            return nil
        }
        return TrainingLoadState(atl: load.atl, ctl: load.ctl, tsb: load.tsb, acwr: load.acwr)
    }

    /// Availability for historical training tools. Reads the
    /// `TrainingMetricsCache`'s cached range — available once the cache
    /// has been refreshed at least once (app foreground, dashboard open).
    func historicalAvailability() -> Availability {
        guard let range = MainActor.assumeIsolated({ AppDependencies.current.analysis.trainingMetricsCache.dataAvailabilityRange }) else {
            return .unavailable
        }
        return Availability(hasData: true, validRange: range, lastUpdated: range.upperBound)
    }

    /// Sample → record helper. Snake-case keys match the scheme used by
    /// session/sleep/hrv records for consistency.
    private static func loadRecord(for sample: TrainingMetricsCache.DaySample) -> FactValue {
        .record([
            "date": .date(sample.date),
            "atl": .double(sample.atl),
            "ctl": .double(sample.ctl),
            "tsb": .double(sample.tsb),
            "acwr": sample.ctl > 0 ? .double(sample.atl / sample.ctl) : .missing(reason: .notYetComputed, detail: "ctl=0"),
            "trimp_that_day": .double(sample.trimp)
        ])
    }

    var entries: [FactEntry] {
        snapshotEntries + projectionEntries
    }

    /// Current and historical load: CTL, ATL, TSB, ACWR and the rollups.
    private var snapshotEntries: [FactEntry] {
        [
            [trainingTrajectoryEntry],
            trainingLoadEntries
        ]
        .flatMap { $0 }
    }

    private var trainingLoadEntries: [FactEntry] {
        [
            trainingLoadCurrentEntries,
            trainingLoadByDateEntries
        ]
        .flatMap { $0 }
    }

    // --- Current point values ---
    // Descriptions call these LIVE / CURRENT and the canonical answer for
    // "today's CTL/ATL/TSB", so the model quotes one source instead of
    // mixing them with workout-start or forecast values in one conversation.
    private var trainingLoadCurrentEntries: [FactEntry] {
        [
            trainingLoadCtlEntry,
            trainingLoadAtlEntry,
            trainingLoadTsbEntry,
            trainingLoadAcwrEntry,
            trainingLoadByDateDateEntry,
            trainingLoadRecentPeriodEntry
        ]
    }

    // --- Per-day scalar pulls, for when the model needs one value, not the full record ---
    private var trainingLoadByDateEntries: [FactEntry] {
        [
            trainingLoadCtlByDateDateEntry,
            trainingLoadAtlByDateDateEntry,
            trainingLoadTsbByDateDateEntry,
            trainingLoadTrimpByDateDateEntry,
            trainingLoadBySportPeriodEntry
        ]
    }

    private var trainingTrajectoryEntry: FactEntry {
        .fixed(
            key: "training.trajectory",
            description: """
            Where the user's fitness is HEADED — the Load & Trajectory verdict the app's dedicated screen shows. trajectory: building / maintaining / detraining / highStrain / rapidIncrease / peaking / comeback / overreach / buildingBaseline \
            (trajectory_label is the human phrasing). Plus ramp_band + ramp_rate_ctl_per_week (weekly CTL slope), form_descriptor / form_word (Fresh / Held / Working / Tired / VeryTired, from TSB), monotony + strain (Foster — high monotony \
            = little day-to-day variation in load; describe it as that, not as a risk), and current ctl/atl/tsb. Use for 'am I building or detraining?', 'what's my form?', 'is my training too monotonous?'.
            """,
            valueType: "Record",
            availability: { self.historicalAvailability() },
            resolve: { self.trajectoryRecord() }
        )
    }

    private var trainingLoadCtlEntry: FactEntry {
        .fixed(key: "training.load.ctl", description: """
        Chronic training load — 42-day exponentially-weighted average of daily training load (power-based TSS where a session has it, else heart-rate TSS/TRIMP; fitness proxy). LIVE / CURRENT value — exactly what the user sees on their \
        Dashboard right now. `workout.live.today_readiness.ctl` returns this SAME live value (they \
        can't disagree). Canonical answer for 'what's my CTL'.
        """, valueType: "Double") {
            .from(self.liveOrCached()?.ctl)
        }
    }

    private var trainingLoadAtlEntry: FactEntry {
        .fixed(key: "training.load.atl", description: """
        Acute training load — 7-day EWMA (fatigue proxy). LIVE / CURRENT value — exactly what the user sees on their Dashboard right now. `workout.live.today_readiness.atl` returns this SAME live value (they can't disagree). Canonical answer \
        for 'what's my ATL'.
        """, valueType: "Double") {
            .from(self.liveOrCached()?.atl)
        }
    }

    private var trainingLoadTsbEntry: FactEntry {
        .fixed(key: "training.load.tsb", description: """
        Training-load balance (form, CTL − ATL). Positive = fresh, negative = fatigued. LIVE / CURRENT value — this is EXACTLY the TSB the user sees on their Dashboard right now, and THE canonical answer for 'what's my TSB' / 'right now' / 'today'. \
        `workout.live.today_readiness.tsb` returns this same live value (they can't disagree). CRITICAL: never answer a current-TSB question with a FORECAST (`projected_tsb_tomorrow_steady_state`), a workout-start value (`starting_tsb`), or an \
        end-of-workout estimate (`final_tsb`) — those are projections/snapshots, NOT the current number, and quoting one as 'current' is the exact bug that made TSB swing between turns.
        """, valueType: "Double") {
            guard let live = self.liveOrCached() else {
                return .missing(reason: .notRecorded, detail: "no training metrics yet — first load happens after app foreground")
            }
            return .double(live.tsb)
        }
    }

    private var trainingLoadAcwrEntry: FactEntry {
        .fixed(key: "training.load.acwr", description: """
        Acute-to-chronic workload ratio — ATL ÷ CTL. <0.8 below your usual range, 0.8-1.0 maintenance, 1.0-1.3 in range, 1.3-1.5 above your usual range, >1.5 sharp increase \
        — the same bands and labels the Training Load screen shows; descriptive, not an injury-risk prediction. LIVE / CURRENT value; matches the Dashboard.
        """, valueType: "Double") {
            .from(self.liveOrCached()?.acwr)
        }
    }

    // --- Historical lookups (cached daily series) ---
    private var trainingLoadByDateDateEntry: FactEntry {
        .parameterized(
            pattern: "training.load.by_date($date)",
            paramExample: "2026-03-15",
            description: """
                Training load (atl, ctl, tsb, acwr, and that day's training load in the `trimp` field — the power-aware load CTL/ATL use) AS OF a specific local date. Returns the values the dashboard would have shown on that date. Horizon: last \
                ~400 days (year-over-year queries supported).
                """,
            availability: { self.historicalAvailability() },
            resolve: { param, _ in
                guard let date = FactLocalDay.formatter().date(from: param) else {
                    return .missing(reason: .invalidParameter, detail: "expected yyyy-MM-dd, got '\(param)'")
                }
                guard let sample = MainActor.assumeIsolated({ AppDependencies.current.analysis.trainingMetricsCache.sampleOn(date: date) }) else {
                    return .missing(reason: .outOfRange, detail: "no training sample for \(param) — outside cached window or pre-data")
                }
                return Self.loadRecord(for: sample)
            }
        )
    }

    private var trainingLoadRecentPeriodEntry: FactEntry {
        .parameterized(
            pattern: "training.load.recent($period)",
            paramExample: "last_30d",
            description: """
            Daily training-load series over a recent period. Each item is a record with date, atl, ctl, tsb, acwr, and that day's training load in the `trimp` field (the power-aware load CTL/ATL use). Most recent first. Periods: last_7d / \
            last_14d / last_30d / last_90d / last_180d / last_365d / all_time. \
            Use for 'how has my CTL trended?' / 'was I fitter last month?' / 'year-over-year?'.
            """,
            availability: { self.historicalAvailability() },
            resolve: { param, _ in
                guard let interval = PeriodParser.interval(for: param) else {
                    return .missing(reason: .invalidParameter, detail: "unknown period '\(param)' — accepts 7d/14d/30d/60d/90d/180d/365d, last_week/this_week, last_month, last_quarter, last_year, all_time")
                }
                let samples = Self.loadSamples(in: interval)
                guard !samples.isEmpty else {
                    return .missing(reason: .notRecorded, detail: "no daily samples in period — cache may be cold")
                }
                return .list(samples.map { Self.loadRecord(for: $0) })
            }
        )
    }

    /// Cached daily load samples inside `interval`, newest first.
    private static func loadSamples(in interval: DateInterval) -> [TrainingMetricsCache.DaySample] {
        MainActor.assumeIsolated {
            AppDependencies.current.analysis.trainingMetricsCache.samplesSince(interval.start)
        }.filter { interval.containsBeforeEnd($0.date) }
    }

    private var trainingLoadCtlByDateDateEntry: FactEntry {
        .parameterized(
            pattern: "training.load.ctl.by_date($date)",
            paramExample: "2026-03-15",
            description: "CTL (chronic training load, fitness proxy) on a specific historical date.",
            availability: { self.historicalAvailability() },
            resolve: { param, _ in
                guard let sample = Self.sampleOnDate(param) else {
                    return .missing(reason: .outOfRange, detail: "no training sample for \(param)")
                }
                return .double(sample.ctl)
            }
        )
    }

    private var trainingLoadAtlByDateDateEntry: FactEntry {
        .parameterized(
            pattern: "training.load.atl.by_date($date)",
            paramExample: "2026-03-15",
            description: "ATL (acute training load, fatigue proxy) on a specific historical date.",
            availability: { self.historicalAvailability() },
            resolve: { param, _ in
                guard let sample = Self.sampleOnDate(param) else {
                    return .missing(reason: .outOfRange, detail: "no training sample for \(param)")
                }
                return .double(sample.atl)
            }
        )
    }

    private var trainingLoadTsbByDateDateEntry: FactEntry {
        .parameterized(
            pattern: "training.load.tsb.by_date($date)",
            paramExample: "2026-03-15",
            description: "TSB (CTL − ATL, freshness) on a specific historical date.",
            availability: { self.historicalAvailability() },
            resolve: { param, _ in
                guard let sample = Self.sampleOnDate(param) else {
                    return .missing(reason: .outOfRange, detail: "no training sample for \(param)")
                }
                return .double(sample.tsb)
            }
        )
    }

    private var trainingLoadTrimpByDateDateEntry: FactEntry {
        .parameterized(
            pattern: "training.load.trimp.by_date($date)",
            paramExample: "2026-03-15",
            description: "Total training load on a specific historical date (sum across all workouts that day) — the power-aware load CTL/ATL use, which the dashboard labels LOAD; not raw heart-rate TRIMP.",
            availability: { self.historicalAvailability() },
            resolve: { param, _ in
                guard let sample = Self.sampleOnDate(param) else {
                    return .missing(reason: .outOfRange, detail: "no training sample for \(param)")
                }
                return .double(sample.trimp)
            }
        )
    }

    // --- TRIMP breakdown by sport over a period ---
    private var trainingLoadBySportPeriodEntry: FactEntry {
        .parameterized(
            pattern: "training.load.by_sport($period)",
            paramExample: "last_30d",
            description: """
            Heart-rate TRIMP breakdown by sport type (walking, running, cycling, etc.) over the period, from the app's own recordings. Returns a record keyed by sport name with TRIMP totals. CTL/ATL and the weekly totals use the \
            power-aware load and include HealthKit-only workouts, so these need not sum to them. Period accepts last_7d / last_14d / last_30d / last_90d / last_180d / last_365d / all_time.
            """,
            availability: { Availability(hasData: true, validRange: nil, lastUpdated: nil) },
            resolve: { param, _ in self.resolveTrainingLoadBySportPeriod(param) }
        )
    }

    private func resolveTrainingLoadBySportPeriod(_ param: String) -> FactValue {
        guard let interval = PeriodParser.interval(for: param) else {
            return .missing(reason: .invalidParameter, detail: "unknown period '\(param)' — accepts 7d/14d/30d/60d/90d/180d/365d, last_week/this_week, last_month, last_quarter, last_year, all_time")
        }
        let entries = self.archive.entries
            .filter { $0.sessionType == .workout && interval.containsBeforeEnd($0.date) }
        let sessions = entries.compactMap { self.archive.retrieveLightweightOrLog($0.sessionId) }
        var totals: [String: Double] = [:]
        for s in sessions {
            guard let meta = s.workoutMetadata, let trimp = meta.luciaTRIMP else { continue }
            totals[meta.sport.displayName, default: 0] += trimp
        }
        guard !totals.isEmpty else {
            return .missing(reason: .notRecorded, detail: "no TRIMP-bearing workouts in period")
        }
        var record: [String: FactValue] = [:]
        for (sport, trimp) in totals {
            record[sport] = .double(trimp)
        }
        return .record(record)
    }

    /// Parse "yyyy-MM-dd" and look up the corresponding TrainingMetricsCache
    /// sample. Wrapped for reuse by the per-scalar by_date facts above.
    private static func sampleOnDate(_ iso: String) -> TrainingMetricsCache.DaySample? {
        guard let date = FactLocalDay.formatter().date(from: iso) else { return nil }
        return MainActor.assumeIsolated { AppDependencies.current.analysis.trainingMetricsCache.sampleOn(date: date) }
    }
}

// MARK: - Heat acclimatization

/// `heat.acclimation.*` facts so the assistant can answer "how acclimated
/// am I to the heat?" / "how much more do I need to do?". Reads the shared
/// `HeatAcclimationCache` — the same source the Load & Trajectory card
/// renders, so the AI and the UI can never disagree.
struct HeatAcclimationNamespace: FactNamespaceResolver {
    let namespace = "heat"

    /// Await a readout, bounded — the compute does one weather fetch.
    func readout() async -> HeatAcclimationCache.Readout? {
        await FactResolveTimeout.withTimeout(seconds: 8) {
            await AppDependencies.current.analysis.heatAcclimationCache.currentAwaitingRefresh()
        } ?? nil
    }

    var entries: [FactEntry] {
        [
            heatAcclimationLevelEntry,
            heatAcclimationSummaryEntry
        ]
    }

    private var heatAcclimationLevelEntry: FactEntry {
        .fixedAsync(
            key: "heat.acclimation.level",
            description: """
            Heat-acclimatization level, 0–100%. How adapted the user currently is to exercising in the heat, built by replaying each outdoor workout's logged temperature + humidity through a physiology model (induction ~5-day time constant, \
            ~2.5%/day decay without heat exposure). 0 = not heat-adapted, 85+ = fully acclimated. LIVE value; matches the Load & Trajectory card.
            """,
            valueType: "Double"
        ) {
            guard let r = await self.readout() else {
                return self.missing(otherwise: "no outdoor workouts with weather yet — heat tracking builds from logged hot sessions")
            }
            return .double(r.level)
        }
    }

    private var heatAcclimationSummaryEntry: FactEntry {
        .fixedAsync(
            key: "heat.acclimation.summary",
            description: """
            Heat-acclimatization summary the user can act on: current level (0–100%), plain-language band, the heat level they're adapted to (≈ air temperature), how many more hot training days to reach full acclimatization, and how \
            many qualifying hot exposures are in the trailing window. THE canonical answer for 'how acclimated am I to the heat / summer?' and 'how much more do I need to do?'.
            """,
            valueType: "Record"
        ) { await self.resolveHeatAcclimationSummary() }
    }

    @MainActor private func resolveHeatAcclimationSummary() async -> FactValue {
        guard let r = await self.readout() else {
            return missing(otherwise: "no outdoor workouts with weather yet")
        }
        var rec: [String: FactValue] = [
            "level_percent": .double(r.level),
            "band": .string(r.band.label),
            "hot_exposures_in_window": .integer(r.hotExposureCount)
        ]
        if let wbgt = r.adaptedWBGT {
            rec["adapted_to_wbgt_c"] = .double(wbgt)
            rec["adapted_to_air_temp_c_approx"] = .double(HeatAcclimation.approxAirTempC(fromWBGT: wbgt))
        }
        addAcclimationStatus(&rec, daysToTarget: r.daysToTarget)
        return .record(rec)
    }

    /// No readout. With heat tracking off the cache never computes one, so
    /// "no outdoor workouts" would be a false answer; say what is actually
    /// stopping it and where the user can change that.
    private func missing(otherwise detail: String) -> FactValue {
        guard AppDependencies.current.app.settingsManager.settingsSnapshot.heatTrackingEnabled else {
            return .missing(
                reason: .notRecorded,
                detail: "heat tracking is turned off — the user can turn it on from the Heat acclimatization card on the Fitness tab"
            )
        }
        return .missing(reason: .notRecorded, detail: detail)
    }

    private func addAcclimationStatus(_ rec: inout [String: FactValue], daysToTarget: Int?) {
        switch daysToTarget {
        case .some(0):
            rec["status"] = .string("at or above target — fully acclimated to summer heat")
        case let .some(n):
            rec["more_hot_days_to_full"] = .integer(n)
            rec["status"] = .string("about \(n) more hot training day(s) to full acclimatization")
        case .none:
            rec["status"] = .string("current sessions aren't hot enough to reach full acclimatization — need hotter or longer outdoor exposure")
        }
    }
}
