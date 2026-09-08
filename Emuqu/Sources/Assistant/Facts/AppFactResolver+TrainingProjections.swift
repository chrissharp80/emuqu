import Foundation

// The projection half of `TrainingLoadNamespace`, split out of
// `AppFactResolver+Sessions.swift` when that struct's body passed
// the 500-line limit. The load snapshot facts — CTL / ATL / TSB / ACWR and the
// per-period rollups — stay behind; the forward-looking ones (recovery hours,
// days-until-fresh, race predictions, pace zones) live here.
//
// Only the file boundary changed.

extension TrainingLoadNamespace {
    /// Forward-looking projections derived from the same load model.
    var projectionEntries: [FactEntry] {
        [
            trainingLoadEntries,
            trainingProjectEntries
        ]
        .flatMap { $0 }
    }

    private var trainingLoadEntries: [FactEntry] {
        [
            trainingLoadWeeklyCurrentEntry,
            trainingLoadWeeklyLast4WeeksEntry,
            // Anytime fitness tools. These derive from the
            // archive + cached training load so the AI can answer
            // "what's my predicted 5K?" / "what should I run today?" /
            trainingRecoveryHoursNeededEntry,
            trainingDaysUntilFreshEntry,
            trainingRacePredictionsSportEntry,
            trainingPaceZonesEntry,
            trainingSportBaselineSportEntry,
            trainingDaysUntilAtlConvergesParamsEntry
        ]
    }

    private var trainingProjectEntries: [FactEntry] {
        [
            // General-purpose projection primitives.
            // The AI composes scenarios from these instead of needing
            // a custom tool per question. User feedback: "will I need
            // to special case every question?" — no. These let the AI
            // answer arbitrary 'if I do X TRIMP from this state for Y
            trainingProjectFromParamsEntry,
            daysUntilConvergedFromEntry,
            trainingProjectedTsbDailyTrimpEntry
        ]
    }

    // --- Weekly totals (current rolling 7 days and last 4 weeks) ---
    private var trainingLoadWeeklyCurrentEntry: FactEntry {
        .fixed(
            key: "training.load.weekly.current",
            description: "Total TRIMP over the current rolling 7-day window.",
            valueType: "Double",
            availability: { self.historicalAvailability() },
            resolve: {
                let cal = Calendar.current
                guard let cutoff = cal.date(byAdding: .day, value: -7, to: Date()) else {
                    return .missing(reason: .internalError)
                }
                let samples = MainActor.assumeIsolated { AppDependencies.current.analysis.trainingMetricsCache.samplesSince(cutoff) }
                guard !samples.isEmpty else {
                    return .missing(reason: .notRecorded, detail: "cache cold — no daily samples")
                }
                let total = samples.map(\.trimp).reduce(0, +)
                return .double(total)
            }
        )
    }

    private var trainingLoadWeeklyLast4WeeksEntry: FactEntry {
        .fixed(
            key: "training.load.weekly.last_4_weeks",
            description: "List of the last 4 weekly TRIMP totals. Each item is a record with week_ending (date) and trimp. Most recent week first.",
            valueType: "List",
            availability: { self.historicalAvailability() },
            resolve: { self.resolveTrainingLoadWeeklyLast4Weeks() }
        )
    }

    private func resolveTrainingLoadWeeklyLast4Weeks() -> FactValue {
        let cal = Calendar.current
        let now = Date()
        var items: [FactValue] = []
        for weekIndex in 0 ..< 4 {
            guard let weekEnd = cal.date(byAdding: .day, value: -7 * weekIndex, to: now),
                  let weekStart = cal.date(byAdding: .day, value: -7, to: weekEnd)
            else { continue }
            let samples = MainActor.assumeIsolated {
                AppDependencies.current.analysis.trainingMetricsCache.samplesSince(weekStart)
            }.filter { $0.date < weekEnd }
            let total = samples.map(\.trimp).reduce(0, +)
            items.append(.record([
                "week_ending": .date(weekEnd),
                "trimp": .double(total)
            ]))
        }
        guard !items.isEmpty else {
            return .missing(reason: .notRecorded, detail: "cache cold — no daily samples")
        }
        return .list(items)
    }

