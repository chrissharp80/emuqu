import Foundation

// The session, walks, training-load and heat namespaces, split out of
// `AppFactResolver.swift` at a top-level type boundary. The period
// parser, the factory, and the user/app namespaces stay behind.

// MARK: - session.* namespace

struct SessionNamespace: FactNamespaceResolver {
    let namespace = "session"
    let archive: SessionArchive
    let settings: @Sendable () -> UserSettings

    /// Metadata-only: returns "do we have any workout sessions at all,
    /// and if so what's the date range?". Read path is the in-memory
    /// archive entries index — no disk I/O, no HealthKit call — which
    /// satisfies the `availability` synchronous + metadata-only contract.
    private func workoutAvailability() -> Availability {
        let entries = archive.entries.filter { $0.sessionType == .workout }
        guard !entries.isEmpty,
              let earliest = entries.map(\.date).min(),
              let latest = entries.map(\.date).max()
        else { return .unavailable }
        // Range is inclusive, earliest..latest. The schema inlines only
        // the start-of-month of `earliest` into the tool description.
        return Availability(hasData: true, validRange: earliest ... latest, lastUpdated: latest)
    }

    /// Internal: load a session by ordinal (0 = latest workout).
    private func sessionByOrdinal(_ n: Int) -> HRVSession? {
        guard n >= 0 else { return nil }
        let entries = archive.entries
            .filter { $0.sessionType == .workout }
            .sorted { $0.date > $1.date }
        guard n < entries.count else { return nil }
        return archive.retrieveLightweightOrLog(entries[n].sessionId)
    }

    private func sessionByID(_ idString: String) -> HRVSession? {
        guard let uuid = UUID(uuidString: idString) else { return nil }
        return archive.retrieveLightweightOrLog(uuid)
    }

    private func sessionByDate(_ iso: String) -> HRVSession? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        guard let target = formatter.date(from: iso) else { return nil }
        let cal = Calendar.current
        let day = cal.startOfDay(for: target)
        guard let next = cal.date(byAdding: .day, value: 1, to: day) else { return nil }
        let entry = archive.entries
            .first { $0.sessionType == .workout && $0.date >= day && $0.date < next }
        return entry.flatMap { archive.retrieveLightweightOrLog($0.sessionId) }
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

    // --- latest convenience (== by_ordinal(0)) ---
    private var sessionLatestEntry: FactEntry {
        .fixed(
            key: "session.latest",
            description: "All fields for the most recent workout as a record — same keys as session.by_ordinal(0).* parameterised lookups.",
            valueType: "Record",
            availability: { self.workoutAvailability() },
            resolve: { Self.fullRecord(for: self.sessionByOrdinal(0)) }
        )
    }

    private var sessionLatestIdEntry: FactEntry {
        .fixed(
            key: "session.latest.id",
            description: "UUID of the most recent workout.",
            valueType: "String",
            availability: { self.workoutAvailability() },
            resolve: { .from(self.sessionByOrdinal(0)?.id.uuidString) }
        )
    }

    private var sessionLatestDateEntry: FactEntry {
        .fixed(
            key: "session.latest.date",
            description: "Start date of the most recent workout.",
            valueType: "Date",
            availability: { self.workoutAvailability() },
            resolve: { .from(self.sessionByOrdinal(0)?.startDate) }
        )
    }

    // --- parameterized: session.by_ordinal(N).* ---
    private var sessionByOrdinalNEntry: FactEntry {
        .parameterized(
            pattern: "session.by_ordinal($n)",
            paramExample: "0",
            description: "A workout by recency index (0 = most recent, 1 = previous, …). Tail tokens access any stored field; e.g. session.by_ordinal(2).alpha1.mean.",
            availability: { self.workoutAvailability() },
            resolve: { param, tail in
                guard let n = Int(param) else {
                    return .missing(reason: .invalidParameter, detail: "invalid ordinal '\(param)'")
                }
                let session = self.sessionByOrdinal(n)
                return Self.resolveSessionField(session, tail: tail)
            }
        )
    }

    private var sessionByIdIdEntry: FactEntry {
        .parameterized(
            pattern: "session.by_id($id)",
            paramExample: "A43B2C4F-0000-4000-8000-000000000000",
            description: "A workout by UUID. Tail tokens access any stored field.",
            availability: { self.workoutAvailability() },
            resolve: { param, tail in
                Self.resolveSessionField(self.sessionByID(param), tail: tail)
            }
        )
    }

    private var sessionByDateDateEntry: FactEntry {
        .parameterized(
            pattern: "session.by_date($date)",
            paramExample: "2026-04-21",
            description: "A workout by date (yyyy-MM-dd, local timezone). Returns the first workout on that date.",
            availability: { self.workoutAvailability() },
            resolve: { param, tail in
                Self.resolveSessionField(self.sessionByDate(param), tail: tail)
            }
        )
    }

    // MARK: Record serializer

