import Foundation

// `typealias Wts = <WeightsStruct>` is deliberate. These are dense linear
// combinations — `(1 - ranks.hr[i]) * Wts.hr + ranks.rmssd[i] * Wts.rmssd + …` —
// where the alias exists so one formula fits on one line and reads like the
// equation it implements. Spelling it out wraps every term and makes the
// structure harder to check against the paper.
//
// `Wts` rather than `W`: the type-name rule's three-character minimum costs
// two characters here and avoids a blanket waiver for the whole file.
enum HRVSleepStageClassifier {
    // MARK: - Types

    struct ClassificationResult {
        let stageIntervals: [HealthKitManager.SleepStageInterval]
        let deepSleepMinutes: Int
        let remSleepMinutes: Int
        let coreSleepMinutes: Int
        let awakeMinutes: Int
    }

    /// Per-window composite scores for each stage candidate.
    struct WindowScores {
        let deepScore: Double
        let remScore: Double
        let awakeScore: Double
        let classifiedStage: HealthKitManager.SleepStage
        /// Whether this window had its own LF/HF ratio (scored with the
        /// frequency-domain weights). A window without one, on a night where
        /// others have it, is ranked on a filler value and reads false here.
        /// Critical for augmentation gating: LF/HF is the only cardiac feature
        /// that reliably separates REM from N2 (Vanoli 1995, Herzig 2017).
        let hasFreqDomain: Bool
        /// The REM score before the first-hour suppression. `remScore` is 0
        /// there so classification never calls early REM; augmentation's
        /// "Watch REM has weak REM evidence" check reads this instead, so the
        /// forced 0 is not taken as evidence against REM. Nil means the same
        /// as `remScore`.
        var remEvidence: Double?
    }

    /// Result of augmenting Apple Watch stages with HRV evidence.
    struct AugmentationResult {
        let stageIntervals: [HealthKitManager.SleepStageInterval]
        let deepSleepMinutes: Int
        let remSleepMinutes: Int
        let coreSleepMinutes: Int
        let awakeMinutes: Int
        let augmentationCount: Int
        let augmentations: [Augmentation]
    }

    /// A single epoch where HRV evidence overrode the Watch stage.
    struct Augmentation {
        let windowStart: Date
        let windowEnd: Date
        let watchStage: HealthKitManager.SleepStage
        let augmentedStage: HealthKitManager.SleepStage
        let score: Double
    }

    struct FeatureWindow {
        let startDate: Date
        let endDate: Date
        let midpointMs: Int64
        // Time domain
        let hr: Double
        let rmssd: Double
        let sdnn: Double
        let hrCV: Double
        /// Nonlinear
        let dfaAlpha1: Double?
        // Frequency domain
        let lfHfRatio: Double?
        let hfPower: Double?
    }

    // MARK: - Configuration

    private static let windowSizeMs: Int64 = 5 * 60 * 1000
    private static let minPointsPerWindow = 10
    private static let minValidRRsPerWindow = 8
    static let minWindowsForClassification = 6
    private static let minBeatsForDFA = 64

    /// No REM before ~60 min. First cycle is NREM-dominant (Carskadon & Dement 2017).
    /// First REM ~70–90 min post-onset; first cycle NREM-dominant — Carskadon &
    /// Dement, Principles & Practice of Sleep Medicine 6e, 2017.
    private static let minTimeBeforeREMMs: Int64 = 60 * 60 * 1000

    /// Score thresholds and augmentation thresholds are centralized in
    /// SleepClassifierConstants (Constants.swift).
    /// Aliases for brevity within this file:
    private static var deepScoreThreshold: Double {
        SleepClassifierConstants.deepScoreThreshold
    }

    private static var remScoreThreshold: Double {
        SleepClassifierConstants.remScoreThreshold
    }

    static var awakeScoreThreshold: Double {
        SleepClassifierConstants.awakeScoreThreshold
    }

    static var augmentCoreToDeepThreshold: Double {
        SleepClassifierConstants.augmentCoreToDeepThreshold
    }

    static var augmentCoreToREMThreshold: Double {
        SleepClassifierConstants.augmentCoreToREMThreshold
    }

    static var augmentAwakeToREMThreshold: Double {
        SleepClassifierConstants.augmentAwakeToREMThreshold
    }

