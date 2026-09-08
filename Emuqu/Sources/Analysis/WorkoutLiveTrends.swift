import Foundation

/// Stateless helpers that derive mid-workout trend metrics from the
/// in-memory `WorkoutSample` buffer: reverse-split delta, HR drift,
/// aerobic decoupling, cadence drift, grade-adjusted pace.
///
/// Kept off `WorkoutRecorder` so the recorder file (already large)
/// stays focused on lifecycle and hardware coordination. All functions
/// return nil when the buffer is too small for the metric to be
/// meaningful — the AI context surfaces nil and the voice coach skips
/// the trend line rather than speaking a confident wrong number.
enum WorkoutLiveTrends {
    /// Minimum total elapsed seconds before any half-vs-half metric
    /// (reverse split, decoupling) starts emitting. Below this the
    /// "first half" is too short to be a baseline.
    static let halfMetricsMinSeconds: Int = 600 // 10 minutes

    /// Minimum elapsed seconds before HR drift / cadence drift become
    /// meaningful. Lower than the half metrics because a quartile is
    /// shorter and HR settles in 5-7 min.
    static let driftMetricsMinSeconds: Int = 420 // 7 minutes

    /// Average pace from the second half of the captured samples
    /// minus the average pace from the first half, in sec/km.
    /// Negative result = running FASTER in the second half (a true
    /// "negative split"). Positive = slowing down.
    static func reverseSplitDeltaSecPerKm(samples: [WorkoutSample]) -> Double? {
        guard let last = samples.last, last.offsetSec >= halfMetricsMinSeconds else { return nil }
        let mid = last.offsetSec / 2
        let firstPaces = samples.filter { $0.offsetSec < mid }.compactMap { $0.paceSecPerKm }
        let secondPaces = samples.filter { $0.offsetSec >= mid }.compactMap { $0.paceSecPerKm }
        guard firstPaces.count >= 30, secondPaces.count >= 30 else { return nil }
        let firstAvg = firstPaces.reduce(0, +) / Double(firstPaces.count)
        let secondAvg = secondPaces.reduce(0, +) / Double(secondPaces.count)
        return secondAvg - firstAvg
    }

    /// HR drift: average HR in the most recent quarter compared to the
    /// average HR in the first quarter, expressed as a percentage of
    /// the first-quarter baseline. Positive = drift up (fatigue),
    /// negative = recovery / cooler effort.
    ///
    /// Pace-matching is intentionally simple here: we don't try to
    /// match same-pace samples. The AI gets enough context (current
    /// pace + first-quarter pace) to caveat the drift number itself
    /// when pace has changed. Trying to pace-match in a 10 µs hot
    /// loop produces noisy results in real-world sample buffers.
    static func hrDriftPercent(samples: [WorkoutSample]) -> Double? {
        guard let last = samples.last, last.offsetSec >= driftMetricsMinSeconds else { return nil }
        let q = last.offsetSec / 4
        guard q > 0 else { return nil }
        let firstQuartileHRs = samples.filter { $0.offsetSec < q }.compactMap { $0.heartRate }
        let lastQuartileHRs = samples.filter { $0.offsetSec >= 3 * q }.compactMap { $0.heartRate }
        guard firstQuartileHRs.count >= 30, lastQuartileHRs.count >= 30 else { return nil }
        let firstAvg = Double(firstQuartileHRs.reduce(0, +)) / Double(firstQuartileHRs.count)
        let lastAvg = Double(lastQuartileHRs.reduce(0, +)) / Double(lastQuartileHRs.count)
        guard firstAvg > 0 else { return nil }
        return ((lastAvg - firstAvg) / firstAvg) * 100.0
    }

