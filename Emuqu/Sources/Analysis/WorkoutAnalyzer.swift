import CoreLocation
import Foundation

// MARK: - Workout Analyzer
//
// Pure-value transforms that turn an RR stream + GPS track into a populated
// WorkoutMetadata. Called from WorkoutRecorder.finalizeSession before archive
// write so persisted sessions carry metrics end-to-end.
//
// Metrics produced here:
//   • Banister TRIMP — exponential, HRR-based, sex-aware. Persisted in the
//     `luciaTRIMP` field (misnamed field retained for schema compat; a
//     future migration can rename).
//   • hrTSS — HRSS formulation: session TRIMP ÷ 1-hour-at-LTHR TRIMP × 100.
//   • Pa:Hr decoupling — first-half vs second-half pace/HR efficiency drift
//   • Efficiency factor — normalized-pace / avg HR for the session
//   • Splits — auto-emitted every 1 km (metric) or 1 mile (imperial)
//   • gpsPolyline — Google-style polyline encoding of the track
//
// HRR capture is a separate service (HRRCaptureService) because it needs a
// live post-stop window, not a retrospective pass over data.
//
// ─────────────────────────────────────────────────────────────────
// SCIENTIFIC BASIS (what's implemented and why):
//
// TRIMP (Banister 1991):
//   • Formula: TRIMP = Σ (dur_min × HRR × A × e^(k·HRR))
//   • Male:   A = 0.64, k = 1.92
//   • Female: A = 0.86, k = 1.67
//     From Banister's original sex-split lactate-HR regressions. Yes, the
//     sex binary is 1970s-era; more recent work (Manresa-Rocamora 2021 and
//     others) shows individual variability exceeds the male/female gap,
//     but a properly-individual TRIMPi (Manzi 2009, r = 0.77-0.87 with
//     race performance) requires lab blood-lactate testing users don't
//     have. Banister's coefficients are the best accepted defaults when
//     we only have HR + HRmax + HRrest.
//   • HRR = (HR − HRrest) / (HRmax − HRrest) — Karvonen heart-rate reserve.
//     Accounts for resting HR, which Edwards's %HRmax zone method ignores
//     (a fit person with resting HR 50 and a novice with resting HR 75 at
//     the same HR 150 are NOT doing the same internal work).
//   • Range: 0-4.37 TRIMP/min male, 0-3.4 TRIMP/min female.
//   • Continuous integration, not zoned — no spurious jumps across zone
//     lines (a limitation of Edwards's method cited across the literature).
//
// hrTSS (HRSS formulation):
//   • Formula: hrTSS = (session TRIMP / 1hr-at-LTHR TRIMP) × 100
//   • Rationale: TSS's canonical meaning is "1 hour at threshold = 100".
//     TrainingPeaks's actual proprietary formula isn't published; this
//     HRSS derivation (Fellrnr; intervals.icu uses an equivalent method)
//     reaches the same definitional endpoint using Banister on the
//     reference-hour baseline. Cleaner than `duration × IF² × 100`
//     (which was my first implementation — definitionally correct only
//     for mid-range intensities, and breaks down at the tails).
//   • Requires HRmax and HRrest; returns nil rather than guess if either is
//     missing. LTHR is OPTIONAL and falls back to 0.88 × HRmax (see below).
//     `WorkoutAnalyzerMathTests` pins this behaviour.
//
// LTHR:
//   • User override preferred. Friel's 30-min TT / last-20-min-avg
//     protocol is the gold standard; he explicitly rejects %HRmax
//     heuristics ("do not use 220-age... as likely wrong as right").
//   • Heuristic fallback: 0.88 × HRmax (midpoint of Friel's 85-90 %
//     band for fit endurance athletes).
//   • NEW: Rogers & Gronwald 2021 showed DFA α1 crossing 0.75 during
//     exercise corresponds to VT1 within ~2 bpm on average (ICC 0.96 for
//     HR in 15 men; individual limits about ±10 bpm, weaker in later
//     cohorts — see the LiveDFAAnalyzer header). The post-summary
//     surfaces this HR as a LT1 estimate so the user can choose to
//     update their LTHR setting to a validated-source anchor. We do
//     NOT auto-modify TRIMP inputs; user keeps control.
//
// What's NOT implemented and why:
//   • Lucia TRIMP (2003, 3-zone VT-based) — published but "no training
//     study on Lucia's method has been conducted to validate it by
//     demonstrating dose-response relationships" (Fellrnr review).
//   • Edwards TRIMP (1993, 5-zone %HRmax) — kept only as the fallback
//     when HRrest is unknown. Known limitations: arbitrary zone
//     boundaries, linear weighting understates high-intensity cost.
//   • Stagno modified TRIMP (2007) — validated for team sports
//     (correlation with ΔVO2max r = 0.8) but uses group-average zone
//     weights; no real advantage over Banister for endurance.
//   • Power-TSS — gold standard for cycling / power-meter running,
//     needs FTP anchor we don't yet collect.
//   • TRIMPi (Manzi 2009) — most predictive (r=0.77-0.87) but needs
//     blood lactate testing.
//
// Source links (as of April 2026):
//   • Banister:    https://fellrnr.com/wiki/TRIMP
//   • Lucia (and validation gap): https://www.trainingimpulse.com/lucias-trimp-0
//   • Manzi TRIMPi: https://pubmed.ncbi.nlm.nih.gov/19812506/
//   • Rogers & Gronwald α1 2021: https://pmc.ncbi.nlm.nih.gov/articles/PMC7845545/
//   • 2024 α1 replication:       https://www.frontiersin.org/journals/physiology/articles/10.3389/fphys.2024.1329360/full
//   • Friel LTHR protocol:       https://www.trainingpeaks.com/learn/articles/joe-friel-s-quick-guide-to-setting-zones/
// ─────────────────────────────────────────────────────────────────
enum WorkoutAnalyzer {
    // MARK: - Public entry point