    /// Full record for a session — every persisted field the analysis
    /// snapshot captures, plus the core identity / timing fields. This
    /// is what the AI sees when it does `session.latest` or
    /// `session.by_id(X)` without a tail.
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

    /// Given an optional session and a tail key like .alpha1.mean or
    /// .trimp, return that field's FactValue. When tail is nil, returns
    /// the full record (useful for small dumps).
    static func resolveSessionField(_ session: HRVSession?, tail: FactKey?) -> FactValue {
        guard let session else { return .missing(reason: .notRecorded, detail: "session not found") }
        let record = fullRecord(for: session)
        guard let tail else { return record }
        var cursor: FactValue = record
        for token in tail.tokens {
            guard case .record(let dict) = cursor else {
                return .missing(reason: .invalidParameter, detail: "cannot descend into non-record at '\(token.rendered)'")
            }
            // Fact record keys use snake_case; accept either a direct match or
            // the conventional alias (e.g. "alpha1" → "alpha1_mean").
            guard let next = dict[token.name] ?? dict[token.name + "_mean"] else {
                return .missing(reason: .invalidParameter, detail: "no field '\(token.rendered)' on session record")
            }
            cursor = next
        }
        return cursor
    }
}

// MARK: - walks.* namespace

struct WalksNamespace: FactNamespaceResolver {
    let namespace = "walks"
    let archive: SessionArchive

    private func cutoff(for period: String) -> Date? {
        PeriodParser.cutoff(for: period)
    }

    private func entriesInPeriod(_ period: String) -> [SessionArchiveEntry] {
        guard let cutoff = cutoff(for: period) else { return [] }
        return archive.entries
            .filter { $0.sessionType == .workout && $0.date >= cutoff }
            .sorted { $0.date > $1.date }
    }