    /// Aerobic decoupling: percentage change in pace/HR efficiency
    /// from the first half to the second half. Uses speed (1/pace)
    /// over HR so a higher second-half ratio means MORE efficient
    /// (lower HR for same speed). The reported number is the
    /// percentage drop; positive = decoupling has occurred.
    static func aerobicDecouplingPercent(samples: [WorkoutSample]) -> Double? {
        guard let last = samples.last, last.offsetSec >= halfMetricsMinSeconds else { return nil }
        let mid = last.offsetSec / 2

        func efficiency(in slice: [WorkoutSample]) -> Double? {
            let valid = slice.filter { ($0.heartRate ?? 0) > 0 && ($0.paceSecPerKm ?? 0) > 0 }
            guard valid.count >= 30 else { return nil }
            // pace sec/km → m/sec speed: 1000 / pace.
            let speeds = valid.map { 1_000.0 / ($0.paceSecPerKm ?? 1) }
            let hrs = valid.compactMap { $0.heartRate.map(Double.init) }
            let avgSpeed = speeds.reduce(0, +) / Double(speeds.count)
            let avgHR = hrs.reduce(0, +) / Double(hrs.count)
            guard avgHR > 0 else { return nil }
            return avgSpeed / avgHR
        }

        guard let firstEff = efficiency(in: samples.filter { $0.offsetSec < mid }),
              let secondEff = efficiency(in: samples.filter { $0.offsetSec >= mid }),
              firstEff > 0
        else { return nil }
        return ((firstEff - secondEff) / firstEff) * 100.0
    }

    /// bpm slope over the last ~90 seconds.
    /// Compares the most-recent 30-second HR average against the
    /// average from 60-90 seconds ago. Positive = HR currently rising;
    /// negative = HR currently falling. Used by `hr.driftHigh` to
    /// suppress alerts whose long-window drift is positive but whose
    /// instantaneous direction has reversed (e.g. user finished a
    /// climb, is now descending and HR is recovering — long-window
    /// drift still says "+6%" but the live signal says "falling").
    /// Returns nil before 90 seconds of samples or when fewer than 10
    /// HR readings land in either window.
    static func recentHRSlopeBpm(samples: [WorkoutSample]) -> Double? {
        guard let last = samples.last, last.offsetSec >= 90 else { return nil }
        let recentStart = last.offsetSec - 30
        let priorEnd = last.offsetSec - 60
        let priorStart = last.offsetSec - 90
        let recent = samples
            .filter { $0.offsetSec > recentStart }
            .compactMap { $0.heartRate.map(Double.init) }
        let prior = samples
            .filter { $0.offsetSec > priorStart && $0.offsetSec <= priorEnd }
            .compactMap { $0.heartRate.map(Double.init) }
        guard recent.count >= 10, prior.count >= 10 else { return nil }
        let recentAvg = recent.reduce(0, +) / Double(recent.count)
        let priorAvg = prior.reduce(0, +) / Double(prior.count)
        return recentAvg - priorAvg
    }

    /// Cadence drift in steps-per-minute: current quarter average
    /// minus first-quarter average. Negative = stride breaking down.
    static func cadenceDriftSpm(samples: [WorkoutSample]) -> Double? {
        guard let last = samples.last, last.offsetSec >= driftMetricsMinSeconds else { return nil }
        let q = last.offsetSec / 4
        guard q > 0 else { return nil }
        let firstCadences = samples.filter { $0.offsetSec < q }.compactMap { $0.cadenceStepsPerMin }
        let lastCadences = samples.filter { $0.offsetSec >= 3 * q }.compactMap { $0.cadenceStepsPerMin }
        guard firstCadences.count >= 30, lastCadences.count >= 30 else { return nil }
        let firstAvg = firstCadences.reduce(0, +) / Double(firstCadences.count)
        let lastAvg = lastCadences.reduce(0, +) / Double(lastCadences.count)
        return lastAvg - firstAvg
    }