    /// Compute all workout-flavoured metrics from the raw inputs.
    /// - Parameters:
    ///   - rrPoints: RR interval points captured during the session.
    ///   - startDate: Absolute session start (used to align GPS fixes).
    ///   - track: GPS fixes, in chronological order. Empty for indoor sports.
    ///   - userMaxHR: User's physiological max HR (from Settings, 220-age fallback).
    ///     Used as the canonical denominator for %HRmax zoning. Session-peak fallback
    ///     only when this is nil — which it never is in practice, but keeps the
    ///     function pure / testable in isolation.
    /// - Returns: A populated WorkoutMetadata ready to merge into the existing one.
    /// Sex coefficients for Banister's exponential TRIMP (Banister 1991).
    /// Men:   y = 0.64 × e^(1.92 × HRR)
    /// Women: y = 0.86 × e^(1.67 × HRR)
    /// Caller passes `nil` or `.other` to get the men's coefficients
    /// (slightly higher weighting at high intensities) — it's the more
    /// common published default when sex is unspecified.
    enum BanisterSex { case male, female }

    static func analyze(
        sport: Sport,
        rrPoints: [RRPoint],
        startDate: Date,
        track: [CLLocation],
        userMaxHR: Int? = nil,
        userRestingHR: Int? = nil,
        userLTHR: Int? = nil,
        sex: BanisterSex = .male,
        splitDistanceMeters: Double = 1_000
    ) -> WorkoutMetadata {
        // luciaTRIMP is Banister — continuous, HRR-based, sex-aware. It falls
        // back to Edwards 5-zone when resting HR / max HR aren't both known, so
        // the analyzer still returns something meaningful in edge cases.
        var metadata = WorkoutMetadata(sport: sport)
        metadata.luciaTRIMP = computeTRIMP(
            rrPoints: rrPoints, userMaxHR: userMaxHR, userRestingHR: userRestingHR, sex: sex
        )
        // HRSS-style hrTSS: session TRIMP normalised against the TRIMP of one
        // hour at LTHR. Equals 100 for exactly 1 hour at threshold — the
        // definitional meaning of a "1-hour threshold effort = 100 TSS".
        metadata.hrTSS = computeHrTSS(rrPoints: rrPoints, userMaxHR: userMaxHR, userRestingHR: userRestingHR, userLTHR: userLTHR, sex: sex)
        if !track.isEmpty {
            attachGPSDerived(
                to: &metadata, track: track, rrPoints: rrPoints,
                startDate: startDate, splitDistanceMeters: splitDistanceMeters
            )
        }
        return metadata
    }

