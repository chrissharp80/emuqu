import Foundation

/// Pass 1 of the Beat-to-Beat Consistency feature.
///
/// What this detects: deviation from THIS USER'S established baseline,
/// not the presence of any specific condition. A user whose baseline
/// already carries chronic irregularity will score Consistent because
/// the irregularity has been absorbed into their baseline. That is
/// correct, intended behavior for a recovery input.
///
/// Pure math + value types only: no UI and no persistence on
/// `HRVSession`. The HRV detail screen scores each night with it, and
/// `BeatConsistencyPriorsCache` keeps the per-night features that form the
/// baseline.
///
/// Spec source: "Emuqu — Beat-to-Beat Consistency: Pass 1 Spec".
/// All numeric thresholds tagged `// CALIBRATION CONSTANT`
/// are the spec's initial values, subject to revision after the
/// calibration check across the tester archive.
enum BeatConsistency {
    // MARK: - Value types

    /// Computed once per accepted overnight session, then handed back
    /// to the baseline accumulator for the NEXT night's score.
    struct NightlyResult: Equatable, Sendable {
        /// 0-100, higher = more consistent. `nil` when state is
        /// `calibrating` or `insufficientData`.
        let score: Int?
        let band: Band?
        let state: State

        /// The per-feature median across this night's valid scoring
        /// windows. This is the value the baseline rolling window
        /// remembers — feeds the NEXT night's score, not this one's.
        let nightlyFeatureMedians: Features

        /// Fraction of valid scoring windows that crossed the high
        /// threshold for each feature on this night. Composite is
        /// computed from these.
        let fracHigh: Features

        /// Diagnostic counters useful for the Pass 1 calibration
        /// check and for the Pass 3 detail screen.
        let scoringWindowCount: Int
        let displayWindowCount: Int

        /// 50%-overlap windows. Emitted so Pass 3 can draw the
        /// Poincaré plot point cloud without re-walking the RR
        /// series. Never feeds the score.
        let displayWindows: [Window]
    }

    /// Per-feature container. Used three different ways:
    /// - the night's median per feature (for the baseline)
    /// - the night's `fracHigh` per feature (for the composite)
    /// - the baseline's center / scale per feature
    struct Features: Equatable, Sendable, Codable {
        let pNN50: Double
        let cvRR: Double
        let ratio: Double
    }

    enum Band: String, Equatable, Sendable, CaseIterable {
        case consistent
        case somewhatVariable
        case notablyVariable
    }

    /// Resolved at scoring time from (a) the count of accepted prior
    /// nights and (b) whether THIS night has enough valid windows to
    /// produce a score at all. The two gates are independent: the calibration gate depends on prior
    /// nights, the data floor on this night's windows.
    enum State: Equatable, Sendable {
        /// User has fewer than `minNightsForLowConfidence` (14)
        /// accepted nights. No score, no band, no high-test math.
        case calibrating(nightsCollected: Int, nightsNeeded: Int)
        /// 14–27 accepted nights. Score renders with a wider `k`.
        case lowConfidence(nightsCollected: Int)
        /// 28+ accepted nights. Standard `k`.
        case normal
        /// THIS night didn't capture enough valid windows
        /// (< `minScoringWindowsPerNight`, i.e. < ~10 min). Independent
        /// of calibration state; produces no score and the night does
        /// NOT feed the baseline.
        case insufficientData(validWindowCount: Int)
    }

    /// One enumerated 30-second window. The analyzer emits these
    /// publicly so callers (Pass 3 Poincaré plot, tests) can inspect
    /// the per-window feature values without re-running the math.
    struct Window: Equatable, Sendable {
        /// Session-relative milliseconds the window spans.
        let startMs: Int64
        let endMs: Int64
        /// RR intervals (ms) that fell inside the window AFTER
        /// artifact filtering. Length == `nValid`.
        let rrIntervals: [Int]
        /// Per-feature values computed over `rrIntervals`. `nil` if
        /// the window is invalid (e.g. fewer than 20 valid RR intervals,
        /// or span outside 28–32 s — see `WindowKind.scoring` rules).
        let features: Features?
        /// True only when this window passed every validity check for
        /// its kind. Invalid windows are emitted with `features = nil`
        /// so the caller can still see them on the Poincaré plot but
        /// the score path ignores them.
        let isValid: Bool
    }