    /// Grade-adjusted pace using Strava-style coefficients. Given a
    /// raw pace in sec/km and current grade in %, returns the
    /// flat-equivalent pace (sec/km). Coefficients clipped to
    /// ±30 % grade — beyond that the polynomial overshoots.
    ///
    /// Reference: the Minetti running-energy curve fitted to a
    /// quintic polynomial. A 5 % uphill costs ~17 % more energy at
    /// the same speed; a 5 % downhill saves ~10 %.
    static func gradeAdjustedPaceSecPerKm(pace: Double?, gradePercent: Double?) -> Double? {
        guard let pace, pace > 0 else { return nil }
        guard let g = gradePercent else { return pace }
        let grade = max(-30.0, min(30.0, g))
        // Minetti coefficients (Strava-style polynomial). Output is a
        // multiplier; pace divided by the multiplier gives the
        // flat-equivalent pace (faster grade = larger multiplier).
        let x = grade / 100.0
        let multiplier = 1.0
            + 5.294 * x
            + 33.7 * pow(x, 2)
            + -72.0 * pow(x, 3)
            + 39.0 * pow(x, 4)
        guard multiplier > 0 else { return pace }
        return pace / multiplier
    }

    /// Recent 1 km splits with EACH split's pace grade-adjusted using
    /// the average altitude delta over that split. Index 0 = most
    /// recent. Up to last 3 completed splits returned.
    ///
    /// The voice coach already gets `recentSplitPaces` (raw) — this is
    /// the elevation-aware companion so the AI can answer "your last
    /// split was actually 5:10/km flat-equivalent even though the
    /// watch said 4:30 — that downhill was free speed."
    static func recentSplitGradeAdjustedPaces(samples: [WorkoutSample]) -> [Double] {
        kilometreSplits(samples).suffix(3).reversed().compactMap { entry in
            gradeAdjustedPaceSecPerKm(pace: entry.rawPace, gradePercent: entry.gradePercent)
        }
    }

    /// Completed 1 km chunks, each with its raw pace and the average grade
    /// across it (rise over run between the chunk's endpoints).
    private static func kilometreSplits(_ samples: [WorkoutSample]) -> [(rawPace: Double, gradePercent: Double)] {
        guard !samples.isEmpty else { return [] }
        var splits: [(rawPace: Double, gradePercent: Double)] = []
        var chunkStartDist = 0.0
        var chunkStartSec = 0
        var chunkStartAlt: Double?
        for s in samples {
            guard let d = s.distanceMeters else { continue }
            if chunkStartAlt == nil { chunkStartAlt = s.altitudeMeters }
            if d - chunkStartDist >= 1_000 {
                let rawPace = Double(s.offsetSec - chunkStartSec) / ((d - chunkStartDist) / 1_000)
                let rise = (s.altitudeMeters ?? 0) - (chunkStartAlt ?? 0)
                let run = d - chunkStartDist
                let grade = run > 0 ? (rise / run) * 100.0 : 0.0
                splits.append((rawPace, grade))
                chunkStartDist = d
                chunkStartSec = s.offsetSec
                chunkStartAlt = s.altitudeMeters
            }
        }
        return splits
    }

    /// Heuristic time-to-fade estimate in minutes. Given the rolling
    /// HR drift % and α1 trajectory, project how long the user can
    /// hold the current effort before HR drift hits 10 % (the
    /// generally-cited threshold past which fatigue compounds rapidly).
    ///
    /// Method: linear extrapolation of HR drift over the last quarter
    /// of the workout. If drift is negative or flat, returns nil
    /// (sustainable indefinitely at this effort). Fundamentally a
    /// rough estimate — physiology is non-linear and the real answer
    /// depends on fueling, terrain, heat. Surfaced as "rough" via the
    /// description in the AI tool catalog.
    static func projectedMinutesUntilFade(
        samples: [WorkoutSample],
        currentDriftPercent: Double?
    ) -> Double? {
        guard let drift = currentDriftPercent, drift > 1.0 else { return nil }
        guard let last = samples.last, last.offsetSec >= driftMetricsMinSeconds * 2 else { return nil }
        // Drift accumulated from quartile 1 to quartile 4 over
        // (3/4)*elapsed minutes. Extrapolate: minutes to reach 10 %
        // drift = (10 − currentDrift) / driftRate.
        let elapsedMin = Double(last.offsetSec) / 60.0
        let driftSpanMin = elapsedMin * 0.75
        guard driftSpanMin > 0 else { return nil }
        let driftRatePerMin = drift / driftSpanMin
        guard driftRatePerMin > 0.05 else { return nil } // floor: no real trend
        let remainingDrift = 10.0 - drift
        guard remainingDrift > 0 else { return 0 }
        let projected = remainingDrift / driftRatePerMin
        // Clamp to reasonable range — the linear model breaks down
        // past ~3 hours, and "100 hours until fade" is misleading.
        return max(1.0, min(180.0, projected))
    }
}