    /// Distance, polyline, splits and decoupling — everything that needs a GPS
    /// track.
    ///
    /// Elevation is deliberately NOT computed here. WorkoutLocationManager is
    /// the single source of truth: it uses CMAltimeter when available (±0.5 m)
    /// and falls back to GPS altitude with a proper noise gate only when no
    /// barometer is present. Summing raw GPS altitude deltas here (no gate)
    /// produces ~2x inflated gain and would overwrite the live barometric
    /// measurement in the finalize step.
    private static func attachGPSDerived(
        to metadata: inout WorkoutMetadata,
        track: [CLLocation],
        rrPoints: [RRPoint],
        startDate: Date,
        splitDistanceMeters: Double
    ) {
        metadata.distanceMeters = computeDistance(track: track)
        metadata.gpsPolyline = encodePolyline(track: track)
        // Plan §F5 #17 — α1 column on splits. Enrich after the base splits are
        // emitted so the post-pass can read the analyzed sample stream's alpha1
        // values (samples are populated upstream before this analyzer runs).
        metadata.splits = enrichSplitsWithAlpha1(
            splits: computeSplits(
                track: track, rrPoints: rrPoints,
                startDate: startDate, splitDistanceMeters: splitDistanceMeters
            ),
            samples: metadata.samples ?? [],
            startDate: startDate,
            track: track
        )
        let decoupling = computeDecoupling(track: track, rrPoints: rrPoints, startDate: startDate)
        metadata.decouplingPercent = decoupling.decouplingPercent
        metadata.efficiencyFactor = decoupling.overallEfficiencyFactor
    }

    // MARK: - TRIMP (Banister exponential, HRR-based)

    /// Banister 1991 TRIMP: continuous integration, sex-dependent exponential
    /// scaling on heart-rate reserve. Per-beat contribution:
    ///
    ///   TRIMP = Σ (durMin × HRR × A × e^(k × HRR))
    ///
    /// where HRR = (HR − HRrest) / (HRmax − HRrest) and (A, k) are
    /// sex-specific coefficients: (0.64, 1.92) for men, (0.86, 1.67) for
    /// women. The asymmetry reflects observed differences in the
    /// lactate-vs-HR curve across sexes in Banister's original work.
    /// Range: 0-4.37 TRIMP/min for men, 0-3.4 TRIMP/min for women.
    ///
    /// Why Banister instead of Edwards zone TRIMP:
    ///   • Continuous — no "jump" in stress score when HR crosses a zone line.
    ///   • HRR-based — accounts for resting HR, so a fit person with HRrest
    ///     50 and HR 150 doesn't score the same as an unfit person with
    ///     HRrest 75 and HR 150.
    ///   • Exponential — the scientifically observed relationship between
    ///     HR and blood lactate is non-linear; linear zone weights
    ///     dramatically understate the physiological cost of Zone 5 work.
    ///
    /// Needs BOTH userMaxHR and userRestingHR to compute HRR properly. When
    /// either is missing we fall back to Edwards 5-zone with userMaxHR (or
    /// session peak in the deepest fallback) so the function always returns
    /// *something* meaningful — but callers should strongly prefer providing
    /// the real numbers for day-to-day comparability.
    static func computeTRIMP(
        rrPoints: [RRPoint],
        userMaxHR: Int? = nil,
        userRestingHR: Int? = nil,
        sex: BanisterSex = .male
    ) -> Double? {
        guard rrPoints.count >= 30 else { return nil }
        let hrs = rrPoints.compactMap { point -> (Double, Double)? in
            guard point.rr_ms > 0 else { return nil }
            return (60_000.0 / Double(point.rr_ms), Double(point.rr_ms) / 1_000.0)
        }
        guard !hrs.isEmpty else { return nil }
        // Banister when we have both HRmax and HRrest; otherwise Edwards, so
        // older callers and test doubles still get a number.
        guard let maxHR = userMaxHR, maxHR > 0,
              let restHR = userRestingHR, restHR > 0, maxHR > restHR
        else { return edwardsTRIMPFallback(hrs: hrs, userMaxHR: userMaxHR) }
        return banisterTRIMP(hrs: hrs, maxHR: Double(maxHR), restHR: Double(restHR), sex: sex)
    }