    static var augmentCrossStageThreshold: Double {
        SleepClassifierConstants.augmentCrossStageThreshold
    }

    static var augmentCrossStageRejectThreshold: Double {
        SleepClassifierConstants.augmentCrossStageRejectThreshold
    }

    // MARK: - Public API

    static func classify(
        rrPoints: [RRPoint],
        sleepStartMs: Int64,
        sleepEndMs: Int64,
        recordingStart: Date
    ) -> ClassificationResult? {
        guard sleepEndMs > sleepStartMs else { return nil }
        let windows = buildFeatureWindows(
            rrPoints: rrPoints,
            sleepStartMs: sleepStartMs,
            sleepEndMs: sleepEndMs,
            recordingStart: recordingStart
        )
        guard windows.count >= minWindowsForClassification else {
            debugLog("[HRVSleepStageClassifier] Insufficient windows: \(windows.count) < \(minWindowsForClassification)")
            return nil
        }
        var rawStages = classifyWindows(windows, sleepStartMs: sleepStartMs)
        rawStages = smoothStages(rawStages)
        return summarise(buildIntervals(windows: windows, stages: rawStages))
    }

    /// Minutes per stage. `.unspecified` counts as core, matching how
    /// HealthKit's own "asleep" bucket is presented everywhere else.
    private static func summarise(_ intervals: [HealthKitManager.SleepStageInterval]) -> ClassificationResult {
        let minutes = accumulateStageMinutes(intervals)
        return ClassificationResult(
            stageIntervals: intervals, deepSleepMinutes: minutes.deep, remSleepMinutes: minutes.rem,
            coreSleepMinutes: minutes.core, awakeMinutes: minutes.awake
        )
    }

    // MARK: - Feature Computation

    /// Five-minute feature windows over `[sleepStartMs, sleepEndMs)`, both
    /// wall-clock ms from `recordingStart`. Beats are placed on the wall clock
    /// (`exportTimeMs`), not the beat-sum clock `t_ms`, which falls behind real
    /// time after a streamed night's BLE drops; so window membership, the
    /// bounds and the window dates all sit on the one clock the callers'
    /// bounds and the Watch's intervals use.
    static func buildFeatureWindows(
        rrPoints: [RRPoint],
        sleepStartMs: Int64,
        sleepEndMs: Int64,
        recordingStart: Date
    ) -> [FeatureWindow] {
        var windows: [FeatureWindow] = []
        var windowStart = sleepStartMs
        let timed = wallClockTimed(rrPoints)
        // Two-pointer sweep instead of a per-window filter: `timed` is
        // time-ordered and the window bounds advance monotonically, so
        // membership is identical while cost drops from O(windows x n) to O(n).
        var sweep = RRWindowSweep(timed)
        while windowStart < sleepEndMs {
            let windowEnd = min(windowStart + windowSizeMs, sleepEndMs)
            let points = Array(timed[sweep.range(start: windowStart, end: windowEnd)])
            if let window = featureWindow(points: points, windowStart: windowStart,
                                          windowEnd: windowEnd, recordingStart: recordingStart) {
                windows.append(window)
            }
            windowStart += windowSizeMs
        }
        return windows
    }

    /// The beats re-timed on the wall clock (`t_ms` = `exportTimeMs`), in
    /// time order. A series that is already ordered keeps its beat order
    /// (beats of one BLE packet share a wall-clock stamp); a merged series
    /// that is not is sorted, so the sweep never skips beats.
    static func wallClockTimed(_ rrPoints: [RRPoint]) -> [RRPoint] {
        let timed = rrPoints.map { RRPoint(t_ms: $0.exportTimeMs, rr_ms: $0.rr_ms, wallClockMs: $0.wallClockMs, hr: $0.hr) }
        let ordered = zip(timed, timed.dropFirst()).allSatisfy { $0.t_ms <= $1.t_ms }
        return ordered ? timed : timed.sorted { $0.t_ms < $1.t_ms }
    }