    enum WindowKind: Equatable, Sendable {
        /// Non-overlapping; feeds the score. Stride == length == 30 s.
        case scoring
        /// 50% overlap; for the Poincaré plot only. Stride 15 s,
        /// length 30 s. Never feeds the score.
        case display
    }

    /// Tunables. All values pinned by the Pass 1 spec; do NOT change
    /// without re-running the calibration check.
    struct Config: Equatable, Sendable {
        var windowLengthMs: Int64 = 30_000
        var displayStrideMs: Int64 = 15_000
        /// ± 2 s tolerance around window length, guards
        /// against a window straddling a long artifact gap.
        var windowSpanToleranceMs: Int64 = 2_000
        var minValidRRPerWindow: Int = 20
        var minScoringWindowsPerNight: Int = 20
        var minNightsForLowConfidence: Int = 14
        var minNightsForNormal: Int = 28
        /// Trailing windows for the baseline estimators.
        var baselineCenterWindow: Int = 28
        var baselineScaleWindow: Int = 56
        /// Winsorize the scale-window sample before MAD so
        /// one bad night doesn't inflate the threshold for weeks.
        var winsorizeLowPercentile: Double = 0.10
        var winsorizeHighPercentile: Double = 0.90

        // CALIBRATION CONSTANT — k schedule
        var kLowConfidence: Double = 4.0
        var kNormal: Double = 3.0

        // CALIBRATION CONSTANT — composite weights
        // Sum to 1.0. pNN50 carries the most interpretable magnitude
        // signal; ratio is the only orthogonal (shape) term; cvRR is
        // largely redundant with pNN50 and is downweighted pending
        // the correlation check (drop in a later pass if the
        // redundancy is confirmed across the tester set).
        var weightPNN50: Double = 0.5
        var weightCVRR: Double = 0.1
        var weightRatio: Double = 0.4

        // CALIBRATION CONSTANT — per-feature scale floors
        // The floor that stops a hyper-regular user (near-zero MAD)
        // from getting a near-zero threshold and flagging on noise.
        var pnn50ScaleFloor: Double = 2.0
        var cvrrScaleFloor: Double = 0.01
        var ratioScaleFloor: Double = 0.03

        // CALIBRATION CONSTANT — band cutoffs
        var consistentMinScore: Int = 80
        var somewhatVariableMinScore: Int = 60

        static let `default` = Config()
    }

    /// Baseline computed from prior accepted nights. The analyzer
    /// reads this to derive per-feature thresholds. Pass `nil` when
    /// the user has zero accepted nights — `State.calibrating` will
    /// be reported.
    struct Baseline: Equatable, Sendable {
        let center: Features
        let scale: Features
        /// Count of accepted nights used to compute `center` (trailing
        /// 28). Drives the `State.normal` vs `lowConfidence` gate AND
        /// the `k` schedule.
        let acceptedNightCount: Int

        /// Per-feature `(center, scale)` lookup helper. Encapsulates
        /// the floor application: the floor lives on
        /// the scale term, not on the high test.
        func threshold(feature: KeyPath<Features, Double>, k: Double) -> Double {
            center[keyPath: feature] + k * scale[keyPath: feature]
        }
    }

    // MARK: - Public entry point