    /// Core Banister integration. `hrs` is a list of (HR-bpm, duration-seconds)
    /// tuples — one per RR beat. Returns the integrated TRIMP across all beats.
    static func banisterTRIMP(
        hrs: [(Double, Double)],
        maxHR: Double,
        restHR: Double,
        sex: BanisterSex
    ) -> Double {
        // Banister TRIMP: dur_min × HRR × A·e^(b·HRR); male A=0.64 b=1.92,
        // female A=0.86 b=1.67 — Morton, Fitz-Clarke & Banister, J Appl Physiol
        // 1990;69(3):1171-1177 (coeffs: Banister 1991, Physiological Testing of
        // Elite Athletes).
        // Read A and b from TrainingConstants.TRIMP (one source)
        // instead of inline 0.64/0.86 + 1.92/1.67 literals that would have to be
        // kept in sync by hand with `HealthWorkoutSummary.calculateTrimp`.
        // Banister TRIMP (Morton, Fitz-Clarke & Banister 1990) calls these `A`
        // and `k`; `beatTRIMP` names the same two values `scale:` and
        // `weighting:`, so the paper's symbols live in this comment and the
        // code says what each one does.
        let scale: Double = (sex == .male) ? TrainingConstants.TRIMP.maleScale : TrainingConstants.TRIMP.femaleScale
        let weighting: Double = (sex == .male) ? TrainingConstants.TRIMP.maleWeighting : TrainingConstants.TRIMP.femaleWeighting
        let range = maxHR - restHR
        guard range > 0 else { return 0 }

        return hrs.reduce(0.0) { total, beat in
            total + beatTRIMP(hr: beat.0, durSec: beat.1, restHR: restHR, range: range, scale: scale, weighting: weighting)
        }
    }

    /// One beat's contribution. HRR (Karvonen): (HR − HRrest)/(HRmax − HRrest)
    /// — Karvonen, Kentala & Mustala, Ann Med Exp Biol Fenn 1957;35(3):307-315.
    /// Clamped to [0,1] so a spike past max HR doesn't explode the exponential.
    private static func beatTRIMP(
        hr: Double,
        durSec: Double,
        restHR: Double,
        range: Double,
        scale: Double,
        weighting: Double
    ) -> Double {
        let hrr = max(0, min((hr - restHR) / range, 1.0))
        return (durSec / 60.0) * hrr * (scale * exp(weighting * hrr))
    }

    /// Edwards 5-zone fallback. Used only when userRestingHR isn't known,
    /// so the function still returns a sensible-ish number in edge cases
    /// (direct callers, tests). Production path always provides HRrest.
    private static func edwardsTRIMPFallback(
        hrs: [(Double, Double)],
        userMaxHR: Int?
    ) -> Double? {
        let denominator: Double
        if let userMax = userMaxHR, userMax > 0 {
            denominator = Double(userMax)
        } else {
            guard let peakHR = hrs.map(\.0).max(), peakHR > 0 else { return nil }
            denominator = peakHR
        }
        return hrs.reduce(0.0) { total, beat in
            let frac = beat.0 / denominator
            guard let bin = edwardsBins.first(where: { $0.range.contains(frac) }) else { return total }
            return total + (beat.1 / 60.0) * bin.weight
        }
    }

    /// Edwards' five %HRmax bands and their linear weights.
    private static let edwardsBins: [(range: ClosedRange<Double>, weight: Double)] = [
            (0.50 ... 0.60, 1),
            (0.60 ... 0.70, 2),
            (0.70 ... 0.80, 3),
            (0.80 ... 0.90, 4),
            (0.90 ... 2.00, 5)
        ]

    // MARK: - hrTSS (HRSS-style: session TRIMP vs 1-hour-at-LTHR TRIMP)

    /// Heart-rate Training Stress Score via the HRSS formulation
    /// (Fellrnr / intervals.icu): normalise the session's Banister TRIMP
    /// against the TRIMP produced by exactly one hour at the user's LTHR.
    ///
    ///   hrTSS = session_TRIMP / TRIMP_1hr_at_LTHR × 100
    ///
    /// This gives the definitionally-correct meaning of TSS — "a 1-hour
    /// effort at threshold = 100 points." It's superior to the older
    /// `duration × IF² × 100` approximation because (a) it uses Banister's
    /// physiologically-grounded exponential rather than a squared ratio,
    /// and (b) it naturally rewards steady threshold work the way power-TSS
    /// does without needing power data.
    ///
    /// LTHR defaults to 0.88 × userMaxHR when `userLTHR` is nil. Friel
    /// explicitly warns the %HRmax estimate is less accurate than a field-
    /// tested LTHR — once the user runs a 30-min time trial and sets LTHR
    /// in Settings, all subsequent hrTSS comparisons become more reliable.
    /// hrTSS (HRSS): session_TRIMP / TRIMP(1h at LTHR) × 100 —
    /// intervals.icu/Fellrnr; LTHR≈0.88·HRmax est. per Friel.
    static func computeHrTSS(
        rrPoints: [RRPoint],
        userMaxHR: Int? = nil,
        userRestingHR: Int? = nil,
        userLTHR: Int? = nil,
        sex: BanisterSex = .male
    ) -> Double? {
        guard let sessionTRIMP = computeTRIMP(
            rrPoints: rrPoints, userMaxHR: userMaxHR, userRestingHR: userRestingHR, sex: sex
        ), sessionTRIMP > 0 else { return nil }
        // HRmax and HRrest are REQUIRED — without them there is no heart-rate
        // reserve to anchor against, so skip hrTSS rather than publish a number
        // built on guesses.
        //
        // LTHR is optional and falls back to 0.88 × HRmax (the standard
        // population approximation); a missing LTHR does NOT skip the metric.
        // `WorkoutAnalyzerMathTests` pins this behaviour.
        guard let maxHR = userMaxHR, maxHR > 0,
              let restHR = userRestingHR, restHR > 0,
              maxHR > restHR
        else { return nil }
        let lthr = (userLTHR.map { $0 > 0 ? Double($0) : nil } ?? nil) ?? Double(maxHR) * 0.88
        let referenceTRIMP = oneHourAtLTHRTRIMP(lthr: lthr, maxHR: maxHR, restHR: restHR, sex: sex)
        guard referenceTRIMP > 0 else { return nil }
        return (sessionTRIMP / referenceTRIMP) * 100.0
    }