    /// Drops the whole walks namespace from the schema when there isn't a
    /// single workout in the archive — the user has literally nothing to
    /// query. Otherwise every walks tool becomes available; the period
    /// parameter is self-describing in its enum of allowed values.
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
            description: "Number of workouts in the given period. Period accepts last_7d / last_14d / last_30d / last_90d / all_time.",
            availability: { self.walksAvailability() },
            resolve: { param, _ in
                .integer(self.entriesInPeriod(param).count)
            }
        )
    }

    private var walksTotalDistanceMPeriodEntry: FactEntry {
        .parameterized(
            pattern: "walks.total_distance_m($period)",
            paramExample: "last_7d",
            description: "Sum of distance across all workouts in the period. Metres.",
            availability: { self.walksAvailability() },
            resolve: { param, _ in
                let sessions = self.entriesInPeriod(param).compactMap { self.archive.retrieveLightweightOrLog($0.sessionId) }
                let total = sessions.compactMap(\.workoutMetadata?.distanceMeters).reduce(0, +)
                return total > 0 ? .double(total) : .missing(reason: .notRecorded, detail: "no distance-bearing workouts in period")
            }
        )
    }

    private var walksTotalTrimpPeriodEntry: FactEntry {
        .parameterized(
            pattern: "walks.total_trimp($period)",
            paramExample: "last_7d",
            description: "Sum of TRIMP across all workouts in the period.",
            availability: { self.walksAvailability() },
            resolve: { param, _ in
                let sessions = self.entriesInPeriod(param).compactMap { self.archive.retrieveLightweightOrLog($0.sessionId) }
                let total = sessions.compactMap(\.workoutMetadata?.luciaTRIMP).reduce(0, +)
                return total > 0 ? .double(total) : .missing(reason: .notRecorded, detail: "no TRIMP data in period")
            }
        )
    }

    private var walksHardestPeriodEntry: FactEntry {
        .parameterized(
            pattern: "walks.hardest($period)",
            paramExample: "last_30d",
            description: "Highest-TRIMP workout in the period. Returns a record with the session's id, date, trimp.",
            availability: { self.walksAvailability() },
            resolve: { param, _ in
                let sessions = self.entriesInPeriod(param).compactMap { self.archive.retrieveLightweightOrLog($0.sessionId) }
                guard let hardest = sessions.max(by: { ($0.workoutMetadata?.luciaTRIMP ?? 0) < ($1.workoutMetadata?.luciaTRIMP ?? 0) }) else {
                    return .missing(reason: .notRecorded, detail: "no workouts in period")
                }
                return SessionNamespace.fullRecord(for: hardest)
            }
        )
    }

    private var walksListPeriodEntry: FactEntry {
        .parameterized(
            pattern: "walks.list($period)",
            paramExample: "last_7d",
            description: "List of workouts in period. Each item is a session summary record.",
            availability: { self.walksAvailability() },
            resolve: { param, _ in
                let sessions = self.entriesInPeriod(param).compactMap { self.archive.retrieveLightweightOrLog($0.sessionId) }
                return .list(sessions.map { SessionNamespace.fullRecord(for: $0) })
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
    // Descriptions explicitly call these LIVE /
    // CURRENT and the canonical answer for "today's
    // CTL/ATL/TSB". The same numbers also exist in a frozen
    // form on `workout.live.today_readiness` (snapshot at
    // workout start) — when the user asks "what's my TSB"
    // mid-workout the AI must pick ONE source, not flip
    // between them. The reported failure mode (telling the
    // user TSB is -19 then -13.6 in the same conversation)
    // came from mixing live + frozen values; spelling out
    // "this is the live value, prefer it" makes the choice
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

    // --- Per-day scalar pulls (so the AI doesn't have to parse
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
            = under-varied load, an overtraining-risk signal), and current ctl/atl/tsb. Use for 'am I building or detraining?', 'what's my form?', 'is my training too monotonous?'.
            """,
            valueType: "Record",
            availability: { self.historicalAvailability() },
            resolve: { self.trajectoryRecord() }
        )
    }

    // unambiguous in the schema the model sees.
    private var trainingLoadCtlEntry: FactEntry {
        .fixed(key: "training.load.ctl", description: """
        Chronic training load — 42-day exponentially-weighted TRIMP average (fitness proxy). LIVE / CURRENT value — exactly what the user sees on their Dashboard right now. `workout.live.today_readiness.ctl` returns this SAME live value (they \
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
        Training stress balance — CTL minus ATL. Positive = fresh, negative = fatigued. LIVE / CURRENT value — this is EXACTLY the TSB the user sees on their Dashboard right now, and THE canonical answer for 'what's my TSB' / 'right now' / 'today'. \
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
        .fixed(key: "training.load.acwr", description: "Acute-to-chronic workload ratio — ATL ÷ CTL. <0.8 below your usual range, 0.8-1.3 within your usual range, >1.5 sharp recent increase. LIVE / CURRENT value; matches the Dashboard.", valueType: "Double") {
            .from(self.liveOrCached()?.acwr)
        }
    }

    // --- Historical lookups (cached daily series) ---
    private var trainingLoadByDateDateEntry: FactEntry {
        .parameterized(
            pattern: "training.load.by_date($date)",
            paramExample: "2026-03-15",
            description: "Training load (atl, ctl, tsb, acwr, that-day TRIMP) AS OF a specific local date. Returns the values the dashboard would have shown on that date. Horizon: last ~400 days (year-over-year queries supported).",
            availability: { self.historicalAvailability() },
            resolve: { param, _ in
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                formatter.timeZone = .current
                guard let date = formatter.date(from: param) else {
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
            Daily training-load series over a recent period. Each item is a record with date, atl, ctl, tsb, acwr, and that-day TRIMP. Most recent first. Periods: last_7d / last_14d / last_30d / last_90d / last_180d / last_365d / all_time. \
            Use for 'how has my CTL trended?' / 'was I fitter last month?' / 'year-over-year?'.
            """,
            availability: { self.historicalAvailability() },
            resolve: { param, _ in
                guard let cutoff = PeriodParser.cutoff(for: param) else {
                    return .missing(reason: .invalidParameter, detail: "unknown period '\(param)' — accepts 7d/14d/30d/60d/90d/180d/365d, last_week/this_week, last_month, last_quarter, last_year, all_time")
                }
                let samples = MainActor.assumeIsolated { AppDependencies.current.analysis.trainingMetricsCache.samplesSince(cutoff) }
                guard !samples.isEmpty else {
                    return .missing(reason: .notRecorded, detail: "no daily samples in period — cache may be cold")
                }
                return .list(samples.map { Self.loadRecord(for: $0) })
            }
        )
    }

    //     the full record when it only needs one value) ---
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
            description: "Total TRIMP earned on a specific historical date (sum across all workouts that day).",
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
            description: "TRIMP breakdown by sport type (walking, running, cycling, etc.) over the period. Returns a record keyed by sport name with TRIMP totals. Period accepts last_7d / last_14d / last_30d / last_90d / last_180d / last_365d / all_time.",
            availability: { Availability(hasData: true, validRange: nil, lastUpdated: nil) },
            resolve: { param, _ in self.resolveTrainingLoadBySportPeriod(param) }
        )
    }

    private func resolveTrainingLoadBySportPeriod(_ param: String) -> FactValue {
        guard let cutoff = PeriodParser.cutoff(for: param) else {
            return .missing(reason: .invalidParameter, detail: "unknown period '\(param)' — accepts 7d/14d/30d/60d/90d/180d/365d, last_week/this_week, last_month, last_quarter, last_year, all_time")
        }
        let entries = self.archive.entries
            .filter { $0.sessionType == .workout && $0.date >= cutoff }
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
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        guard let date = formatter.date(from: iso) else { return nil }
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
                return .missing(reason: .notRecorded, detail: "no outdoor workouts with weather yet — heat tracking builds from logged hot sessions")
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
            return .missing(reason: .notRecorded, detail: "no outdoor workouts with weather yet")
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
