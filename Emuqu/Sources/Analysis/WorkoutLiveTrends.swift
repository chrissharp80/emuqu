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

    /// Grade-adjusted pace: the flat-ground pace that costs the same energy
    /// as `pace` on `gradePercent`. Returns `pace` unchanged without a grade.
    ///
    /// Uses Minetti et al. (2002)'s cost of running per metre, a quintic in
    /// the grade fraction i: C(i) = 155.4i⁵ − 30.4i⁴ − 43.3i³ + 46.3i² +
    /// 19.5i + 3.6 J/kg/m, divided by the flat cost (3.6) to give a cost
    /// multiplier. A 5 % uphill costs ~30 % more than the flat and a 5 %
    /// downhill ~24 % less; the saving peaks near −20 % (about half the flat
    /// cost) and shrinks on steeper descents, where braking costs energy;
    /// past about −40 % a descent costs more than the flat. The grade is
    /// clipped to ±45 %, the range Minetti measured and fitted the curve on.
    static func gradeAdjustedPaceSecPerKm(pace: Double?, gradePercent: Double?) -> Double? {
        guard let pace, pace > 0 else { return nil }
        guard let g = gradePercent else { return pace }
        let i = max(-45.0, min(45.0, g)) / 100.0
        let cost = 155.4 * pow(i, 5) - 30.4 * pow(i, 4) - 43.3 * pow(i, 3)
            + 46.3 * pow(i, 2) + 19.5 * i + 3.6
        let multiplier = cost / 3.6
        guard multiplier > 0 else { return pace }
        // A costlier grade means the same effort covers ground faster on
        // the flat, so the flat-equivalent pace (sec/km) is shorter.
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
    /// across it (rise over run between the chunk's endpoints). A sample
    /// without an altitude carries the last known altitude forward; the grade
    /// is nil when no altitude is known at either endpoint, so that split is
    /// reported at its raw pace instead of a fabricated grade.
    private static func kilometreSplits(_ samples: [WorkoutSample]) -> [(rawPace: Double, gradePercent: Double?)] {
        var splits: [(rawPace: Double, gradePercent: Double?)] = []
        var start = (dist: 0.0, sec: 0, alt: Double?.none)
        var lastAlt: Double?
        for s in samples {
            guard let d = s.distanceMeters else { continue }
            lastAlt = s.altitudeMeters ?? lastAlt
            if start.alt == nil { start.alt = lastAlt }
            let run = d - start.dist
            guard run >= 1_000 else { continue }
            let rawPace = Double(s.offsetSec - start.sec) / (run / 1_000)
            let grade = splitGrade(from: start.alt, to: lastAlt, run: run)
            splits.append((rawPace, grade))
            start = (d, s.offsetSec, lastAlt)
        }
        return splits
    }

    /// Rise over run in percent, or nil when either altitude is unknown.
    private static func splitGrade(from startAlt: Double?, to endAlt: Double?, run: Double) -> Double? {
        guard let startAlt, let endAlt, run > 0 else { return nil }
        return (endAlt - startAlt) / run * 100.0
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

// MARK: - Live time in zone

/// Live time-in-zone breakdown for the active workout.
/// Walks the per-second sample buffer once and bins HR by percent of the
/// user's max HR (Z1 50–60 %, Z2 60–70 %, Z3 70–80 %, Z4 80–90 %,
/// Z5 90 %+). Time below 50 % of max is not binned. These are the same
/// bands the post-workout summary, the live zone colour and the assistant's
/// reference use, so live and finished time-in-zone agree.
///
/// Lets the AI answer "what zone has most of this run been in?"
/// mid-workout. Cheap (single linear pass over `samples` — typical
/// session is a few thousand entries).
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

    static func compute(samples: [WorkoutSample], userMaxHR: Int) -> WorkoutZoneBreakdown {
        guard userMaxHR > 0, !samples.isEmpty else { return .empty }
        var secs = [0, 0, 0, 0, 0]
        var prevOffset = 0
        for s in samples {
            let dt = max(0, s.offsetSec - prevOffset)
            prevOffset = s.offsetSec
            guard let hr = s.heartRate,
                  let zone = zoneIndex(fractionOfMax: Double(hr) / Double(userMaxHR))
            else { continue }
            secs[zone] += dt
        }
        let total = secs.reduce(0, +)
        return WorkoutZoneBreakdown(
            z1Sec: secs[0], z2Sec: secs[1], z3Sec: secs[2], z4Sec: secs[3], z5Sec: secs[4],
            totalSec: total,
            dominantZone: total > 0 ? (secs.enumerated().max(by: { $0.element < $1.element })?.offset).map { $0 + 1 } : nil
        )
    }

    /// Zero-based zone for a heart rate as a fraction of max HR; nil below 50 %.
    private static func zoneIndex(fractionOfMax pct: Double) -> Int? {
        switch pct {
        case ..<0.50: nil
        case ..<0.60: 0
        case ..<0.70: 1
        case ..<0.80: 2
        case ..<0.90: 3
        default: 4
        }
    }
}

/// Riegel race-time predictions. Given one of the user's efforts at
/// one distance, predict their time at another using
/// `T2 = T1 × (D2 / D1)^1.06`. The 1.06 exponent is the commonly-used
/// "fatigue factor" for trained runners; pure flat extrapolation (1.00)
/// is too optimistic past the original distance.
///
/// Each target distance gets its own basis. Only sport-matched efforts of
/// at least `minimumBasisMeters` count. Efforts from the last
/// `recentWindowDays` days are preferred over older ones; within that pool,
/// efforts within ±20 % of the target distance are preferred over the rest.
/// The basis is the effort in the chosen pool that predicts the fastest
/// time. Returns an empty map when no effort qualifies.
enum RaceTimePrediction {
    /// Distances the predictor produces. Fixed at the canonical race
    /// ladder so the AI's tool catalog can describe them up-front.
    static let standardDistancesMeters: [Double] = [
        5_000,      // 5K
        10_000,     // 10K
        21_097.5,   // half marathon
        42_195      // marathon
    ]

    /// Shortest effort used as a basis. A 1 km sprint extrapolated to a
    /// marathon wildly overstates endurance.
    static let minimumBasisMeters: Double = 3_000
    static let recentWindowDays: Double = 90
    /// Share of the target distance an effort may differ by and still count
    /// as "comparable" (±20 %).
    static let comparableDistanceTolerance = 0.20
    /// Riegel's endurance exponent.
    static let exponent = 1.06

    /// The effort a prediction was extrapolated from.
    struct Basis: Equatable, Sendable {
        let distanceMeters: Double
        let durationSec: Double
        let date: Date
    }

    struct Prediction: Equatable, Sendable {
        let totalSec: Double
        let basis: Basis
    }

    /// Predicted total seconds per standard distance (meters).
    static func predict(
        from sessions: [HRVSession],
        sport: Sport,
        now: Date = Date()
    ) -> [Double: Double] {
        predictWithBasis(from: sessions, sport: sport, now: now).mapValues(\.totalSec)
    }

    /// Predictions per standard distance, each with the effort it came from.
    static func predictWithBasis(
        from sessions: [HRVSession],
        sport: Sport,
        now: Date = Date()
    ) -> [Double: Prediction] {
        let pool = candidatePool(from: sessions, sport: sport, now: now)
        guard !pool.isEmpty else { return [:] }
        var out: [Double: Prediction] = [:]
        for target in standardDistancesMeters {
            let comparable = pool.filter {
                abs($0.distanceMeters - target) <= target * comparableDistanceTolerance
            }
            let predictions = (comparable.isEmpty ? pool : comparable).map { basis in
                Prediction(totalSec: riegel(basis, to: target), basis: basis)
            }
            out[target] = predictions.min { $0.totalSec < $1.totalSec }
        }
        return out
    }

    private static func riegel(_ basis: Basis, to target: Double) -> Double {
        basis.durationSec * pow(target / basis.distanceMeters, exponent)
    }

    /// Qualifying efforts from the recent window, or from all history when
    /// the window has none.
    private static func candidatePool(from sessions: [HRVSession], sport: Sport, now: Date) -> [Basis] {
        let all: [Basis] = sessions.compactMap { s in
            guard s.workoutMetadata?.sport == sport,
                  let dur = s.duration, dur > 0,
                  let dist = s.workoutMetadata?.distanceMeters, dist >= minimumBasisMeters
            else { return nil }
            return Basis(distanceMeters: dist, durationSec: dur, date: s.startDate)
        }
        let cutoff = now.addingTimeInterval(-recentWindowDays * 86_400)
        let recent = all.filter { $0.date >= cutoff }
        return recent.isEmpty ? all : recent
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

// MARK: - Forward-looking training load projection
//
// Extends the post-finalize ATL/CTL/TSB Banister model into a "what does
// tomorrow look like?" surface for the AI coach, so it can answer "should
// I push tomorrow or take it easy?" with numbers instead of guessing from
// today's score alone.

/// Garmin-style "hours of recovery needed" estimate derived from the
/// user's training load: the whole days of complete rest until TSB is back
/// to ≥ 0 under the Banister projection, expressed in hours.
enum RecoveryTimeEstimate {
    /// Hours of recovery needed before TSB returns to ≥ 0 at zero
    /// added load. nil when already fresh, when an input is missing, or
    /// when freshness is more than 30 days away.
    static func hoursFromTrainingLoad(atl: Double?, ctl: Double?) -> Double? {
        guard let atl, let ctl, atl > ctl else { return nil }
        // Days-until-fresh from the projection model is exact for the
        // EWMA decay; whole days converted to hours.
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
    /// `dailyTrimp = 0` rest pattern. 0 when already fresh; nil when
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