// MARK: - Forward-looking training load projection
//
// Extends the existing post-finalize ATL/CTL/TSB Banister
// model into a "what does tomorrow look like?" surface for the AI
// coach. Lets the AI answer "should I push tomorrow or take it easy?"
// with real numbers instead of guessing from today's score alone.

/// Live time-in-zone breakdown for the active workout.
/// Walks the per-second sample buffer once and bins HR by Karvonen
/// 5-zone breakpoints (50/60/70/80/90 % HRR). Returns seconds in
/// each zone plus the dominant zone label.
///
/// The post-summary already computes this from the finalized session;
/// this is the LIVE counterpart so the AI can answer "what zone has
/// most of this run been in?" mid-workout. Cheap (single linear
/// pass over `samples` — typical session is a few thousand entries).
struct WorkoutZoneBreakdown: Equatable {
    let z1Sec: Int
    let z2Sec: Int
    let z3Sec: Int
    let z4Sec: Int
    let z5Sec: Int
    let totalSec: Int
    /// Most-time-in zone (1-5). Nil when all zones are zero.
    let dominantZone: Int?

    static let empty = WorkoutZoneBreakdown(
        z1Sec: 0, z2Sec: 0, z3Sec: 0, z4Sec: 0, z5Sec: 0,
        totalSec: 0, dominantZone: nil
    )

    static func compute(
        samples: [WorkoutSample],
        userMaxHR: Int,
        userRestingHR: Int
    ) -> WorkoutZoneBreakdown {
        guard userMaxHR > userRestingHR, !samples.isEmpty else { return .empty }
        var secs = [0, 0, 0, 0, 0]
        var prevOffset = 0
        for s in samples {
            let dt = max(0, s.offsetSec - prevOffset)
            prevOffset = s.offsetSec
            guard let hr = s.heartRate, hr > userRestingHR else { continue }
            let pct = Double(hr - userRestingHR) / Double(userMaxHR - userRestingHR)
            secs[Self.karvonenZoneIndex(hrReserveFraction: pct)] += dt
        }
        let total = secs.reduce(0, +)
        return WorkoutZoneBreakdown(
            z1Sec: secs[0], z2Sec: secs[1], z3Sec: secs[2], z4Sec: secs[3], z5Sec: secs[4],
            totalSec: total,
            dominantZone: total > 0 ? (secs.enumerated().max(by: { $0.element < $1.element })?.offset).map { $0 + 1 } : nil
        )
    }

    /// 5-zone Karvonen: 50/60/70/80/90 % HRR.
    private static func karvonenZoneIndex(hrReserveFraction pct: Double) -> Int {
        switch pct {
        case ..<0.50: 0
        case ..<0.60: 1
        case ..<0.70: 2
        case ..<0.80: 3
        default: 4
        }
    }
}

/// Riegel race-time predictions. Given the user's best
/// recent performance at one distance, predict their time at another
/// using `T2 = T1 × (D2 / D1)^1.06`. The 1.06 exponent is the
/// commonly-used "fatigue factor" for trained runners; pure flat
/// extrapolation (1.00) is too optimistic past the original distance.
///
/// Source candidates (best of, in priority order): saved PR overrides,
/// then fastest workout in last 90 days within ±20 % of target, then
/// best-of-all-time matching sport. Returns nil when no comparable
/// effort exists in the history.
enum RaceTimePrediction {
    /// Distances the predictor produces. Fixed at the canonical race
    /// ladder so the AI's tool catalog can describe them up-front.
    static let standardDistancesMeters: [Double] = [
        5_000,      // 5K
        10_000,     // 10K
        21_097.5,   // half marathon
        42_195      // marathon
    ]