    /// The denominator of hrTSS: a synthetic "one hour entirely at LTHR" run
    /// through Banister at the same user coefficients. Sixty simulated minutes
    /// of beats at `lthr` give the reference a 100-point session is measured
    /// against.
    private static func oneHourAtLTHRTRIMP(lthr: Double, maxHR: Int, restHR: Int, sex: BanisterSex) -> Double {
        let referenceBeats: [(Double, Double)] = Array(
            repeating: (lthr, 60.0 * 60.0 / 60.0 /* 60 s per simulated minute */ ),
            count: 60
        )
        return banisterTRIMP(hrs: referenceBeats, maxHR: Double(maxHR), restHR: Double(restHR), sex: sex)
    }

    // MARK: - GPS derivations

    static func computeDistance(track: [CLLocation]) -> Double {
        WorkoutGeometry.trackLengthMeters(track)
    }

    static func computeElevationGain(track: [CLLocation]) -> Double {
        guard track.count >= 2 else { return 0 }
        var gain = 0.0
        for i in 1 ..< track.count {
            let delta = track[i].altitude - track[i - 1].altitude
            if delta > 0 { gain += delta }
        }
        return gain
    }

    static func computeElevationLoss(track: [CLLocation]) -> Double {
        guard track.count >= 2 else { return 0 }
        var loss = 0.0
        for i in 1 ..< track.count {
            let delta = track[i].altitude - track[i - 1].altitude
            if delta < 0 { loss += -delta }
        }
        return loss
    }

    /// Retroactive elevation-gain recompute for sessions recorded before the
    /// CMAltimeter (barometric) fix. The live elevation for those sessions
    /// was accumulated from raw GPS altitude with a 2 m noise gate —
    /// insufficient for GPS altitude's ±5-10 m standard deviation, which
    /// integrates into ~2× the real gain over a 60-min walk.
    ///
    /// Algorithm (tuned by user-feedback calibration on a 400 ft real climb:
    /// raw GPS reads 937 ft, and an overly aggressive smoother reads
    /// < 200 ft):
    ///   1. Wide rolling-median smoother (window 15, ≈ 75 s at 5 s fix
    ///      rate) removes the short-period GPS noise without eating
    ///      genuine terrain — a real hill has sustained signal over
    ///      many fixes, so median-of-15 preserves it.
    ///   2. Running-mean pass (window 5) on top of the median output
    ///      smooths any residual sawtoothing so tiny oscillations
    ///      around a climb don't get double-counted on each up-tick.
    ///   3. Per-delta accumulation with a small 1.5 m gate. Just enough
    ///      to drop sub-metre GPS jitter that survives the smoothers;
    ///      small enough that the climb doesn't get undercounted.
    ///
    /// This is the same smoothing family Strava / Garmin use for their
    /// barometer-less fallback (moving-average + small gate; no
    /// "sustained direction" requirement — that threw out real hills
    /// whose slope contained a brief pause).
    ///
    /// Returns `(gainMeters, lossMeters)`. Expected to land within ~15 %
    /// of the true climb when GPS altitude noise is typical; sessions
    /// with severely noisy fixes may still err either direction.
    static func recomputeGPSElevationSmoothed(
        track: [CLLocation],
        noiseGate: Double = 1.5
    ) -> (gain: Double, loss: Double) {
        guard track.count >= 20 else { return (0, 0) }
        let alts = track.map(\.altitude)
        let smoothed = rollingMean(rollingMedian(alts, window: 15), window: 5)
        var gain = 0.0
        var loss = 0.0
        // `1 ..< 0` traps on an empty altitude series.
        guard smoothed.count > 1 else { return (gain: 0, loss: 0) }
        for i in 1 ..< smoothed.count {
            let d = smoothed[i] - smoothed[i - 1]
            if abs(d) < noiseGate { continue }
            if d > 0 { gain += d } else { loss += -d }
        }
        return (gain, loss)
    }