    /// Score one overnight session.
    ///
    /// - Parameters:
    ///   - rr: full beat-to-beat RR series for the session, indexed
    ///     by cumulative session-relative `t_ms`.
    ///   - flags: parallel artifact-detection flags, one per `rr`
    ///     entry. Pass `[]` to treat every interval as clean.
    ///   - sleepStartMs / sleepEndMs: the session's resolved sleep
    ///     window in session-relative ms. Windows are only enumerated
    ///     INSIDE this range. Pass `(0, lastT)` if no sleep boundaries
    ///     are available (the night-level data floor still
    ///     catches short / artifact-heavy sessions).
    ///   - baseline: prior accepted-nights baseline. `nil` ⇒ calibrating.
    ///   - config: pinned spec defaults; override only for tests.
    ///
    /// - Returns: `NightlyResult`. Always returns a value — degraded
    ///   states (calibrating, insufficient data) are encoded in
    ///   `.state` rather than thrown.
    static func score(
        rr: [RRPoint],
        flags: [ArtifactFlags],
        sleepStartMs: Int64,
        sleepEndMs: Int64,
        baseline: Baseline?,
        config: Config = .default
    ) -> NightlyResult {
        // An empty flags array is treated as "all clean" — useful for
        // synthetic test data that hasn't been through ArtifactDetector.
        let cleanMask = flags.isEmpty ? Array(repeating: true, count: rr.count) : flags.map { !$0.isArtifact }
        let scoringWindows = enumerateWindows(
            rr: rr, cleanMask: cleanMask, sleepStartMs: sleepStartMs,
            sleepEndMs: sleepEndMs, kind: .scoring, config: config
        ).filter { $0.isValid }
        let displayWindows = enumerateWindows(
            rr: rr, cleanMask: cleanMask, sleepStartMs: sleepStartMs,
            sleepEndMs: sleepEndMs, kind: .display, config: config
        )
        let medians = medianFeatures(of: scoringWindows.compactMap(\.features))
        let counts = WindowCounts(scoring: scoringWindows, display: displayWindows, medians: medians)
        // Whole-night data floor. Independent of calibration state. A
        // night with too little usable sleep RR produces no score AND is not
        // eligible to feed the baseline.
        guard scoringWindows.count >= config.minScoringWindowsPerNight else {
            return counts.insufficientData()
        }
        return scored(counts: counts, baseline: baseline, config: config)
    }

    /// The window sets a result is built from, so the several degraded exits
    /// can't each assemble them slightly differently.
    private struct WindowCounts {
        let scoring: [Window]
        let display: [Window]
        let medians: Features

        func calibrating(nightsCollected: Int, config: Config) -> NightlyResult {
            result(
                score: nil, band: nil,
                state: .calibrating(
                    nightsCollected: nightsCollected,
                    nightsNeeded: config.minNightsForLowConfidence
                ),
                fracHigh: .zero
            )
        }

        func insufficientData() -> NightlyResult {
            result(score: nil, band: nil, state: .insufficientData(validWindowCount: scoring.count), fracHigh: .zero)
        }

        func result(score: Int?, band: Band?, state: State, fracHigh: Features) -> NightlyResult {
            NightlyResult(
                score: score, band: band, state: state,
                nightlyFeatureMedians: medians,
                fracHigh: fracHigh,
                scoringWindowCount: scoring.count,
                displayWindowCount: display.count,
                displayWindows: display
            )
        }
    }

    /// Calibration gate then composite. Three explicit states, no
    /// contradiction — resolved purely on prior-night count, since this night's
    /// own usability was already checked by the caller.
    private static func scored(counts: WindowCounts, baseline: Baseline?, config: Config) -> NightlyResult {
        let acceptedNights = baseline?.acceptedNightCount ?? 0
        guard acceptedNights >= config.minNightsForLowConfidence else {
            return counts.calibrating(nightsCollected: acceptedNights, config: config)
        }
        // `baseline` is guaranteed non-nil here: `acceptedNights >= 14` can
        // only come from a baseline that exists. Defensive guard (not
        // `baseline!`) — if state drifts out of sync, fall back rather than
        // trap.
        guard let bl = baseline else { return counts.insufficientData() }
        let state: State = acceptedNights < config.minNightsForNormal
            ? .lowConfidence(nightsCollected: acceptedNights)
            : .normal
        let fracHigh = computeFracHigh(
            windows: counts.scoring.compactMap(\.features), baseline: bl,
            k: (state == .normal) ? config.kNormal : config.kLowConfidence
        )
        let score = compositeScore(fracHigh: fracHigh, config: config)
        return counts.result(score: score, band: band(for: score, config: config), state: state, fracHigh: fracHigh)
    }