    // "how many days until I'm fresh?" OUTSIDE an active workout
    // (the `workout.live.*` versions only fire mid-workout).
    // All sync-readable.
    private var trainingRecoveryHoursNeededEntry: FactEntry {
        .fixed(
            key: "training.recovery_hours_needed",
            description: "Hours of recovery needed before TSB returns to ≥ 0 (Garmin-style 'recovery time'). Derived from current ATL/CTL via Banister EWMA decay. Returns notRecorded when already fresh OR no training-load history. Available outside an active workout — works any time.",
            valueType: "Double"
        ) {
            guard let live = self.liveOrCached() else {
                return .missing(reason: .notRecorded, detail: "no training-load data yet")
            }
            guard let h = RecoveryTimeEstimate.hoursFromTrainingLoad(atl: live.atl, ctl: live.ctl) else {
                return .missing(reason: .notRecorded, detail: "already fresh — no recovery needed")
            }
            return .double(h)
        }
    }

    private var trainingDaysUntilFreshEntry: FactEntry {
        .fixed(
            key: "training.days_until_fresh",
            description: "Days from today until TSB returns to ≥ 0 if zero further training is added (rest forecast). 0 means already fresh. Returns notRecorded when projected recovery would take >30 days (signal: take a real off-week) OR no inputs.",
            valueType: "Int"
        ) {
            guard let live = self.liveOrCached() else {
                return .missing(reason: .notRecorded, detail: "no training-load data yet")
            }
            guard let d = TrainingLoadProjection.daysUntilFresh(currentATL: live.atl, currentCTL: live.ctl) else {
                return .missing(reason: .notRecorded, detail: "either fresh or recovery would exceed 30 days")
            }
            return .integer(d)
        }
    }

    private var trainingRacePredictionsSportEntry: FactEntry {
        .parameterized(
            pattern: "training.race_predictions($sport)",
            paramExample: "run",
            description: """
            Riegel race-time predictions (T2 = T1 × (D2/D1)^1.06) at 5K / 10K / half-marathon / marathon for the given sport, based on the user's fastest sport-matched workout in their history. Returns a record { sport, basis_distance_m, \
            basis_duration_sec, predicted_5k_sec, predicted_10k_sec, predicted_half_sec, predicted_marathon_sec }. Sport: 'run' / 'walk' / 'hike' / 'bike'. Returns notRecorded when no comparable workout exists for that sport.
            """,
            resolve: { rawSport, _ in self.resolveTrainingRacePredictionsSport(rawSport) }
        )
    }

    private func resolveTrainingRacePredictionsSport(_ rawSport: String) -> FactValue {
        guard let sport = Sport(rawValue: rawSport.lowercased()) else {
            return .missing(reason: .invalidParameter, detail: "unknown sport \(rawSport)")
        }
        let archive = self.archive
        let entries = archive.entries
            .filter { $0.sessionType == .workout }
            .compactMap { archive.retrieveLightweightOrLog($0.sessionId) }
        let predictions = RaceTimePrediction.predict(from: entries, sport: sport)
        guard !predictions.isEmpty else {
            return .missing(reason: .notRecorded, detail: "no \(sport.rawValue) workouts long enough for a prediction basis")
        }
        var rec: [String: FactValue] = ["sport": .string(sport.rawValue)]
        if let s = predictions[5_000] { rec["predicted_5k_sec"] = .double(s) }
        if let s = predictions[10_000] { rec["predicted_10k_sec"] = .double(s) }
        if let s = predictions[21_097.5] { rec["predicted_half_sec"] = .double(s) }
        if let s = predictions[42_195] { rec["predicted_marathon_sec"] = .double(s) }
        return .record(rec)
    }

    private var trainingPaceZonesEntry: FactEntry {
        .fixed(
            key: "training.pace_zones",
            description: """
            Daniels-style training pace zones derived from the user's running 5K race prediction. Returns sec/km per zone: easy (long-run / base, ×1.30), marathon (steady race pace, ×1.15), threshold (tempo, ×1.10), interval (VO2max, \
            ×1.00), repetition (speed work, ×0.93). Use to answer 'what pace should I hold for an easy run today?'. Returns notRecorded when no run history exists yet.
            """,
            valueType: "Record"
        ) { self.resolveTrainingPaceZones() }
    }