    /// Odd-window rolling median — kills short-duration GPS altitude
    /// spikes without distorting the underlying terrain trend.
    private static func rollingMedian(_ values: [Double], window: Int) -> [Double] {
        guard values.count >= window else { return values }
        let half = window / 2
        var out = values
        for i in half ..< (values.count - half) {
            let slice = Array(values[(i - half) ... (i + half)]).sorted()
            out[i] = slice[slice.count / 2]
        }
        return out
    }

    /// Simple moving-average smoother applied AFTER the median — catches
    /// any residual zig-zag that survived median filtering.
    private static func rollingMean(_ values: [Double], window: Int) -> [Double] {
        guard values.count >= window else { return values }
        let half = window / 2
        var out = values
        for i in half ..< (values.count - half) {
            var sum = 0.0
            for j in (i - half) ... (i + half) { sum += values[j] }
            out[i] = sum / Double(window)
        }
        return out
    }

    // MARK: - Splits

    static func computeSplits(
        track: [CLLocation],
        rrPoints: [RRPoint],
        startDate: Date,
        splitDistanceMeters: Double = 1_000
    ) -> [Split] {
        guard track.count >= 2 else { return [] }
        // Precompute a beat-time → HR array so we can average HR per split window.
        let hrSamples = hrSamplesWithWallClock(rrPoints: rrPoints, startDate: startDate)
        var splits: [Split] = []
        var splitStartIdx = 0
        var splitStartDistance = 0.0
        var cumulative = 0.0
        for i in 1 ..< track.count {
            cumulative += track[i].distance(from: track[i - 1])
            guard cumulative - splitStartDistance >= splitDistanceMeters else { continue }
            splits.append(split(
                index: splits.count + 1, track: track,
                from: splitStartIdx, to: i,
                distance: cumulative - splitStartDistance, hrSamples: hrSamples
            ))
            splitStartIdx = i
            splitStartDistance = cumulative
        }
        return splits
    }

    private static func split(
        index splitIndex: Int,
        track: [CLLocation],
        from splitStartIdx: Int,
        to i: Int,
        distance: Double,
        hrSamples: [HRWallClockSample]
    ) -> Split {
        let startFix = track[splitStartIdx]
        let endFix = track[i]
        let duration = endFix.timestamp.timeIntervalSince(startFix.timestamp)
        return Split(
            index: splitIndex,
            distanceMeters: distance,
            durationSeconds: duration,
            averageHR: averageHR(samples: hrSamples, from: startFix.timestamp, to: endFix.timestamp),
            averagePaceSecPerKm: duration > 0 ? (duration / (distance / 1_000)) : nil,
            elevationGainMeters: computeElevationGain(track: Array(track[splitStartIdx ... i])),
            averageAlpha1: nil // populated by enrichSplitsWithAlpha1 post-pass
        )
    }

    /// Plan §F5 #17 — post-pass that adds `averageAlpha1` to each
    /// split using the workout samples' α1 column. Splits are emitted
    /// from `computeSplits` first (which only knows GPS + RR), then
    /// this enrichment runs once the analyzer has α1 samples.
    /// Cheap O(n+m): samples and splits both run in chronological
    /// order, so a single linear sweep covers all splits.
    static func enrichSplitsWithAlpha1(
        splits: [Split],
        samples: [WorkoutSample],
        startDate: Date,
        track: [CLLocation]
    ) -> [Split] {
        guard !splits.isEmpty else { return splits }
        let alphaPoints = alphaOffsets(of: samples)
        guard !alphaPoints.isEmpty else { return splits }
        // Each split needs its [startOffsetSec, endOffsetSec] window, re-derived
        // by walking the GPS track parallel to the split distances. When track
        // sizes don't line up (e.g. split-only indoor sport) the per-split
        // duration carries the window instead — close enough.
        var enriched: [Split] = []
        var walk = SplitTrackWalk(startOffsetSec: 0, trackIdx: 0, cumulative: 0)
        for split in splits {
            let endOffsetSec = walk.advance(over: split, track: track, startDate: startDate)
            var enrichedSplit = split
            enrichedSplit.averageAlpha1 = averageAlpha1(
                of: alphaPoints, from: walk.startOffsetSec, to: endOffsetSec
            )
            enriched.append(enrichedSplit)
            walk.startOffsetSec = endOffsetSec
        }
        return enriched
    }