    /// Composite. `raw` is in [0, 1] since each frac_high is in [0, 1] and
    /// the weights sum to 1.
    private static func compositeScore(fracHigh: Features, config: Config) -> Int {
        let raw = config.weightPNN50 * fracHigh.pNN50
            + config.weightCVRR * fracHigh.cvRR
            + config.weightRatio * fracHigh.ratio
        return Int(round(100 * (1 - raw)))
    }

    private static func band(for score: Int, config: Config) -> Band {
        if score >= config.consistentMinScore { return .consistent }
        if score >= config.somewhatVariableMinScore { return .somewhatVariable }
        return .notablyVariable
    }

    // MARK: - Baseline assembly

    /// Build the per-user baseline from a list of prior accepted
    /// nights' median values. Caller is responsible for filtering out
    /// nights that returned `.insufficientData` (those don't qualify) and for ordering newest-first.
    ///
    /// Returns `nil` when there's nothing to base on. Pass `nil` to
    /// `score(...)` in that case — it will surface `.calibrating`.
    static func buildBaseline(
        priorNights: [Features],
        config: Config = .default
    ) -> Baseline? {
        guard !priorNights.isEmpty else { return nil }
        let centerSample = Array(priorNights.prefix(config.baselineCenterWindow))
        let scaleSample = Array(priorNights.prefix(config.baselineScaleWindow))
        return Baseline(
            center: Features(
                pNN50: median(centerSample.map(\.pNN50)),
                cvRR: median(centerSample.map(\.cvRR)),
                ratio: median(centerSample.map(\.ratio))
            ),
            scale: baselineScale(scaleSample, config: config),
            acceptedNightCount: priorNights.count
        )
    }

    /// Winsorized MAD per feature, floored so a run of near-identical nights
    /// can't collapse the scale to zero and make every deviation look extreme.
    private static func baselineScale(_ scaleSample: [Features], config: Config) -> Features {
        func mad(_ values: [Double], floor: Double) -> Double {
            max(
                winsorizedMAD(
                    values,
                    low: config.winsorizeLowPercentile,
                    high: config.winsorizeHighPercentile
                ),
                floor
            )
        }
        return Features(
            pNN50: mad(scaleSample.map(\.pNN50), floor: config.pnn50ScaleFloor),
            cvRR: mad(scaleSample.map(\.cvRR), floor: config.cvrrScaleFloor),
            ratio: mad(scaleSample.map(\.ratio), floor: config.ratioScaleFloor)
        )
    }

    // MARK: - Window enumeration

    /// Walk forward from sleep start. A window's "official" end is `start +
    /// length` and it can extend up to `sleepEndMs` — the last window's NOMINAL
    /// end is not truncated, but the span-tolerance check rejects anything that
    /// doesn't actually contain enough data inside `[start, end)`.
    ///
    /// The loop condition must NOT be `startMs + windowLengthMs <=
    /// sleepEndMs`: that contradicts the above by dropping the final window
    /// entirely whenever the nominal end runs past `sleepEndMs`, instead of
    /// enumerating it and letting the span check decide. Fence-post effect: N
    /// beats at 1000 ms span (N−1) s of t_ms, so a 600-beat / 10-min night
    /// would produce 19 windows, not the spec'd 20 — every night losing up to
    /// one valid scoring window, and nights near the 20-window data floor
    /// misclassified as Insufficient Data. Pinned by BeatConsistencyTests
    /// (testWindowing…, testInsufficient…, testCalibrationGate…,
    /// testScaleFloor…).
    private static func enumerateWindows(
        rr: [RRPoint],
        cleanMask: [Bool],
        sleepStartMs: Int64,
        sleepEndMs: Int64,
        kind: WindowKind,
        config: Config
    ) -> [Window] {
        guard !rr.isEmpty, sleepEndMs > sleepStartMs else { return [] }
        let stride: Int64 = (kind == .scoring) ? config.windowLengthMs : config.displayStrideMs
        var windows: [Window] = []
        var startMs = sleepStartMs
        while startMs < sleepEndMs {
            windows.append(window(rr: rr, cleanMask: cleanMask, startMs: startMs, config: config))
            startMs += stride
        }
        return windows
    }