    /// One window's features, or nil when the window is too sparse or too
    /// artifact-ridden to describe.
    ///
    /// HR, SDNN and CV take every valid beat. The beat-to-beat features do
    /// not join beats across a gap: RMSSD differences only beats adjacent in
    /// the recording (no invalid beat dropped between them, no recording
    /// break), and α1 and LF/HF/HF run on the longest break-free stretch
    /// (see `SleepWindowBeats`).
    private static func featureWindow(
        points windowPoints: [RRPoint],
        windowStart: Int64,
        windowEnd: Int64,
        recordingStart: Date
    ) -> FeatureWindow? {
        guard windowPoints.count >= minPointsPerWindow else { return nil }
        let beats = SleepWindowBeats(windowPoints)
        let validRRs = beats.validRRs
        guard validRRs.count >= minValidRRsPerWindow else { return nil }
        let avgRR = validRRs.reduce(0, +) / Double(validRRs.count)
        let followsPrevious = beats.validFollowsPrevious
        let stats = windowVariability(validRRs, avgRR: avgRR) { followsPrevious[$0] }
        let freq = windowFrequencyMetrics(beats)
        return FeatureWindow(
            startDate: recordingStart.addingTimeInterval(Double(windowStart) / 1_000.0),
            endDate: recordingStart.addingTimeInterval(Double(windowEnd) / 1_000.0),
            midpointMs: windowStart + windowSizeMs / 2,
            hr: 60_000.0 / avgRR,
            rmssd: stats.rmssd, sdnn: stats.sdnn, hrCV: stats.hrCV,
            dfaAlpha1: windowAlpha1(beats),
            lfHfRatio: freq?.lfHfRatio, hfPower: freq?.hf
        )
    }

    /// RMSSD, SDNN and the RR-based coefficient of variation.
    ///
    /// RMSSD takes the difference `validRRs[i] - validRRs[i - 1]` only where
    /// `followsPrevious(i)`: beat `i` came straight after beat `i - 1` in the
    /// recording. Differencing across a dropped beat or a recording break
    /// would add one spurious difference per gap (Task Force 1996: differences
    /// of ADJACENT intervals; the same rule as
    /// `TimeDomainAnalyzer.rmssd(fromRRs:isValid:followsBreak:)`). With no
    /// such pair RMSSD is 0, as for a window of one beat. The default treats
    /// every pair as adjacent, for a gap-free series.
    ///
    /// SDNN here is the POPULATION variance (divisor N), deliberately not routed
    /// through `Statistics`, which offers only sample variance (divisor N-1).
    /// The two diverge most on short windows, which is all this classifier
    /// runs on.
    ///
    /// `internal` rather than `private` so the divisor can be
    /// pinned by a test: the comment above is otherwise the only thing
    /// distinguishing the two formulas, and a mutation to N-1 would survive
    /// the classifier's whole suite.
    nonisolated static func windowVariability(
        _ validRRs: [Double], avgRR: Double, followsPrevious: (Int) -> Bool = { _ in true }
    ) -> (rmssd: Double, sdnn: Double, hrCV: Double) {
        guard validRRs.count > 1 else { return (rmssd: 0, sdnn: 0, hrCV: 0) }

        var diffs = [Double]()
        diffs.reserveCapacity(validRRs.count - 1)
        for i in 1 ..< validRRs.count where followsPrevious(i) {
            diffs.append(validRRs[i] - validRRs[i - 1])
        }
        let variance = validRRs.map { pow($0 - avgRR, 2) }.reduce(0, +) / Double(validRRs.count)
        let sdnn = sqrt(variance)
        return (Statistics.rootMeanSquare(diffs), sdnn, avgRR > 0 ? sdnn / avgRR : 0)
    }

    /// DFA α1 over the window's longest break-free stretch, its invalid beats
    /// linearly interpolated in place (Kubios; Lipponen & Tarvainen 2019), so
    /// a dropped beat is not read as two beats being adjacent and no fit spans
    /// a recording break. Nil when that stretch has fewer than
    /// `minBeatsForDFA` beats, more of it interpolated than the live α1 path
    /// accepts (`LiveDFAAnalyzer.maxCorrectedFraction`), or DFA cannot fit.
    private static func windowAlpha1(_ beats: SleepWindowBeats) -> Double? {
        guard let series = beats.interpolatedStretch(), series.values.count >= minBeatsForDFA,
              series.correctedFraction <= LiveDFAAnalyzer.maxCorrectedFraction else { return nil }
        return DFAAnalyzer.compute(series.values)?.alpha1
    }