    private func resolveTrainingPaceZones() -> FactValue {
        let archive = self.archive
        let entries = archive.entries
            .filter { $0.sessionType == .workout }
            .compactMap { archive.retrieveLightweightOrLog($0.sessionId) }
        let predictions = RaceTimePrediction.predict(from: entries, sport: .run)
        guard let totalSec = predictions[5_000],
              let zones = TrainingPaceZones.from5KPace(secPerKm: totalSec / 5.0)
        else {
            return .missing(reason: .notRecorded, detail: "no 5K running basis in history")
        }
        return .record([
            "easy_sec_per_km": .double(zones.easySecPerKm),
            "marathon_sec_per_km": .double(zones.marathonSecPerKm),
            "threshold_sec_per_km": .double(zones.thresholdSecPerKm),
            "interval_sec_per_km": .double(zones.intervalSecPerKm),
            "repetition_sec_per_km": .double(zones.repetitionSecPerKm)
        ])
    }

    private var trainingSportBaselineSportEntry: FactEntry {
        .parameterized(
            pattern: "training.sport_baseline($sport)",
            paramExample: "run",
            description: Self.trainingSportBaselineSportDescription,
            resolve: { rawSport, _ in self.resolveTrainingSportBaselineSport(rawSport) }
        )
    }

    private func resolveTrainingSportBaselineSport(_ rawSport: String) -> FactValue {
        guard let sport = Sport(rawValue: rawSport.lowercased()) else {
            return .missing(reason: .invalidParameter, detail: "unknown sport \(rawSport)")
        }
        let archive = self.archive
        let recent = archive.entries
            .filter { $0.sessionType == .workout }
            .compactMap { archive.retrieveLightweightOrLog($0.sessionId) }
        let baselines = WorkoutHistoryBaselines.compute(from: recent, sport: sport, limit: 30)
        guard baselines.sampleCount > 0 else {
            return .missing(reason: .notRecorded, detail: "no \(sport.rawValue) workouts in history")
        }
        return .record(sportBaselineRecord(sport, baselines: baselines))
    }

    private func sportBaselineRecord(
        _ sport: Sport,
        baselines: WorkoutHistoryBaselines
    ) -> [String: FactValue] {
        var rec: [String: FactValue] = [
            "data_source": .string("sport_wide"),
            "sport": .string(sport.rawValue),
            "sample_count": .integer(baselines.sampleCount),
            "comparison_safe": .boolean(baselines.sampleCount >= 2)
        ]
        if let p = baselines.avgPaceSecPerKm { rec["avg_pace_sec_per_km"] = .double(p) }
        if let h = baselines.avgHR { rec["avg_hr"] = .double(h) }
        if let a = baselines.avgAlpha1 { rec["avg_alpha1"] = .double(a) }
        return rec
    }

    private static let trainingSportBaselineSportDescription = """
    SPORT-WIDE cross-workout averages (NOT route-specific). Returns averages from the user's recent (≤30) workouts of the given sport. Returns a record { data_source: 'sport_wide', sport, sample_count, avg_pace_sec_per_km, avg_hr, \
    avg_alpha1 }. The data_source field tells you to phrase any comparison as 'compared to your typical run' rather than 'compared to this route' (route-specific data is a different tool: workout.live.route_history_baseline). \
    Use for 'what's my typical run pace?' / 'is my usual heart rate high?'. Returns notRecorded when no matching workouts exist.
    """

    private var trainingDaysUntilAtlConvergesParamsEntry: FactEntry {
        .parameterized(
            pattern: "training.days_until_atl_converges($params)",
            paramExample: "60,5",
            description: Self.daysUntilAtlConvergesDescription,
            resolve: { rawParams, _ in self.resolveTrainingDaysUntilAtlConvergesParams(rawParams) }
        )
    }

    private func resolveTrainingDaysUntilAtlConvergesParams(_ rawParams: String) -> FactValue {
        let parts = rawParams.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2,
              let daily = Double(parts[0]), daily >= 0,
              let gap = Double(parts[1]), gap > 0
        else {
            return .missing(reason: .invalidParameter, detail: "expected 'daily_trimp,gap_trimp' both numeric, e.g. '60,5'")
        }
        guard let live = self.liveOrCached() else {
            return .missing(reason: .notRecorded, detail: "no training-load data yet")
        }
        return convergenceRecord(
            atl: live.atl, ctl: live.ctl, daily: daily, gap: gap,
            unmet: "daily_trimp=\(Int(daily)) won't close gap within 60 days at current fitness — unsustainable"
        )
    }