    private static func window(
        rr: [RRPoint],
        cleanMask: [Bool],
        startMs: Int64,
        config: Config
    ) -> Window {
        let endMs = startMs + config.windowLengthMs
        let windowRR = inWindow(rr: rr, cleanMask: cleanMask, startMs: startMs, endMs: endMs)
        let isValid = validateWindow(
            rrInWindow: windowRR,
            expectedLengthMs: config.windowLengthMs,
            toleranceMs: config.windowSpanToleranceMs,
            minN: config.minValidRRPerWindow
        )
        return Window(
            startMs: startMs, endMs: endMs,
            rrIntervals: windowRR.intervals,
            features: isValid ? computeFeatures(rrIntervals: windowRR.intervals) : nil,
            isValid: isValid
        )
    }

    /// Extract the RR intervals that fall inside [startMs, endMs) and
    /// pass the clean mask. Returns the intervals plus the span (last
    /// minus first `t_ms`) for the validity check. `rr` is in time order,
    /// so the scan starts at the first beat at or after `startMs` (binary
    /// search) instead of rescanning the night from the first beat.
    private static func inWindow(
        rr: [RRPoint],
        cleanMask: [Bool],
        startMs: Int64,
        endMs: Int64
    ) -> (intervals: [Int], span: Int64) {
        var intervals: [Int] = []
        var firstT: Int64?
        var lastT: Int64?
        for i in firstIndex(in: rr, atOrAfter: startMs) ..< rr.count {
            let point = rr[i]
            guard point.t_ms < endMs else { break }
            guard i < cleanMask.count, cleanMask[i] else { continue }
            intervals.append(point.rr_ms)
            if firstT == nil { firstT = point.t_ms }
            lastT = point.t_ms
        }
        let span: Int64 = if let firstT, let lastT { lastT - firstT } else { 0 }
        return (intervals, span)
    }