    /// LF/HF and HF power through the shared PSD pipeline, from cubic-spline
    /// resampled (time, rr) pairs of the window's longest break-free stretch:
    /// the beat-sum clock does not advance across a recording break, so beats
    /// on either side of one would be spliced together as if continuous. Each
    /// valid beat's time is its midpoint on the beat-sum clock within the
    /// stretch (the intervals before it, invalid ones included, so the spline
    /// spans a dropped beat at its true time): the wall-clock stamps the
    /// window was cut on repeat for the beats of one BLE packet, which a
    /// spline cannot take as times.
    private static func windowFrequencyMetrics(_ beats: SleepWindowBeats) -> FrequencyDomainMetrics? {
        guard let stretch = beats.longestStretch else { return nil }
        var elapsedMs = 0.0
        var times: [Double] = []
        var rrValues: [Double] = []
        for i in stretch {
            let rr = Double(beats.points[i].rr_ms)
            if beats.isValid[i] {
                times.append((elapsedMs + rr / 2.0) / 1_000.0)
                rrValues.append(rr)
            }
            elapsedMs += rr
        }
        return FrequencyDomainAnalyzer.computeFromCleanPairs(times: times, rrValues: rrValues)
    }

    // MARK: - Rank-Based Classification

    /// Compute per-window composite scores for deep, REM, and awake stages.
    /// Used by both standalone classification and Watch stage augmentation.
    ///
    /// Weights reflect research-validated feature importance for cardiac sleep staging
    /// (Fonseca 2015, Xiao 2013, Radha 2019). LF/HF ratio carries the most weight
    /// for deep/REM discrimination — it is the strongest single cardiac discriminator
    /// between these stages (Vanoli 1995).
    ///
    /// DFA α1 direction (Penzel 2003, Bunde 2000):
    /// - Deep sleep has the LOWEST α1 of the night
    /// - REM has the HIGHEST — closest to the correlated pattern seen in wake
    /// - So: low dfaRank → deep-like, high dfaRank → REM-like
    ///
    /// Only the DIRECTION matters here: the classifier ranks windows against
    /// each other within one night and never compares α1 to an absolute
    /// threshold, so it is unaffected by which scale the numbers below come
    /// from. That is worth stating, because the two available sources disagree
    /// on the magnitude.
    ///
    /// Deep sleep is NOT "~0.5-0.7,
    /// anti-correlated" here. Bunde 2000 does report NREM heart rates as
    /// essentially uncorrelated, but ABOVE the breathing-cycle timescale —
    /// and α1 is the SHORT-scale exponent, measured inside the respiratory
    /// band, so that figure is not an α1 value. The α1 numbers this repo cites
    /// elsewhere (`WindowSelector.RecoveryWindow.optimalAlpha1Range`,
    /// PMC4100066) are N1 0.89 ± 0.23, N2 0.85 ± 0.16, N3 0.78 ± 0.21: same
    /// ordering, much narrower spread, and nowhere near 0.5.
    ///
    /// Quoting both would state two incompatible magnitudes for one quantity,
    /// in two files that both drive behaviour. Neither citation is wrong; they
    /// describe different scales. The magnitude claim is omitted here because
    /// this code does not use one, and the user-facing copy quotes the
    /// PMC4100066 figures, which are the ones that are actually about α1.
    static func computeWindowScores(
        _ windows: [FeatureWindow],
        sleepStartMs: Int64
    ) -> [WindowScores] {
        let ranks = computeFeatureRanks(windows)
        let hasFreqDomain = windows.contains { $0.lfHfRatio != nil }
        let hasDFA = windows.contains { $0.dfaAlpha1 != nil }
        let nightDurationMs = max(1, (windows.last?.midpointMs ?? sleepStartMs) - sleepStartMs)
        return (0 ..< windows.count).map { i in
            windowScores(
                ranks: ranks, index: i,
                elapsedMs: windows[i].midpointMs - sleepStartMs,
                nightDurationMs: nightDurationMs,
                hasFreqDomain: hasFreqDomain, hasDFA: hasDFA
            )
        }
    }