    private static let daysUntilAtlConvergesDescription = """
    Days at the given daily TRIMP load until ATL converges within `gap_trimp` units of CTL (the 'adaptive zone' where fitness ≈ fatigue). Param format: 'daily_trimp,gap_trimp' — e.g. '60,5' means 'how many days at 60 TRIMP/day \
    until |ATL−CTL| ≤ 5'. **For 'if I maintain the current walk daily' questions, get the daily_trimp by calling `workout.most_recent.snapshot` first (it returns TRIMP for today's most recent workout) — don't ask the user.** \
    For 'if I double the walk', multiply that value by 2 before passing in. To project the actual ATL/CTL trajectory (e.g. 'how high would ATL get'), use `training.project_from` with the load value — ATL exponentially approaches \
    the daily TRIMP (7-day τ; ~95% of asymptote at 21 days). Returns 0 when the user is already inside the gap. Returns notRecorded when the chosen daily_trimp would never close the gap within 60 days at current fitness (signal: \
    load unsustainable — ATL outruns CTL forever).
    """

    // days' questions, and chain them when needed.
    private var trainingProjectFromParamsEntry: FactEntry {
        .parameterized(
            pattern: "training.project_from($params)",
            paramExample: "65.4,72.1,80,14",
            description: Self.trainingProjectFromParamsDescription,
            resolve: { rawParams, _ in self.resolveTrainingProjectFromParams(rawParams) }
        )
    }

    private func resolveTrainingProjectFromParams(_ rawParams: String) -> FactValue {
        let parts = rawParams.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count == 4,
              let atl0 = Double(parts[0]), atl0 >= 0,
              let ctl0 = Double(parts[1]), ctl0 >= 0,
              let daily = Double(parts[2]), daily >= 0,
              let days = Int(parts[3]), days >= 1, days <= 365
        else {
            return .missing(reason: .invalidParameter, detail: "expected 'starting_atl,starting_ctl,daily_trimp,horizon_days' all numeric (days 1-365), e.g. '65.4,72.1,80,14'")
        }
        return projection(atl: atl0, ctl: ctl0, daily: daily, days: days)
    }

    private func projection(atl atl0: Double, ctl ctl0: Double, daily: Double, days: Int) -> FactValue {
        let trajectory = TrainingLoadProjection.project(
            startingATL: atl0,
            startingCTL: ctl0,
            dailyTrimp: daily,
            horizonDays: days
        )
        guard let final = trajectory.last else {
            return .missing(reason: .internalError)
        }
        var rec = projectionRecord(atl: atl0, ctl: ctl0, daily: daily, days: days, final: final)
        let milestones = projectionMilestones(trajectory, days: days)
        if !milestones.isEmpty {
            rec["milestones"] = .record(milestones)
        }
        return .record(rec)
    }

    private func projectionRecord(
        atl atl0: Double,
        ctl ctl0: Double,
        daily: Double,
        days: Int,
        final: TrainingLoadProjection.Day
    ) -> [String: FactValue] {
        [
            "starting_atl": .double(atl0),
            "starting_ctl": .double(ctl0),
            "starting_tsb": .double(ctl0 - atl0),
            "daily_trimp": .double(daily),
            "horizon_days": .integer(days),
            "final_atl": .double(final.atl),
            "final_ctl": .double(final.ctl),
            "final_tsb": .double(final.tsb)
        ]
    }

    // Milestones at common horizons inside the
    // projection (only when within range), so the AI
    // can read intermediate state without a second
    // call.
    private func projectionMilestones(
        _ trajectory: [TrainingLoadProjection.Day],
        days: Int
    ) -> [String: FactValue] {
        var milestones: [String: FactValue] = [:]
        for marker in [7, 14, 28] where marker <= days {
            let day = trajectory[marker - 1]
            milestones["day_\(marker)"] = .record([
                "atl": .double(day.atl),
                "ctl": .double(day.ctl),
                "tsb": .double(day.tsb)
            ])
        }
        return milestones
    }

    private static let trainingProjectFromParamsDescription = """
    GENERAL-PURPOSE projection. Project ATL/CTL/TSB forward from arbitrary starting state. Param format: 'starting_atl,starting_ctl,daily_trimp,horizon_days' — all four numeric. Returns the FINAL day's atl/ctl/tsb plus key milestones \
    (day 7, 14, 28). Use when the AI needs intermediate state for a multi-stage question (e.g. 'if I keep load X until convergence, then switch to Y...'). Use `lookup_fact training.load.snapshot` to read the user's current ATL/CTL \
    as starting state. To find the day of convergence, use `training.days_until_converged_from`.
    """

    private var daysUntilConvergedFromEntry: FactEntry {
        .parameterized(
            pattern: "training.days_until_converged_from($params)",
            paramExample: "65.4,72.1,80,5",
            description: Self.daysUntilConvergedFromDescription,
            resolve: { rawParams, _ in self.resolveTrainingDaysUntilConvergedFromParams(rawParams) }
        )
    }

