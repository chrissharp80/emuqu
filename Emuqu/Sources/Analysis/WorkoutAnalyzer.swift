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
//   • Range: 0-4.37 TRIMP/min male, 0-4.57 TRIMP/min female (at HRR = 1).
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
//     shows this HR as an LT1 (aerobic-threshold) estimate only. It is
//     NOT offered as an LTHR value: LT1 sits well below LTHR, and using
//     it as the hrTSS denominator would inflate every later load figure
//     (see ThresholdCards+Cards.swift). It never modifies TRIMP / hrTSS
//     inputs.
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
//   • Power-TSS — gold standard for cycling / power-meter running.
//     Computed outside this analyzer (`powerTSS`) when power and an FTP
//     (user-set or auto-estimated) exist, and preferred over TRIMP then.
//   • TRIMPi (Manzi 2009) — most predictive (r=0.77-0.87) but needs
//     blood lactate testing.
//
// Source links:
//   • Banister:    https://fellrnr.com/wiki/TRIMP
//   • Lucia (and validation gap): https://www.trainingimpulse.com/lucias-trimp-0
//   • Manzi TRIMPi: https://pubmed.ncbi.nlm.nih.gov/19812506/
//   • Rogers & Gronwald α1 2021: https://pmc.ncbi.nlm.nih.gov/articles/PMC7845545/
//   • 2024 α1 replication:       https://www.frontiersin.org/journals/physiology/articles/10.3389/fphys.2024.1329360/full
//   • Friel LTHR protocol:       https://www.trainingpeaks.com/learn/articles/joe-friel-s-quick-guide-to-setting-zones/
// ─────────────────────────────────────────────────────────────────
enum WorkoutAnalyzer {
    // MARK: - Public entry point

    /// Sex coefficients for Banister's exponential TRIMP (Banister 1991).
    /// Men:   y = 0.64 × e^(1.92 × HRR)
    /// Women: y = 0.86 × e^(1.67 × HRR)
    enum BanisterSex { case male, female }

    /// Steps of a track (step `i` runs from fix `i - 1` to fix `i`) that a
    /// paused stretch makes not count: `paused` steps add neither distance nor
    /// time, `gaps` (the step across a resume) add distance but not time.
    struct TrackPauses: Equatable, Sendable {
        var paused: Set<Int> = []
        var gaps: Set<Int> = []
    }