    private static func windowScores(
        ranks: FeatureRanks,
        index i: Int,
        elapsedMs: Int64,
        nightDurationMs: Int64,
        hasFreqDomain: Bool,
        hasDFA: Bool
    ) -> WindowScores {
        let nightFraction = Double(elapsedMs) / Double(nightDurationMs)
        let deepScore = computeDeepScore(
            ranks: ranks, index: i, nightFraction: nightFraction,
            hasFreqDomain: hasFreqDomain, hasDFA: hasDFA
        )
        // REM this early in the night is a misread, not a short latency.
        var remScore = computeREMScore(
            ranks: ranks, index: i, nightFraction: nightFraction,
            hasFreqDomain: hasFreqDomain, hasDFA: hasDFA
        )
        let remEvidence = remScore
        if elapsedMs < minTimeBeforeREMMs { remScore = 0 }
        let awakeScore = computeAwakeScore(ranks: ranks, index: i, hasFreqDomain: hasFreqDomain)
        return WindowScores(
            deepScore: deepScore, remScore: remScore, awakeScore: awakeScore,
            classifiedStage: classifyStage(deepScore: deepScore, remScore: remScore, awakeScore: awakeScore),
            hasFreqDomain: hasFreqDomain && ranks.lfHfPresent[i], remEvidence: remEvidence
        )
    }

    // MARK: - Score Computation Helpers

    /// Pre-computed per-feature rank arrays for all windows.
    private struct FeatureRanks {
        let hr, rmssd, cv, hf, lfHf, dfa: [Double]
        /// Whether each window had its own LF/HF (the rank uses a filler when not).
        let lfHfPresent: [Bool]
    }

    private static func computeFeatureRanks(_ windows: [FeatureWindow]) -> FeatureRanks {
        let dfaValues = windows.map(\.dfaAlpha1)
        let validDFAs = dfaValues.compactMap { $0 }
        let medianDFA = validDFAs.isEmpty ? SleepClassifierConstants.fallbackMedianDFA : validDFAs.sorted()[validDFAs.count / 2]

        return FeatureRanks(
            hr: computeRanks(windows.map(\.hr)),
            rmssd: computeRanks(windows.map(\.rmssd)),
            cv: computeRanks(windows.map(\.hrCV)),
            hf: computeRanks(windows.map { $0.hfPower ?? 0 }),
            lfHf: computeRanks(windows.map { $0.lfHfRatio ?? 2.0 }),
            dfa: computeRanks(dfaValues.map { $0 ?? medianDFA }),
            lfHfPresent: windows.map { $0.lfHfRatio != nil }
        )
    }

    private static func computeDeepScore(
        ranks: FeatureRanks,
        index i: Int,
        nightFraction: Double,
        hasFreqDomain: Bool,
        hasDFA: Bool
    ) -> Double {
        let temporal = deepTemporalBonus(nightFraction)
        if hasFreqDomain, hasDFA {
            typealias Wts = SleepClassifierConstants.DeepWeightsAllFeatures
            return (1.0 - ranks.hr[i]) * Wts.hr + ranks.rmssd[i] * Wts.rmssd + (1.0 - ranks.cv[i]) * Wts.cv
                + ranks.hf[i] * Wts.hf + (1.0 - ranks.lfHf[i]) * Wts.lfHf + (1.0 - ranks.dfa[i]) * Wts.dfa + temporal * Wts.temporal
        } else if hasFreqDomain {
            typealias Wts = SleepClassifierConstants.DeepWeightsFreqOnly
            return (1.0 - ranks.hr[i]) * Wts.hr + ranks.rmssd[i] * Wts.rmssd + (1.0 - ranks.cv[i]) * Wts.cv
                + ranks.hf[i] * Wts.hf + (1.0 - ranks.lfHf[i]) * Wts.lfHf + temporal * Wts.temporal
        } else if hasDFA {
            typealias Wts = SleepClassifierConstants.DeepWeightsDFAOnly
            return (1.0 - ranks.hr[i]) * Wts.hr + ranks.rmssd[i] * Wts.rmssd + (1.0 - ranks.cv[i]) * Wts.cv
                + (1.0 - ranks.dfa[i]) * Wts.dfa + temporal * Wts.temporal
        } else {
            typealias Wts = SleepClassifierConstants.DeepWeightsTimeDomainOnly
            return (1.0 - ranks.hr[i]) * Wts.hr + ranks.rmssd[i] * Wts.rmssd + (1.0 - ranks.cv[i]) * Wts.cv + temporal * Wts.temporal
        }
    }