    /// Index of the first beat with `t_ms >= ms`, or `rr.count` when none.
    private static func firstIndex(in rr: [RRPoint], atOrAfter ms: Int64) -> Int {
        var lo = 0, hi = rr.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if rr[mid].t_ms < ms { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private static func validateWindow(
        rrInWindow: (intervals: [Int], span: Int64),
        expectedLengthMs: Int64,
        toleranceMs: Int64,
        minN: Int
    ) -> Bool {
        guard rrInWindow.intervals.count >= minN else { return false }
        // Span check: with at least `minN` intervals at ~1 Hz the
        // last-first gap should be close to the window length. A
        // window that straddles a long artifact dropout will have a
        // tiny span (most data fell on one side) and gets rejected.
        let span = rrInWindow.span
        let lowerBound = expectedLengthMs - toleranceMs
        let upperBound = expectedLengthMs + toleranceMs
        return span >= lowerBound && span <= upperBound
    }

    // MARK: - Per-window features

    /// Returns `Features.zero` when the input is too short
    /// (caller has already validated `count >= minValidRRPerWindow`,
    /// so this is defensive — the floor on `count < 2` keeps the
    /// pNN50 denominator and SD math safe).
    static func computeFeatures(rrIntervals: [Int]) -> Features {
        let n = rrIntervals.count
        guard n >= 2 else { return .zero }
        let rrDoubles = rrIntervals.map(Double.init)
        var nn50Count = 0
        for i in 1 ..< n where abs(rrDoubles[i] - rrDoubles[i - 1]) > 50 {
            nn50Count += 1
        }
        // Population variance (divisor N) throughout: "Use
        // population stddev, be consistent across all three features".
        let mean = rrDoubles.reduce(0, +) / Double(n)
        let variance = populationVariance(rrDoubles, mean: mean)
        return Features(
            pNN50: 100.0 * Double(nn50Count) / Double(n - 1),
            cvRR: mean > 0 ? sqrt(variance) / mean : 0,
            ratio: poincareRatio(rrDoubles, variance: variance)
        )
    }

    private static func populationVariance(_ values: [Double], mean: Double) -> Double {
        values.reduce(0.0) { acc, v in acc + (v - mean) * (v - mean) } / Double(values.count)
    }

    /// SD1 / SD2 (Poincaré). When `2*var - SD1^2 <= 0` the ratio
    /// is 0 — no NaN, no crash.
    private static func poincareRatio(_ rrDoubles: [Double], variance: Double) -> Double {
        let diffs = (1 ..< rrDoubles.count).map { rrDoubles[$0] - rrDoubles[$0 - 1] }
        let diffMean = diffs.reduce(0, +) / Double(diffs.count)
        let sd1 = sqrt(populationVariance(diffs, mean: diffMean)) / sqrt(2)
        let sd2Squared = 2 * variance - sd1 * sd1
        let sd2 = sd2Squared > 0 ? sqrt(sd2Squared) : 0
        return sd2 > 0 ? sd1 / sd2 : 0
    }

    // MARK: - Per-night reductions

    private static func medianFeatures(of windows: [Features]) -> Features {
        guard !windows.isEmpty else { return .zero }
        return Features(
            pNN50: median(windows.map(\.pNN50)),
            cvRR: median(windows.map(\.cvRR)),
            ratio: median(windows.map(\.ratio))
        )
    }

    private static func computeFracHigh(
        windows: [Features],
        baseline: Baseline,
        k: Double
    ) -> Features {
        guard !windows.isEmpty else { return .zero }
        let total = Double(windows.count)
        let highPNN50 = windows.filter { $0.pNN50 > baseline.threshold(feature: \.pNN50, k: k) }.count
        let highCV = windows.filter { $0.cvRR > baseline.threshold(feature: \.cvRR, k: k) }.count
        let highRatio = windows.filter { $0.ratio > baseline.threshold(feature: \.ratio, k: k) }.count
        return Features(
            pNN50: Double(highPNN50) / total,
            cvRR: Double(highCV) / total,
            ratio: Double(highRatio) / total
        )
    }

    // MARK: - Statistics

    /// Plain median. Average of the two middle elements on even counts.
    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    /// Winsorized MAD scaled to stddev-equivalent:
    ///   - Clamp the sample at the [low, high] percentile (10/90 by default).
    ///   - Compute MAD = median(|x - median(x)|).
    ///   - Multiply by 1.4826 so the result is comparable to a stddev
    ///     for normal data.
    /// Returns 0 for an empty sample (caller floors).
    static func winsorizedMAD(_ values: [Double], low: Double, high: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let lowIdx = max(0, Int(Double(sorted.count - 1) * low))
        let highIdx = min(sorted.count - 1, Int(round(Double(sorted.count - 1) * high)))
        let lowCap = sorted[lowIdx]
        let highCap = sorted[highIdx]
        let winsorized = sorted.map { min(max($0, lowCap), highCap) }
        let med = median(winsorized)
        let abs = winsorized.map { Swift.abs($0 - med) }
        return median(abs) * 1.4826
    }
}

// MARK: - Conveniences

extension BeatConsistency.Features {
    static let zero = BeatConsistency.Features(pNN50: 0, cvRR: 0, ratio: 0)
}

extension BeatConsistency.State {
    /// True when this night's feature medians qualify to be accumulated
    /// into the rolling baseline that feeds NEXT night's score. The only
    /// state that does NOT feed is `.insufficientData` — too few valid
    /// scoring windows means the median would be unreliable.
    var feedsBaseline: Bool {
        switch self {
        case .insufficientData: false
        case .calibrating, .lowConfidence, .normal: true
        }
    }
}