    /// (offsetSec, alpha1) for every sample that carried an α1 value.
    private static func alphaOffsets(of samples: [WorkoutSample]) -> [(Int, Double)] {
        samples.compactMap { sample in
            guard let alpha = sample.alpha1 else { return nil }
            return (sample.offsetSec, alpha)
        }
    }

    /// Mean α1 over one split's window, or nil when no sample fell inside it.
    private static func averageAlpha1(of alphaPoints: [(Int, Double)], from start: Int, to end: Int) -> Double? {
        let inWindow = alphaPoints.filter { $0.0 >= start && $0.0 < end }
        guard !inWindow.isEmpty else { return nil }
        return inWindow.map(\.1).reduce(0, +) / Double(inWindow.count)
    }

    /// Cursor that walks the GPS track alongside the split list, so each split
    /// can be given the clock window it actually covered.
    private struct SplitTrackWalk {
        var startOffsetSec: Int
        var trackIdx: Int
        var cumulative: Double

        /// Advances to the end of `split` and returns its end offset. Any
        /// remaining mismatch (a last partial split) is accepted as-is.
        mutating func advance(over split: Split, track: [CLLocation], startDate: Date) -> Int {
            let targetDistance = cumulative + split.distanceMeters
            while trackIdx + 1 < track.count, cumulative < targetDistance {
                cumulative += track[trackIdx + 1].distance(from: track[trackIdx])
                trackIdx += 1
            }
            guard track.indices.contains(trackIdx) else {
                return startOffsetSec + Int(split.durationSeconds.rounded())
            }
            return Int(track[trackIdx].timestamp.timeIntervalSince(startDate))
        }
    }

    // MARK: - Decoupling & Efficiency Factor

    struct DecouplingResult {
        let decouplingPercent: Double?
        let overallEfficiencyFactor: Double?
    }

    /// Pa:Hr decoupling — first-half vs second-half efficiency drift.
    /// A positive % means the second half required higher HR for the same pace
    /// (aerobic efficiency loss); small values (<5%) mean the athlete is at or
    /// below their aerobic threshold.
    ///
    /// Minimums: session ≥ 5 minutes AND ≥ 500m covered. Below those, the
    /// half-session efficiency ratio explodes into nonsense values
    /// (observed "-274.4%" for a 2-minute house walk). Return nil instead
    /// and let the UI hide the metric.
    static func computeDecoupling(
        track: [CLLocation],
        rrPoints: [RRPoint],
        startDate: Date
    ) -> DecouplingResult {
        let empty = DecouplingResult(decouplingPercent: nil, overallEfficiencyFactor: nil)
        guard track.count >= 4, trackIsLongEnoughForDecoupling(track) else { return empty }
        let midpoint = track.count / 2
        let hrSamples = hrSamplesWithWallClock(rrPoints: rrPoints, startDate: startDate)
        guard let ef1 = halfEfficiency(halfTrack: Array(track[0 ..< midpoint]), hrSamples: hrSamples),
              let ef2 = halfEfficiency(halfTrack: Array(track[midpoint ..< track.count]), hrSamples: hrSamples),
              ef1 > 0
        else { return empty }
        return DecouplingResult(
            decouplingPercent: (ef1 - ef2) / ef1 * 100.0,
            // Overall EF uses the full session.
            overallEfficiencyFactor: halfEfficiency(halfTrack: track, hrSamples: hrSamples)
        )
    }

    /// Below 5 minutes or 500 m the half-session efficiency ratio explodes into
    /// nonsense (an observed "-274.4%" for a 2-minute house walk), so the
    /// metric is withheld rather than shown.
    private static func trackIsLongEnoughForDecoupling(_ track: [CLLocation]) -> Bool {
        guard let firstStamp = track.first?.timestamp, let last = track.last else { return false }
        let totalDuration = last.timestamp.timeIntervalSince(firstStamp)
        var totalDistance = 0.0
        // empty-range-ok: the `track.first` / `track.last` guard above proves
        // count >= 1, and `1 ..< 1` is a valid empty range.
        for i in 1 ..< track.count {
            totalDistance += track[i].distance(from: track[i - 1])
        }
        return totalDuration >= 300 && totalDistance >= 500
    }