    /// Deep clusters early in the night; REM clusters late. The bonus encodes
    /// that prior so a mid-night window is not scored as if position told us
    /// nothing.
    private static func deepTemporalBonus(_ nightFraction: Double) -> Double {
        nightFraction < SleepClassifierConstants.deepTemporalEarlyEnd ? 1.0
            : (
                nightFraction < SleepClassifierConstants.deepTemporalMidEnd
                    ? SleepClassifierConstants.deepTemporalMidBonus : SleepClassifierConstants.deepTemporalLateBonus
            )
    }

    private static func computeREMScore(
        ranks: FeatureRanks,
        index i: Int,
        nightFraction: Double,
        hasFreqDomain: Bool,
        hasDFA: Bool
    ) -> Double {
        let temporal = remTemporalBonus(nightFraction)
        if hasFreqDomain, hasDFA {
            typealias Wts = SleepClassifierConstants.REMWeightsAllFeatures
            return (1.0 - ranks.rmssd[i]) * Wts.rmssd + ranks.cv[i] * Wts.cv + ranks.lfHf[i] * Wts.lfHf
                + (1.0 - ranks.hf[i]) * Wts.hf + ranks.dfa[i] * Wts.dfa + temporal * Wts.temporal
        } else if hasFreqDomain {
            typealias Wts = SleepClassifierConstants.REMWeightsFreqOnly
            return (1.0 - ranks.rmssd[i]) * Wts.rmssd + ranks.cv[i] * Wts.cv + ranks.lfHf[i] * Wts.lfHf
                + (1.0 - ranks.hf[i]) * Wts.hf + temporal * Wts.temporal
        } else if hasDFA {
            typealias Wts = SleepClassifierConstants.REMWeightsDFAOnly
            return (1.0 - ranks.rmssd[i]) * Wts.rmssd + ranks.cv[i] * Wts.cv + ranks.dfa[i] * Wts.dfa + temporal * Wts.temporal
        } else {
            typealias Wts = SleepClassifierConstants.REMWeightsTimeDomainOnly
            return (1.0 - ranks.rmssd[i]) * Wts.rmssd + ranks.cv[i] * Wts.cv + temporal * Wts.temporal
        }
    }

    /// Deep clusters early in the night; REM clusters late. The bonus encodes
    /// that prior so a mid-night window is not scored as if position told us
    /// nothing.
    private static func remTemporalBonus(_ nightFraction: Double) -> Double {
        nightFraction > SleepClassifierConstants.remTemporalLateStart ? 1.0
            : (
                nightFraction > SleepClassifierConstants.remTemporalMidStart
                    ? SleepClassifierConstants.remTemporalMidBonus : 0.0
            )
    }

    private static func computeAwakeScore(
        ranks: FeatureRanks,
        index i: Int,
        hasFreqDomain: Bool
    ) -> Double {
        if hasFreqDomain {
            typealias Wts = SleepClassifierConstants.AwakeWeightsWithFreq
            return ranks.hr[i] * Wts.hr + (1.0 - ranks.rmssd[i]) * Wts.rmssd + ranks.cv[i] * Wts.cv
                + ranks.lfHf[i] * Wts.lfHf + (1.0 - ranks.hf[i]) * Wts.hf
        } else {
            typealias Wts = SleepClassifierConstants.AwakeWeightsWithoutFreq
            return ranks.hr[i] * Wts.hr + (1.0 - ranks.rmssd[i]) * Wts.rmssd + ranks.cv[i] * Wts.cv + ranks.dfa[i] * Wts.dfa
        }
    }

    private static func classifyStage(deepScore: Double, remScore: Double, awakeScore: Double) -> HealthKitManager.SleepStage {
        if awakeScore > awakeScoreThreshold { return .awake }
        if deepScore > deepScoreThreshold, deepScore >= remScore { return .deep }
        if remScore > remScoreThreshold, remScore > deepScore { return .rem }
        return .core
    }

    /// Classify each window using rank-based composite scoring across 7 features.
    /// Delegates to computeWindowScores and extracts the classified stage.
    static func classifyWindows(
        _ windows: [FeatureWindow],
        sleepStartMs: Int64
    ) -> [HealthKitManager.SleepStage] {
        computeWindowScores(windows, sleepStartMs: sleepStartMs).map(\.classifiedStage)
    }