    /// Predict times at every standard distance from the best
    /// per-distance basis in `sessions`. Returns a map of distance
    /// (meters) → predicted total seconds.
    static func predict(
        from sessions: [HRVSession],
        sport: Sport
    ) -> [Double: Double] {
        guard let basis = fastestBasis(from: sessions, sport: sport) else { return [:] }
        // Riegel's endurance exponent.
        let exponent = 1.06
        var out: [Double: Double] = [:]
        for target in standardDistancesMeters {
            out[target] = basis.duration * pow(target / basis.distance, exponent)
        }
        return out
    }

    /// A per-distance "best pace" basis: the session with the LOWEST sec/m
    /// (= fastest), regardless of which distance it was run at.
    private static func fastestBasis(
        from sessions: [HRVSession],
        sport: Sport
    ) -> (distance: Double, duration: Double, secPerMeter: Double)? {
        let scored: [(distance: Double, duration: Double, secPerMeter: Double)] = sessions
            .filter { $0.workoutMetadata?.sport == sport }
            .filter { ($0.duration ?? 0) > 0 && ($0.workoutMetadata?.distanceMeters ?? 0) > 1_000 }
            .compactMap { s in
                guard let dur = s.duration, dur > 0,
                      let dist = s.workoutMetadata?.distanceMeters, dist > 0
                else { return nil }
                return (dist, dur, dur / dist)
            }
        return scored.min(by: { $0.secPerMeter < $1.secPerMeter })
    }
}

/// Training pace zones derived from a benchmark race
/// time, à la Jack Daniels' VDOT system. Returns sec/km per zone:
///   • easy — long-run / aerobic base (60–79 % vVO2max)
///   • marathon — half / marathon goal pace (~84 %)
///   • threshold — tempo / cruise intervals (~88 %)
///   • interval — VO2max efforts (~98–100 %)
///   • repetition — speed work (~105 %)
///
/// Derived from a 5K basis: easy = 5K_pace × 1.30, marathon = ×1.15,
/// threshold = ×1.10, interval = ×1.00, repetition = ×0.93. These
/// match Daniels' VDOT 35–55 zones within ~3 sec/km — accurate
/// enough for AI-readable training-pace recommendations without
/// needing a full VDOT lookup table.
struct TrainingPaceZones: Equatable {
    let easySecPerKm: Double
    let marathonSecPerKm: Double
    let thresholdSecPerKm: Double
    let intervalSecPerKm: Double
    let repetitionSecPerKm: Double

    /// Build zones from a 5K race-pace basis (sec/km).
    static func from5KPace(secPerKm: Double) -> TrainingPaceZones? {
        guard secPerKm > 0 else { return nil }
        return TrainingPaceZones(
            easySecPerKm: secPerKm * 1.30,
            marathonSecPerKm: secPerKm * 1.15,
            thresholdSecPerKm: secPerKm * 1.10,
            intervalSecPerKm: secPerKm * 1.00,
            repetitionSecPerKm: secPerKm * 0.93
        )
    }

    /// Build zones from a Riegel race-prediction map (5K key in
    /// meters). Returns nil when the 5K prediction is missing.
    static func from(racePredictions: [Double: Double]) -> TrainingPaceZones? {
        guard let totalSec = racePredictions[5_000] else { return nil }
        return from5KPace(secPerKm: totalSec / 5.0)
    }
}