    private static func halfEfficiency(halfTrack: [CLLocation], hrSamples: [HRWallClockSample]) -> Double? {
        guard halfTrack.count >= 2,
              let first = halfTrack.first,
              let last = halfTrack.last
        else { return nil }

        let duration = last.timestamp.timeIntervalSince(first.timestamp)
        guard duration > 0 else { return nil }

        var distance = 0.0
        for i in 1 ..< halfTrack.count {
            distance += halfTrack[i].distance(from: halfTrack[i - 1])
        }
        guard distance > 0 else { return nil }

        let pace = distance / duration // m/s — bigger is faster
        guard let avgHR = averageHR(samples: hrSamples, from: first.timestamp, to: last.timestamp),
              avgHR > 0
        else { return nil }

        return pace / avgHR
    }

    // MARK: - Polyline encoding

    /// Google-style polyline encoding (precision 5). Compact, widely supported
    /// for downstream rendering. Altitude is encoded as a parallel series
    /// concatenated after the coordinate polyline, separated by `\n`.
    static func encodePolyline(track: [CLLocation]) -> Data? {
        guard !track.isEmpty else { return nil }
        let coordPoly = encode(coordinates: track.map(\.coordinate))
        let altPoly = encode(altitudes: track.map(\.altitude))
        let joined = "\(coordPoly)\n\(altPoly)"
        return joined.data(using: .utf8)
    }

    /// Scale a coordinate or altitude to the fixed-point integer the polyline
    /// format uses, without trapping.
    ///
    /// `Int(_:)` on a `Double` is a TRAP, not a throw, for NaN, infinity, and
    /// anything outside `Int`'s range — an immediate process kill with no catch
    /// site. A malformed `<ele>` in an imported GPX file reaches exactly this
    /// conversion.
    ///
    /// `GPXImporter` rejects those values at the parse boundary, which is
    /// where the fix belongs. This is the second line: an encoder that cannot
    /// crash regardless of what reaches it, because a fixed importer is one
    /// caller and this is shared by every track-producing path.
    private static func scaledInt(_ value: Double, by factor: Double) -> Int {
        guard value.isFinite else { return 0 }
        let scaled = (value * factor).rounded()
        guard scaled >= Double(Int.min), scaled <= Double(Int.max) else {
            return scaled < 0 ? Int.min : Int.max
        }
        return Int(scaled)
    }

    private static func encode(coordinates: [CLLocationCoordinate2D]) -> String {
        var result = ""
        var prevLat = 0
        var prevLon = 0
        for coord in coordinates {
            let lat = scaledInt(coord.latitude, by: 1e5)
            let lon = scaledInt(coord.longitude, by: 1e5)
            result += encode(value: lat - prevLat)
            result += encode(value: lon - prevLon)
            prevLat = lat
            prevLon = lon
        }
        return result
    }

    private static func encode(altitudes: [Double]) -> String {
        var result = ""
        var prev = 0
        for alt in altitudes {
            let scaled = scaledInt(alt, by: 10)
            result += encode(value: scaled - prev)
            prev = scaled
        }
        return result
    }

    private static func encode(value: Int) -> String {
        var v = value < 0 ? ~(value << 1) : (value << 1)
        var result = ""
        while v >= 0x20 {
            let chunk = ((0x20 | (v & 0x1f)) + 63)
            if let scalar = Unicode.Scalar(chunk) {
                result.append(Character(scalar))
            }
            v >>= 5
        }
        if let scalar = Unicode.Scalar(v + 63) {
            result.append(Character(scalar))
        }
        return result
    }

    // MARK: - HR wall-clock helpers

    struct HRWallClockSample {
        let timestamp: Date
        let hr: Double
    }

    /// Build (wall-clock Date, HR bpm) pairs by integrating RR durations from
    /// the session start. The RRPoint model tracks cumulative ms via `t_ms`,
    /// so we can use it directly when available.
    static func hrSamplesWithWallClock(rrPoints: [RRPoint], startDate: Date) -> [HRWallClockSample] {
        rrPoints.compactMap { point in
            guard point.rr_ms > 0 else { return nil }
            let timestamp = startDate.addingTimeInterval(Double(point.t_ms) / 1000.0)
            let hr = 60_000.0 / Double(point.rr_ms)
            return HRWallClockSample(timestamp: timestamp, hr: hr)
        }
    }

    private static func averageHR(samples: [HRWallClockSample], from: Date, to: Date) -> Double? {
        let window = samples.filter { $0.timestamp >= from && $0.timestamp <= to }
        guard !window.isEmpty else { return nil }
        let total = window.reduce(0.0) { $0 + $1.hr }
        return total / Double(window.count)
    }
}