    private func resolveTrainingDaysUntilConvergedFromParams(_ rawParams: String) -> FactValue {
        let parts = rawParams.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count == 4,
              let atl0 = Double(parts[0]), atl0 >= 0,
              let ctl0 = Double(parts[1]), ctl0 >= 0,
              let daily = Double(parts[2]), daily >= 0,
              let gap = Double(parts[3]), gap > 0
        else {
            return .missing(reason: .invalidParameter, detail: "expected 'starting_atl,starting_ctl,daily_trimp,gap_trimp' all numeric, e.g. '65.4,72.1,80,5'")
        }
        return convergenceRecord(
            atl: atl0, ctl: ctl0, daily: daily, gap: gap,
            unmet: "daily_trimp=\(Int(daily)) won't close gap from this starting state within 60 days — unsustainable load"
        )
    }

    // The two callers report a different `detail` when convergence never
    // happens: the live-state fact blames current fitness, the general-purpose
    // one blames the caller's starting state. The AI reads these strings, so
    // they stay distinct.
    private func convergenceRecord(
        atl atl0: Double,
        ctl ctl0: Double,
        daily: Double,
        gap: Double,
        unmet: String
    ) -> FactValue {
        guard let days = TrainingLoadProjection.daysUntilATLConverges(
            currentATL: atl0,
            currentCTL: ctl0,
            dailyTrimp: daily,
            gapTrimp: gap
        ) else {
            return .missing(reason: .notRecorded, detail: unmet)
        }
        return .record([
            "starting_atl": .double(atl0),
            "starting_ctl": .double(ctl0),
            "daily_trimp": .double(daily),
            "gap_trimp": .double(gap),
            "days_until_converged": .integer(days)
        ])
    }

    private static let daysUntilConvergedFromDescription = """
    GENERAL-PURPOSE convergence helper. Days at the given daily TRIMP from arbitrary starting ATL/CTL until |ATL - CTL| ≤ gap. Param format: 'starting_atl,starting_ctl,daily_trimp,gap_trimp'. Sibling of `training.days_until_atl_converges($daily,$gap)` \
    which uses LIVE current state — this one accepts arbitrary starting state so the AI can chain projections ('how long until convergence from PHASE 1's endpoint at the doubled load'). Returns 0 if already inside the gap. Returns \
    notRecorded if convergence never happens within 60 days from the given state.
    """

    private var trainingProjectedTsbDailyTrimpEntry: FactEntry {
        .parameterized(
            pattern: "training.projected_tsb($daily_trimp)",
            paramExample: "60",
            description: """
            Tomorrow's projected TSB if the user adds the given daily TRIMP load every day (steady-state forecast). Use to answer 'if I keep doing 60 TRIMP days, where does my form land?'. daily_trimp must be a non-negative number. \
            Returns the projected TSB after one day of EWMA decay; for a longer horizon, the AI can reason from the rate of change.
            """,
            resolve: { rawTrimp, _ in self.resolveTrainingProjectedTsbDailyTrimp(rawTrimp) }
        )
    }

    private func resolveTrainingProjectedTsbDailyTrimp(_ rawTrimp: String) -> FactValue {
        guard let trimp = Double(rawTrimp), trimp >= 0 else {
            return .missing(reason: .invalidParameter, detail: "daily_trimp must be a non-negative number")
        }
        guard let live = self.liveOrCached() else {
            return .missing(reason: .notRecorded, detail: "no training-load data yet")
        }
        let projection = TrainingLoadProjection.project(
            startingATL: live.atl,
            startingCTL: live.ctl,
            dailyTrimp: trimp,
            horizonDays: 1
        )
        guard let day = projection.first else {
            return .missing(reason: .internalError)
        }
        return .record(tomorrowRecord(live: live, trimp: trimp, day: day))
    }

    private func tomorrowRecord(
        live: TrainingLoadState,
        trimp: Double,
        day: TrainingLoadProjection.Day
    ) -> [String: FactValue] {
        [
            "starting_atl": .double(live.atl),
            "starting_ctl": .double(live.ctl),
            "starting_tsb": .double(live.tsb),
            "daily_trimp_input": .double(trimp),
            "tomorrow_atl": .double(day.atl),
            "tomorrow_ctl": .double(day.ctl),
            "tomorrow_tsb": .double(day.tsb)
        ]
    }
}