/// Garmin-style "hours of recovery needed" estimate
/// derived from the user's training load. Heuristic: at TSB ≥ 0 the
/// user is fresh (0 hours). At deeper negative TSB, hours scale
/// roughly with how far below 0 they are, scaled by ATL magnitude
/// (a high-ATL athlete at TSB -10 is more cooked than a beginner at
/// TSB -10).
enum RecoveryTimeEstimate {
    /// Hours of recovery needed before TSB returns to ≥ 0 at zero
    /// added load. nil when already fresh OR no inputs.
    static func hoursFromTrainingLoad(atl: Double?, ctl: Double?) -> Double? {
        guard let atl, let ctl, atl > ctl else { return nil }
        // Days-until-fresh from the projection model is exact for the
        // EWMA decay; convert to hours and round to nearest 30 min.
        guard let days = TrainingLoadProjection.daysUntilFresh(currentATL: atl, currentCTL: ctl) else {
            return nil
        }
        return Double(days) * 24.0
    }
}

enum TrainingLoadProjection {
    /// One day of the projected trajectory.
    struct Day: Equatable {
        let daysFromNow: Int
        let atl: Double
        let ctl: Double
        var tsb: Double { ctl - atl }
    }

    /// Project ATL / CTL / TSB forward `horizon` days assuming the
    /// user adds `dailyTrimp` of training load each day. Banister
    /// EWMA decay constants: ATL τ=7d, CTL τ=42d.
    ///
    /// A `dailyTrimp = 0` projection is the "rest week" forecast —
    /// shows how fast freshness recovers without further work. The
    /// `dailyTrimp = todayTrimp` projection shows "if I keep doing
    /// this every day, where do I end up?".
    static func project(
        startingATL: Double,
        startingCTL: Double,
        dailyTrimp: Double,
        horizonDays: Int = 7
    ) -> [Day] {
        // Exact EWMA step: X = load·(1−e^(−1/τ)) + X_prev·e^(−1/τ), τ centralized
        // in TrainingConstants.EWMA (ATL 7d, CTL 42d). NOT the
        // LINEAR 1/τ approximation (`x += (load−x)/τ`), which the
        // rest of the CTL/ATL system does not use (see the note in
        // TrainingHealthQueries.computeEWMA): it leaves this forward projection
        // ~7% off the very ATL it's seeded from, so "days until fresh" and the AI
        // projection tools would compute on different physics than the CTL/TSB they
        // extend. Byte-identical to the live/historical model.
        let atlDecay = exp(-1.0 / Double(TrainingConstants.EWMA.acuteDays))
        let ctlDecay = exp(-1.0 / Double(TrainingConstants.EWMA.chronicDays))
        var atl = startingATL
        var ctl = startingCTL
        var days: [Day] = []
        for offset in 1 ... max(1, horizonDays) {
            atl = dailyTrimp * (1 - atlDecay) + atl * atlDecay
            ctl = dailyTrimp * (1 - ctlDecay) + ctl * ctlDecay
            days.append(Day(daysFromNow: offset, atl: atl, ctl: ctl))
        }
        return days
    }

    /// Days until TSB returns to ≥ 0 (freshness restored) given a
    /// `dailyTrimp = 0` rest pattern. nil when already fresh OR when
    /// the user is so deeply fatigued that recovery would take >30
    /// days (signal: take a real off-week).
    static func daysUntilFresh(currentATL: Double, currentCTL: Double) -> Int? {
        guard currentATL > currentCTL else { return 0 }
        let projection = project(
            startingATL: currentATL,
            startingCTL: currentCTL,
            dailyTrimp: 0,
            horizonDays: 30
        )
        return projection.first { $0.tsb >= 0 }?.daysFromNow
    }

