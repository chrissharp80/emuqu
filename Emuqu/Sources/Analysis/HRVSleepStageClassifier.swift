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
        /// Whether LF/HF ratio was available for this night's scoring.
        /// Critical for augmentation gating: LF/HF is the only cardiac feature
        /// that reliably separates REM from N2 (Vanoli 1995, Herzig 2017).
        let hasFreqDomain: Bool
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
        var deep = 0, rem = 0, core = 0, awake = 0
        for interval in intervals {
            let minutes = interval.durationMinutes
            switch interval.stage {
            case .deep: deep += minutes
            case .rem: rem += minutes
            case .core: core += minutes
            case .awake: awake += minutes
            case .unspecified: core += minutes
            }
        }
        return ClassificationResult(
            stageIntervals: intervals, deepSleepMinutes: deep, remSleepMinutes: rem,
            coreSleepMinutes: core, awakeMinutes: awake
        )
    }

    // MARK: - Feature Computation

    static func buildFeatureWindows(
        rrPoints: [RRPoint],
        sleepStartMs: Int64,
        sleepEndMs: Int64,
        recordingStart: Date
    ) -> [FeatureWindow] {
        var windows: [FeatureWindow] = []
        var windowStart = sleepStartMs
        // Two-pointer sweep instead of a per-window filter.
        // `rrPoints` is t_ms-monotonic and the window
        // bounds advance monotonically, so membership is identical while
        // cost drops from O(windows x n) to O(n).
        var sweep = RRWindowSweep(rrPoints)
        while windowStart < sleepEndMs {
            let windowEnd = min(windowStart + windowSizeMs, sleepEndMs)
            let points = Array(rrPoints[sweep.range(start: windowStart, end: windowEnd)])
            if let window = featureWindow(points: points, windowStart: windowStart,
                                          windowEnd: windowEnd, recordingStart: recordingStart) {
                windows.append(window)
            }
            windowStart += windowSizeMs
        }
        return windows
    }

    /// One window's features, or nil when the window is too sparse or too
    /// artifact-ridden to describe.
    private static func featureWindow(
        points windowPoints: [RRPoint],
        windowStart: Int64,
        windowEnd: Int64,
        recordingStart: Date
    ) -> FeatureWindow? {
        guard windowPoints.count >= minPointsPerWindow else { return nil }
        let validRRs = windowPoints
            .map { Double($0.rr_ms) }
            .filter { HRVConstants.RRInterval.isValid(Int($0)) }
        guard validRRs.count >= minValidRRsPerWindow else { return nil }
        let avgRR = validRRs.reduce(0, +) / Double(validRRs.count)
        let stats = windowVariability(validRRs, avgRR: avgRR)
        let freq = windowFrequencyMetrics(windowPoints)
        return FeatureWindow(
            startDate: recordingStart.addingTimeInterval(Double(windowStart) / 1_000.0),
            endDate: recordingStart.addingTimeInterval(Double(windowEnd) / 1_000.0),
            midpointMs: windowStart + windowSizeMs / 2,
            hr: 60_000.0 / avgRR,
            rmssd: stats.rmssd, sdnn: stats.sdnn, hrCV: stats.hrCV,
            dfaAlpha1: windowAlpha1(validRRs),
            lfHfRatio: freq?.lfHfRatio, hfPower: freq?.hf
        )
    }

    /// RMSSD, SDNN and the RR-based coefficient of variation.
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
    nonisolated static func windowVariability(_ validRRs: [Double], avgRR: Double) -> (rmssd: Double, sdnn: Double, hrCV: Double) {
        guard validRRs.count > 1 else { return (rmssd: 0, sdnn: 0, hrCV: 0) }

        var diffs = [Double]()
        diffs.reserveCapacity(validRRs.count - 1)
        for i in 1 ..< validRRs.count {
            diffs.append(validRRs[i] - validRRs[i - 1])
        }
        let variance = validRRs.map { pow($0 - avgRR, 2) }.reduce(0, +) / Double(validRRs.count)
        let sdnn = sqrt(variance)
        return (Statistics.rootMeanSquare(diffs), sdnn, avgRR > 0 ? sdnn / avgRR : 0)
    }

    /// DFA α1 needs at least `minBeatsForDFA` beats to mean anything.
    private static func windowAlpha1(_ validRRs: [Double]) -> Double? {
        guard validRRs.count >= minBeatsForDFA else { return nil }
        return DFAAnalyzer.compute(validRRs)?.alpha1
    }

    /// LF/HF and HF power through the shared PSD pipeline, from cubic-spline
    /// resampled (time, rr) pairs.
    private static func windowFrequencyMetrics(_ windowPoints: [RRPoint]) -> FrequencyDomainMetrics? {
        let validPoints = windowPoints.filter { HRVConstants.RRInterval.isValid($0.rr_ms) }
        return FrequencyDomainAnalyzer.computeFromCleanPairs(
            times: validPoints.map { $0.midpointMs / 1_000.0 },
            rrValues: validPoints.map { Double($0.rr_ms) }
        )
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
        if elapsedMs < minTimeBeforeREMMs { remScore = 0 }
        let awakeScore = computeAwakeScore(ranks: ranks, index: i, hasFreqDomain: hasFreqDomain)
        return WindowScores(
            deepScore: deepScore, remScore: remScore, awakeScore: awakeScore,
            classifiedStage: classifyStage(deepScore: deepScore, remScore: remScore, awakeScore: awakeScore),
            hasFreqDomain: hasFreqDomain
        )
    }

    // MARK: - Score Computation Helpers

    /// Pre-computed per-feature rank arrays for all windows.
    private struct FeatureRanks {
        let hr, rmssd, cv, hf, lfHf, dfa: [Double]
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
            dfa: computeRanks(dfaValues.map { $0 ?? medianDFA })
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

    /// Compute fractional ranks: 0.0 = lowest, 1.0 = highest.
    static func computeRanks(_ values: [Double]) -> [Double] {
        guard values.count > 1 else { return values.map { _ in 0.5 } }
        let n = Double(values.count - 1)
        // Sort positions by their value, then walk the sorted order writing each
        // item's rank back into its ORIGINAL slot — that mapping is the whole
        // point of the function, and it is why the index has to survive the sort.
        //
        // Sorting the indices rather than `values.enumerated()` says the same
        // thing without materialising a pair the comparator ignores. Ties break
        // by original position — `sorted` is not stable, so without the tie rule
        // tied features rank in whatever order introsort happens to leave them.
        let order = values.indices.sorted { values[$0] == values[$1] ? $0 < $1 : values[$0] < values[$1] }
        var ranks = [Double](repeating: 0, count: values.count)
        for (rank, original) in order.enumerated() {
            ranks[original] = Double(rank) / n
        }
        return ranks
    }
}