    /// Compute all workout-flavoured metrics from the raw inputs.
    /// - Parameters:
    ///   - rrPoints: RR interval points captured during the session.
    ///   - startDate: Absolute session start (used to align GPS fixes).
    ///   - track: GPS fixes, in chronological order. Empty for indoor sports.
    ///   - userMaxHR: User's physiological max HR (from Settings, else 208 − 0.7 × age).
    ///     Used as the canonical denominator for %HRmax zoning. Session-peak fallback
    ///     only when this is nil — which it never is in practice, but keeps the
    ///     function pure / testable in isolation.
    ///   - sex: Banister coefficients. Callers with no recorded sex pass the
    ///     default `.male` — the more common published default, with slightly
    ///     higher weighting at high intensities.
    /// - Returns: A populated WorkoutMetadata ready to merge into the existing one.
    static func analyze(
        sport: Sport,
        rrPoints: [RRPoint],
        startDate: Date,
        track: [CLLocation],
        userMaxHR: Int? = nil,
        userRestingHR: Int? = nil,
        userLTHR: Int? = nil,
        sex: BanisterSex = .male,
        splitDistanceMeters: Double = 1_000,
        pauses: TrackPauses = TrackPauses()
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
                startDate: startDate, splitDistanceMeters: splitDistanceMeters, pauses: pauses
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
        splitDistanceMeters: Double,
        pauses: TrackPauses
    ) {
        metadata.distanceMeters = computeDistance(track: track, pauses: pauses)
        metadata.gpsPolyline = encodePolyline(track: track)
        // Splits carry no α1 yet: the per-second samples are attached after
        // this analyzer runs. `splitsEnrichedWithAlpha1` fills the column in
        // once they are.
        metadata.splits = computeSplits(
            track: track, rrPoints: rrPoints,
            startDate: startDate, splitDistanceMeters: splitDistanceMeters, pauses: pauses
        )
        let decoupling = computeDecoupling(track: track, rrPoints: rrPoints, startDate: startDate, pauses: pauses)
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
    /// Range at HRR = 1: 0.64·e^1.92 ≈ 4.37 TRIMP/min for men,
    /// 0.86·e^1.67 ≈ 4.57 TRIMP/min for women.
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

    static func computeDistance(track: [CLLocation], pauses: TrackPauses = TrackPauses()) -> Double {
        guard !pauses.paused.isEmpty else { return WorkoutGeometry.trackLengthMeters(track) }
        guard track.count >= 2 else { return 0 }
        return (1 ..< track.count).reduce(0.0) { total, i in
            pauses.paused.contains(i) ? total : total + track[i].distance(from: track[i - 1])
        }
    }

    /// Raw sum of upward altitude steps. Only for slices too short to smooth;
    /// over a real track GPS altitude noise roughly doubles this.
    static func computeElevationGain(track: [CLLocation]) -> Double {
        guard track.count >= 2 else { return 0 }
        var gain = 0.0
        for i in 1 ..< track.count {
            let delta = track[i].altitude - track[i - 1].altitude
            if delta > 0 { gain += delta }
        }
        return gain
    }

    // MARK: - Splits

    static func computeSplits(
        track: [CLLocation],
        rrPoints: [RRPoint],
        startDate: Date,
        splitDistanceMeters: Double = 1_000,
        pauses: TrackPauses = TrackPauses()
    ) -> [Split] {
        guard track.count >= 2 else { return [] }
        // Precompute a beat-time → HR array so we can average HR per split window.
        let hrSamples = hrSamplesWithWallClock(rrPoints: rrPoints, startDate: startDate)
        var splits: [Split] = []
        var splitStartIdx = 0
        var run = SplitRun()
        for i in 1 ..< track.count {
            run.add(step: i, of: track, pauses: pauses)
            guard run.distance >= splitDistanceMeters else { continue }
            splits.append(split(
                index: splits.count + 1, track: track,
                from: splitStartIdx, to: i, run: run, hrSamples: hrSamples
            ))
            splitStartIdx = i
            run = SplitRun()
        }
        return splits
    }

    /// Distance and moving time accumulated since the last split, leaving out
    /// what `TrackPauses` marks.
    private struct SplitRun {
        var distance = 0.0
        var seconds = 0.0

        mutating func add(step i: Int, of track: [CLLocation], pauses: TrackPauses) {
            guard !pauses.paused.contains(i) else { return }
            distance += track[i].distance(from: track[i - 1])
            if !pauses.gaps.contains(i) {
                seconds += track[i].timestamp.timeIntervalSince(track[i - 1].timestamp)
            }
        }
    }

    private static func split(
        index splitIndex: Int,
        track: [CLLocation],
        from splitStartIdx: Int,
        to i: Int,
        run: SplitRun,
        hrSamples: [HRWallClockSample]
    ) -> Split {
        let startFix = track[splitStartIdx]
        let endFix = track[i]
        let distance = run.distance
        let duration = run.seconds
        return Split(
            index: splitIndex,
            distanceMeters: distance,
            durationSeconds: duration,
            averageHR: averageHR(samples: hrSamples, from: startFix.timestamp, to: endFix.timestamp),
            averagePaceSecPerKm: duration > 0 ? (duration / (distance / 1_000)) : nil,
            elevationGainMeters: splitElevationGain(Array(track[splitStartIdx ... i])),
            averageAlpha1: nil // populated by enrichSplitsWithAlpha1 post-pass
        )
    }

    /// A split's climb through the same smoothed, sustained-run filter the
    /// session total uses (`BarometricAltitudeProcessor`), so the splits add
    /// up to roughly the headline gain instead of ~2× it from summing raw GPS
    /// altitude jitter. Slices too short to smooth fall back to the raw sum.
    private static func splitElevationGain(_ fixes: [CLLocation]) -> Double {
        guard fixes.count >= 3 else { return computeElevationGain(track: fixes) }
        return BarometricAltitudeProcessor.process(
            samples: fixes.map { (timestamp: $0.timestamp, altitudeMeters: $0.altitude) },
            smootherWindow: min(15, fixes.count)
        ).gainMeters
    }

    /// `metadata`'s splits with each one's mean α1 from the samples already on
    /// it, or its splits unchanged when it has no samples. Call once the
    /// samples are attached (workout finalize) and again whenever α1
    /// re-analysis rewrites them. The split windows are walked along the
    /// stored polyline, its fixes spread across `duration`.
    static func splitsEnrichedWithAlpha1(
        _ metadata: WorkoutMetadata,
        startDate: Date,
        duration: TimeInterval?
    ) -> [Split]? {
        guard let splits = metadata.splits, let samples = metadata.samples else { return metadata.splits }
        let track = metadata.gpsPolyline.map { GPXExporter.decode(polyline: $0, startDate: startDate, duration: duration) } ?? []
        return enrichSplitsWithAlpha1(splits: splits, samples: samples, startDate: startDate, track: track)
    }

    /// Post-pass that adds `averageAlpha1` to each split using the workout
    /// samples' α1 column. Splits are emitted from `computeSplits` first
    /// (which only knows GPS + RR), then this enrichment runs once the
    /// samples exist. Cheap O(n+m): samples and splits both run in
    /// chronological order, so a single linear sweep covers all splits.
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
    /// The halves split the MOVING time, and paused steps (`pauses`) count
    /// toward neither pace nor HR: a mid-run café stop otherwise sat in one
    /// half as slow moving time and read as a large efficiency loss.
    ///
    /// Minimums: session ≥ 5 minutes AND ≥ 500m covered. Below those, the
    /// half-session efficiency ratio explodes into nonsense values
    /// (observed "-274.4%" for a 2-minute house walk). Return nil instead
    /// and let the UI hide the metric.
    static func computeDecoupling(
        track: [CLLocation],
        rrPoints: [RRPoint],
        startDate: Date,
        pauses: TrackPauses = TrackPauses()
    ) -> DecouplingResult {
        let empty = DecouplingResult(decouplingPercent: nil, overallEfficiencyFactor: nil)
        guard track.count >= 4, trackIsLongEnoughForDecoupling(track) else { return empty }
        let hrSamples = hrSamplesWithWallClock(rrPoints: rrPoints, startDate: startDate)
        let halves = movingHalves(track: track, hrSamples: hrSamples, pauses: pauses)
        guard let ef1 = halves.first.efficiency, let ef2 = halves.second.efficiency, ef1 > 0 else { return empty }
        return DecouplingResult(
            decouplingPercent: (ef1 - ef2) / ef1 * 100.0,
            // Overall EF uses the whole moving session.
            overallEfficiencyFactor: halves.first.merged(with: halves.second).efficiency
        )
    }

    /// Moving distance, moving time and HR beats of one half of a session.
    struct MovingHalf {
        var distance = 0.0
        var seconds = 0.0
        var hrSum = 0.0
        var hrCount = 0

        /// Pace (m/s) per bpm, or nil without movement or heart rate.
        var efficiency: Double? {
            guard seconds > 0, distance > 0, hrCount > 0 else { return nil }
            let avgHR = hrSum / Double(hrCount)
            return avgHR > 0 ? (distance / seconds) / avgHR : nil
        }

        func merged(with other: MovingHalf) -> MovingHalf {
            MovingHalf(
                distance: distance + other.distance, seconds: seconds + other.seconds,
                hrSum: hrSum + other.hrSum, hrCount: hrCount + other.hrCount
            )
        }
    }

    /// Walks the track's steps once, filling the first half until half the
    /// moving time is used, then the second. A paused step adds nothing; a
    /// gap (the step across a resume) adds its distance but neither time nor
    /// HR. Beats are swept with a forward-only cursor, so this stays linear.
    private static func movingHalves(
        track: [CLLocation],
        hrSamples: [HRWallClockSample],
        pauses: TrackPauses
    ) -> (first: MovingHalf, second: MovingHalf) {
        var halves = (first: MovingHalf(), second: MovingHalf())
        guard let firstFix = track.first, track.count > 1 else { return halves }
        let halfTime = movingSeconds(track: track, pauses: pauses) / 2
        var cursor = HRCursor(samples: hrSamples)
        _ = cursor.take(through: firstFix.timestamp, counting: false)
        for i in 1 ..< track.count where !pauses.paused.contains(i) {
            let counted = !pauses.gaps.contains(i)
            let beats = cursor.take(through: track[i].timestamp, counting: counted)
            let step = MovingHalf(
                distance: track[i].distance(from: track[i - 1]),
                seconds: counted ? track[i].timestamp.timeIntervalSince(track[i - 1].timestamp) : 0,
                hrSum: beats.sum, hrCount: beats.count
            )
            if halves.first.seconds < halfTime {
                halves.first = halves.first.merged(with: step)
            } else {
                halves.second = halves.second.merged(with: step)
            }
        }
        return halves
    }

    private static func movingSeconds(track: [CLLocation], pauses: TrackPauses) -> Double {
        guard track.count > 1 else { return 0 }
        return (1 ..< track.count).reduce(0.0) { total, i in
            pauses.paused.contains(i) || pauses.gaps.contains(i)
                ? total : total + track[i].timestamp.timeIntervalSince(track[i - 1].timestamp)
        }
    }

    /// Forward-only walk over time-ordered HR samples.
    private struct HRCursor {
        let samples: [HRWallClockSample]
        var index = 0

        /// Consumes every sample up to and including `end`; returns their HR
        /// sum and count when `counting`, else drops them.
        mutating func take(through end: Date, counting: Bool) -> (sum: Double, count: Int) {
            var sum = 0.0
            var count = 0
            while index < samples.count, samples[index].timestamp <= end {
                if counting {
                    sum += samples[index].hr
                    count += 1
                }
                index += 1
            }
            return (sum, count)
        }
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

    /// Build (wall-clock Date, HR bpm) pairs on the gap-corrected timeline
    /// (`gapCorrectedOffsetsMs`), so HR lines up with GPS time after dropouts.
    static func hrSamplesWithWallClock(rrPoints: [RRPoint], startDate: Date) -> [HRWallClockSample] {
        zip(rrPoints, gapCorrectedOffsetsMs(rrPoints)).compactMap { point, offsetMs in
            guard point.rr_ms > 0 else { return nil }
            let timestamp = startDate.addingTimeInterval(Double(offsetMs) / 1000.0)
            return HRWallClockSample(timestamp: timestamp, hr: 60_000.0 / Double(point.rr_ms))
        }
    }

    /// Each beat's offset from session start (ms) on the wall-clock timeline.
    /// `t_ms` counts only received beats, so it stops advancing during a
    /// Bluetooth dropout while GPS time keeps going. Where beats carry
    /// `wallClockMs`, the time lost to each dropout is added back: the
    /// correction is the running maximum of how far wall-clock time has
    /// pulled ahead of `t_ms`, so it grows at each gap and ignores the small
    /// jitter of beats delivered in batches. Recordings without
    /// `wallClockMs` (H10 internal) have no gaps and keep `t_ms` as is.
    static func gapCorrectedOffsetsMs(_ rrPoints: [RRPoint]) -> [Int64] {
        let origin = rrPoints.first { $0.wallClockMs != nil }
        var correctionMs: Int64 = 0
        return rrPoints.map { point in
            if let wall = point.wallClockMs, let origin, let originWall = origin.wallClockMs {
                correctionMs = max(correctionMs, (wall - originWall) - (point.t_ms - origin.t_ms))
            }
            return point.t_ms + correctionMs
        }
    }

    private static func averageHR(samples: [HRWallClockSample], from: Date, to: Date) -> Double? {
        let window = samples.filter { $0.timestamp >= from && $0.timestamp <= to }
        guard !window.isEmpty else { return nil }
        let total = window.reduce(0.0) { $0 + $1.hr }
        return total / Double(window.count)
    }
}