    /// Days at the given daily TRIMP load until ATL
    /// converges within `gapTrimp` units of CTL (i.e. |ATL - CTL| ≤
    /// gap). Used by the AI tool that answers "how long at this
    /// volume until I'm in the adaptive zone?". When the user is
    /// already inside the gap, returns 0. Returns nil if the gap is
    /// never reached within `horizonDays` (signal that the chosen
    /// daily load is unsustainable at the user's current fitness —
    /// ATL outruns CTL forever).
    static func daysUntilATLConverges(
        currentATL: Double,
        currentCTL: Double,
        dailyTrimp: Double,
        gapTrimp: Double,
        horizonDays: Int = 60
    ) -> Int? {
        if abs(currentATL - currentCTL) <= gapTrimp { return 0 }
        let projection = project(
            startingATL: currentATL,
            startingCTL: currentCTL,
            dailyTrimp: dailyTrimp,
            horizonDays: horizonDays
        )
        return projection.first { abs($0.atl - $0.ctl) <= gapTrimp }?.daysFromNow
    }
}

/// Cross-workout history baselines computed once from the user's
/// archived sessions matching the active workout's sport. Cheap
/// enough to recompute when needed but the recorder caches once at
/// workout start so per-tick `buildContext` calls don't re-iterate.
struct WorkoutHistoryBaselines: Equatable {
    let sport: Sport
    /// Distance-weighted average pace across the matched window.
    let avgPaceSecPerKm: Double?
    /// Sample-weighted average HR across matched workouts that
    /// captured HR samples.
    let avgHR: Double?
    /// Sample-weighted average α1 across matched workouts that
    /// captured α1.
    let avgAlpha1: Double?
    /// Number of matched workouts that contributed any data.
    let sampleCount: Int

    static let empty = WorkoutHistoryBaselines(
        sport: .run,
        avgPaceSecPerKm: nil,
        avgHR: nil,
        avgAlpha1: nil,
        sampleCount: 0
    )

    /// Build from an array of historical sessions. Filters to the
    /// matching sport, keeps the most-recent `limit` matches, then
    /// aggregates. Returns `.empty` (sampleCount = 0) when no
    /// matches exist so callers can branch on `count > 0` rather
    /// than handling nil.
    static func compute(
        from sessions: [HRVSession],
        sport: Sport,
        limit: Int = 30
    ) -> WorkoutHistoryBaselines {
        let matches = sessions
            .filter { $0.sessionType == .workout }
            .filter { $0.workoutMetadata?.sport == sport }
            .sorted { $0.startDate > $1.startDate }
            .prefix(limit)
        guard !matches.isEmpty else {
            return WorkoutHistoryBaselines(
                sport: sport, avgPaceSecPerKm: nil,
                avgHR: nil, avgAlpha1: nil, sampleCount: 0
            )
        }
        let sampleAverages = sampleWeightedAverages(Array(matches))
        return WorkoutHistoryBaselines(
            sport: sport,
            avgPaceSecPerKm: distanceWeightedPace(Array(matches)),
            avgHR: sampleAverages.hr,
            avgAlpha1: sampleAverages.alpha1,
            sampleCount: matches.count
        )
    }

    /// Total time over total distance (sec/km), so a long slow run doesn't
    /// count the same as a short fast one. Sessions too short to be meaningful
    /// are excluded from both sides of the ratio.
    private static func distanceWeightedPace(_ matches: [HRVSession]) -> Double? {
        var totalDist: Double = 0
        var totalDur: Double = 0
        for s in matches {
            guard let dist = s.workoutMetadata?.distanceMeters, dist > 100,
                  let dur = s.duration, dur > 60 else { continue }
            totalDist += dist
            totalDur += dur
        }
        return totalDist > 100 ? (totalDur * 1_000.0 / totalDist) : nil
    }

    /// Mean HR and α1 across every sample in the matched sessions, so a longer
    /// session contributes proportionally more.
    private static func sampleWeightedAverages(_ matches: [HRVSession]) -> (hr: Double?, alpha1: Double?) {
        let samples = matches.flatMap { $0.workoutMetadata?.samples ?? [] }
        let hrs = samples.compactMap(\.heartRate).filter { $0 > 0 }.map(Double.init)
        let alphas = samples.compactMap(\.alpha1).filter { $0 > 0 }
        return (Self.mean(hrs), Self.mean(alphas))
    }

    private static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