    /// Compute fractional ranks: 0.0 = lowest, 1.0 = highest. Tied values
    /// share the average of the ranks they span. Missing features are filled
    /// with constants (α1 → the night's median, LF/HF → 2.0, HF → 0), so ties
    /// are common; breaking them by position would turn a tied feature into a
    /// ramp from the start of the night to the end. A night with no α1 at all
    /// gives every window 0.5, a neutral, constant DFA term.
    static func computeRanks(_ values: [Double]) -> [Double] {
        guard values.count > 1 else { return values.map { _ in 0.5 } }
        let n = Double(values.count - 1)
        // Sort positions by value, then write each tie group's mean position
        // back into the original slots.
        let order = values.indices.sorted { values[$0] < values[$1] }
        var ranks = [Double](repeating: 0, count: values.count)
        var groupStart = 0
        while groupStart < order.count {
            let groupEnd = tieGroupEnd(order, values: values, from: groupStart)
            let meanRank = Double(groupStart + groupEnd - 1) / 2.0 / n
            for k in groupStart ..< groupEnd { ranks[order[k]] = meanRank }
            groupStart = groupEnd
        }
        return ranks
    }

    /// One past the last position in `order` whose value equals the value at
    /// `start`.
    private static func tieGroupEnd(_ order: [Int], values: [Double], from start: Int) -> Int {
        var end = start + 1
        while end < order.count, values[order[end]] == values[order[start]] { end += 1 }
        return end
    }
}

/// One feature window's beats, with what the beat-to-beat features need to
/// know about where the beats are NOT adjacent: which beats are invalid
/// (outside `HRVConstants.RRInterval`) and which follow a recording break
/// (`TimeDomainAnalyzer.isRecordingBreak`, on the wall-clock-timed beats the
/// window was cut from, so a Bluetooth dropout counts).
///
/// A file-scope type rather than more members on `HRVSleepStageClassifier`,
/// whose body is already large.
private struct SleepWindowBeats {
    let points: [RRPoint]
    let isValid: [Bool]
    /// Indices into `points` whose beat follows a recording break.
    let breaks: Set<Int>

    init(_ points: [RRPoint]) {
        self.points = points
        isValid = points.map { HRVConstants.RRInterval.isValid($0.rr_ms) }
        breaks = TimeDomainAnalyzer.beatsAfterRecordingBreak(in: points, range: points.indices)
    }

    /// Indices of the valid beats, in order.
    private var validIndices: [Int] {
        points.indices.filter { isValid[$0] }
    }

    /// The valid beats' RR intervals, in order.
    var validRRs: [Double] {
        validIndices.map { Double(points[$0].rr_ms) }
    }

    /// Per valid beat, whether it came straight after the previous valid beat:
    /// no invalid beat was dropped between them and no recording break
    /// separates them. The first valid beat has no predecessor and reads false.
    var validFollowsPrevious: [Bool] {
        let indices = validIndices
        return indices.indices.map { k in
            k > 0 && indices[k] == indices[k - 1] + 1 && !breaks.contains(indices[k])
        }
    }

    /// The window cut at every recording break: runs of beats with no break
    /// inside them, in order.
    var stretches: [Range<Int>] {
        var runs: [Range<Int>] = []
        var start = 0
        for i in breaks.sorted() {
            runs.append(start ..< i)
            start = i
        }
        if start < points.count { runs.append(start ..< points.count) }
        return runs
    }

    /// The stretch with the most beats (the earliest on a tie), or nil for an
    /// empty window.
    var longestStretch: Range<Int>? {
        stretches.max { $0.count < $1.count }
    }

    /// The longest stretch's RRs from its first valid beat to its last, each
    /// invalid beat inside replaced by linear interpolation between its valid
    /// neighbours (`LiveDFAAnalyzer.interpolatingArtifacts`), with how many
    /// were replaced. Invalid beats at either end are trimmed rather than
    /// extrapolated. Nil when the stretch has no valid beat.
    func interpolatedStretch() -> LiveDFAAnalyzer.CleanedSeries? {
        guard let stretch = longestStretch,
              let first = stretch.first(where: { isValid[$0] }),
              let last = stretch.last(where: { isValid[$0] }) else { return nil }
        let span = first ... last
        let invalid = span.map { !isValid[$0] }
        return LiveDFAAnalyzer.CleanedSeries(
            values: LiveDFAAnalyzer.interpolatingArtifacts(span.map { Double(points[$0].rr_ms) }, isArtifact: invalid),
            correctedCount: invalid.count { $0 }
        )
    }
}
