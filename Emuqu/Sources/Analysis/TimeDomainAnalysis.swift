import Accelerate
import Foundation

/// Time-domain HRV analysis
enum TimeDomainAnalyzer {
    // RMSSD=√(mean successive ΔRR²); pNN50; SDNN(N−1); triangular index 1/128s
    // bins — Task Force ESC/NASPE, Circulation 1996;93:1043-1065
    /// Compute RMSSD (ms) from a sequence of clean RR intervals. Shared
    /// helper used by the canonical `computeTimeDomain(_:flags:windowStart:windowEnd:)`
    /// path AND by the live-chart / PDF-sections call sites that used to
    /// inline the same arithmetic. One implementation prevents numeric
    /// drift between parallel copies.
    ///
    /// Returns `nil` when there aren't enough samples to form a single
    /// successive difference.
    static func rmssd(fromCleanRRs rr: [Double]) -> Double? {
        guard rr.count >= 2 else { return nil }
        var sumSquared: Double = 0
        for i in 1 ..< rr.count {
            let diff = rr[i] - rr[i - 1]
            sumSquared += diff * diff
        }
        // Return nil rather than a non-finite Double. A NaN
        // input would produce `Optional(nan)` and a pair of +/-1e308
        // `Optional(inf)`; both would then travel as a *present* measurement.
        // `FiniteHRVInputs` catches them at the scoring boundary, but this is
        // the source and every other caller (Apple Health export, the live
        // chart, the PDF sections) reads it directly. Missing is the honest
        // answer for an unrepresentable one.
        return finiteOrNil((sumSquared / Double(rr.count - 1)).squareRoot())
    }

    /// `nil` unless the value is a real number. See `rmssd(fromCleanRRs:)`.
    private static func finiteOrNil(_ value: Double) -> Double? {
        value.isFinite ? value : nil
    }

    /// RMSSD over a run of RR intervals where some beats are invalid, counting
    /// ONLY differences between beats that are adjacent in the ORIGINAL series
    /// and both valid.
    ///
    /// This is a genuinely different estimator from `rmssd(fromCleanRRs:)`, not a
    /// second copy of it, and the difference is the point. Collapsing an array to
    /// its valid beats and then differencing makes two non-adjacent beats
    /// adjacent, and the gap between them injects one large spurious successive
    /// difference per removed artifact — which inflates RMSSD on exactly the
    /// nights that were already noisy. Skipping the pair instead is more
    /// artifact-robust, and on a heavy-artifact night reads slightly LOWER than
    /// the clean-array value. That gap is expected; see
    /// `RMSSDEstimatorTests.testMaskedEstimatorIsLowerAcrossAnArtifactGap`.
    ///
    /// Shared by `HealthKitManager+HRV` (the value written to Apple
    /// Health, which Athlytic and Training Today read) and the live RMSSD chart,
    /// so the estimator exists as one transcription rather than two with
    /// nothing keeping them in step.
    ///
    /// Returns `nil` when no adjacent valid pair exists.
    static func rmssd(fromRRs rr: [Double], isValid: (Int) -> Bool) -> Double? {
        guard rr.count >= 2 else { return nil }
        var sumSquared: Double = 0
        var pairCount = 0
        for i in 1 ..< rr.count where isValid(i) && isValid(i - 1) {
            let diff = rr[i] - rr[i - 1]
            sumSquared += diff * diff
            pairCount += 1
        }
        guard pairCount >= 1 else { return nil }
        return finiteOrNil((sumSquared / Double(pairCount)).squareRoot())
    }

    // MARK: - Ectopic Cleaning

    /// Ectopic-beat cleaning for the REPORTED time-domain
    /// metrics. The recovery window is *selected* on an
    /// ectopic-filtered RMSSD: `WindowSelector.evaluateWindow` runs
    /// `filterEctopicBeats` (a local-median 20% gate, Kubios/PMC3268104)
    /// over the artifact-clean RR before scoring the candidate. But the
    /// value that is then SCORED, BASELINED, and EXPORTED came from
    /// `computeTimeDomain`, which only dropped *flagged* artifact beats —
    /// it never ran the ectopic gate. A single ectopic beat that survived
    /// artifact flagging (e.g. a compensatory long pause just inside the
    /// missed-beat threshold) produces a large successive difference and
    /// can add tens of ms of RMSSD, so the selector and the report
    /// disagreed about the same window. This applies the SAME local-median
    /// 20% gate the selector uses so the two paths agree.
    ///
    /// Mirrors `WindowSelector.filterEctopicBeats` /
    /// `HRVThresholds.ectopicThresholdPercent` (0.20) and
    /// `WindowSelection.Config.localMedianWindow` (10). Kept as a local
    /// O(n·w) implementation rather than reaching into `WindowSelector`
    /// (which is an instance type carrying its own `config`) so the
    /// time-domain path stays a free function with no selector dependency.
    /// `localMedianWindow` matches `WindowSelection.Config.localMedianWindow`
    /// (10) so this gate behaves identically to the selector's.
    private static let localMedianWindow = 10
    static func filterEctopicBeats(_ rr: [Double]) -> [Double] {
        let windowSize = localMedianWindow
        guard rr.count > windowSize else { return rr }
        let half = windowSize / 2
        var clean = [Double]()
        clean.reserveCapacity(rr.count)
        for i in 0 ..< rr.count where isWithinLocalMedian(rr, index: i, half: half) {
            clean.append(rr[i])
        }
        return clean
    }

    /// Whether beat `i` sits within the ectopic threshold of its neighbours'
    /// median. The median EXCLUDES the beat itself, so a single wild value
    /// can't drag the reference toward itself and survive.
    private static func isWithinLocalMedian(_ rr: [Double], index i: Int, half: Int) -> Bool {
        let lo = Swift.max(0, i - half)
        let hi = Swift.min(rr.count, i + half + 1)
        var neighbours = [Double]()
        neighbours.reserveCapacity(hi - lo)
        for j in lo ..< hi where j != i {
            neighbours.append(rr[j])
        }
        guard !neighbours.isEmpty else { return true }
        neighbours.sort()
        let mid = neighbours.count / 2
        let median = neighbours.count.isMultiple(of: 2)
            ? (neighbours[mid - 1] + neighbours[mid]) / 2.0
            : neighbours[mid]
        guard median > 0 else { return true }
        return abs(rr[i] - median) / median <= HRVThresholds.ectopicThresholdPercent
    }

    // MARK: - Public API

    /// Compute time-domain metrics for clean RR intervals
    /// - Parameters:
    ///   - series: The RR series
    ///   - flags: Artifact flags
    ///   - windowStart: Start index
    ///   - windowEnd: End index (exclusive)
    /// - Returns: Time domain metrics, or nil if insufficient data
    static func computeTimeDomain(
        _ series: RRSeries,
        flags: [ArtifactFlags],
        windowStart: Int,
        windowEnd: Int
    ) -> TimeDomainMetrics? {
        // Window bounds must be valid against BOTH points and flags (separate
        // parameters). Valid callers always satisfy this; a stale window index
        // applied to a shorter/re-loaded series would otherwise trap on the
        // subscript. nil = the existing insufficient-data contract.
        guard windowStart >= 0, windowStart <= windowEnd,
              windowEnd <= series.points.count, windowEnd <= flags.count else { return nil }
        var cleanRR = [Double]()
        for i in windowStart ..< windowEnd where !flags[i].isArtifact {
            cleanRR.append(Double(series.points[i].rr_ms))
        }
        guard cleanRR.count >= 10, let diffs = successiveDifferences(of: cleanRR) else { return nil }
        return metrics(
            cleanRR: cleanRR, diffs: diffs,
            hrStats: computeHRStatistics(series: series, flags: flags, windowStart: windowStart, windowEnd: windowEnd)
        )
    }

    private static func metrics(
        cleanRR: [Double],
        diffs: [Double],
        hrStats: HRWindowStatistics
    ) -> TimeDomainMetrics {
        var meanRR: Double = 0
        vDSP_meanvD(cleanRR, 1, &meanRR, vDSP_Length(cleanRR.count))
        return TimeDomainMetrics(
            meanRR: meanRR,
            sdnn: standardDeviation(cleanRR, mean: meanRR),
            rmssd: rootMeanSquare(diffs),
            pnn50: Double(diffs.filter { abs($0) > 50 }.count) / Double(diffs.count) * 100,
            sdsd: standardDeviationOfDifferences(diffs),
            meanHR: hrStats.mean, sdHR: hrStats.sd, minHR: hrStats.min, maxHR: hrStats.max,
            // HRV Triangular Index: N / max(histogram bin count), 1/128 s bins.
            triangularIndex: computeTriangularIndex(cleanRR)
        )
    }

    /// Successive differences for RMSSD / pNN50 / SDSD.
    ///
    /// Applies the SAME ectopic gate the window selector uses
    /// so the REPORTED RMSSD/pNN50/SDSD agree with the
    /// ectopic-filtered RMSSD the selector scored this window on. Without it, a
    /// surviving ectopic beat inflates the successive-difference family by tens
    /// of ms relative to the value selection chose. The ectopic gate falls back
    /// to the input unchanged when there are too few beats, so this never drops
    /// below the caller's >=10 guard.
    private static func successiveDifferences(of cleanRR: [Double]) -> [Double]? {
        let ectopicCleanRR = filterEctopicBeats(cleanRR)
        let diffSourceRR = ectopicCleanRR.count >= 2 ? ectopicCleanRR : cleanRR
        guard diffSourceRR.count > 1 else { return nil }

        var successiveDiffs = [Double]()
        successiveDiffs.reserveCapacity(diffSourceRR.count - 1)
        for i in 1 ..< diffSourceRR.count {
            successiveDiffs.append(diffSourceRR[i] - diffSourceRR[i - 1])
        }
        return successiveDiffs.isEmpty ? nil : successiveDiffs
    }

    private static func standardDeviationOfDifferences(_ successiveDiffs: [Double]) -> Double {
        var meanDiff: Double = 0
        vDSP_meanvD(successiveDiffs, 1, &meanDiff, vDSP_Length(successiveDiffs.count))
        return standardDeviation(successiveDiffs, mean: meanDiff)
    }

    /// Compute HRV Triangular Index
    /// Uses histogram with 7.8125 ms bin width (1/128 s)
    private static func computeTriangularIndex(_ rr: [Double]) -> Double? {
        guard rr.count >= HRVConstants.MinimumBeats.forTriangularIndex else { return nil }
        let binWidth = WindowConstants.triangularIndexBinWidth
        let minRR = rr.min() ?? 0
        let maxRR = rr.max() ?? 0
        guard maxRR > minRR else { return nil }
        let binCount = Int(ceil((maxRR - minRR) / binWidth)) + 1
        var histogram = [Int](repeating: 0, count: binCount)
        for interval in rr {
            let binIndex = Int((interval - minRR) / binWidth)
            if binIndex >= 0, binIndex < binCount { histogram[binIndex] += 1 }
        }
        guard let maxBin = histogram.max(), maxBin > 0 else { return nil }
        return Double(rr.count) / Double(maxBin)
    }

    // MARK: - Private Helpers

    // Sample standard deviation (N-1 denominator). All callers pass `mean`
    // computed via vDSP_meanvD over the same array, which is identical to the
    // mean Statistics computes internally, so the result is unchanged.
    private static func standardDeviation(_ values: [Double], mean _: Double) -> Double {
        Statistics.sampleStandardDeviation(values)
    }

    private static func rootMeanSquare(_ values: [Double]) -> Double {
        Statistics.rootMeanSquare(values)
    }

    /// Compute HR statistics using rolling 10-second windows
    /// This is the correct method - NOT instantaneous HR from single RR intervals
    private static func computeHRStatistics(
        series: RRSeries,
        flags: [ArtifactFlags],
        windowStart: Int,
        windowEnd: Int
    ) -> HRWindowStatistics {
        if let stored = storedHRStatistics(series: series, flags: flags, windowStart: windowStart, windowEnd: windowEnd) {
            return stored
        }
        let hrSamples = rollingWindowHRSamples(series: series, flags: flags, windowStart: windowStart, windowEnd: windowEnd)
        guard !hrSamples.isEmpty else {
            return meanRRFallback(series: series, flags: flags, windowStart: windowStart, windowEnd: windowEnd)
        }
        return statistics(of: hrSamples)
    }

    /// HR as reported by the Polar sensor during streaming.
    ///
    /// Nil when every stored-HR point in the window was artifact-rejected. In
    /// that case we must NOT fabricate a 60 bpm sentinel — it biases the
    /// downstream RHR z-score (RecoveryScoreCalculator's `zHR = (meanHR -
    /// meanHRBaseline) / meanHRSD`). The caller falls through to the RR-based
    /// rolling window instead, which derives a real HR from the same window's
    /// non-artifact beats.
    private static func storedHRStatistics(
        series: RRSeries,
        flags: [ArtifactFlags],
        windowStart: Int,
        windowEnd: Int
    ) -> HRWindowStatistics? {
        let points = series.points
        guard points[windowStart ..< windowEnd].contains(where: { $0.hr != nil }) else { return nil }
        var hrValues: [Double] = []
        for i in windowStart ..< windowEnd {
            if !flags[i].isArtifact, let hr = points[i].hr {
                hrValues.append(Double(hr))
            }
        }
        guard !hrValues.isEmpty else { return nil }
        return statistics(of: hrValues)
    }

    /// Rolling 10-second windows at 50% overlap — standard practice for the
    /// irregular rhythms of sleep HRV.
    private static func rollingWindowHRSamples(
        series: RRSeries,
        flags: [ArtifactFlags],
        windowStart: Int,
        windowEnd: Int
    ) -> [Double] {
        var hrSamples: [Double] = []
        var i = windowStart
        while i < windowEnd {
            let (hr, j) = tenSecondWindowHR(series: series, flags: flags, from: i, to: windowEnd)
            if let hr { hrSamples.append(hr) }
            i = j > i + 5 ? i + 5 : j
        }
        return hrSamples
    }

    /// HR across the next ~10 s of beats from `i`, and the index just past
    /// them. Nil HR when the window had fewer than 5 beats or produced an
    /// implausible rate.
    private static func tenSecondWindowHR(
        series: RRSeries,
        flags: [ArtifactFlags],
        from i: Int,
        to windowEnd: Int
    ) -> (Double?, Int) {
        let windowDurationMs: Int64 = 10_000
        var beatCount = 0
        var windowDurationActual: Int64 = 0
        var j = i
        while j < windowEnd, windowDurationActual < windowDurationMs {
            if !flags[j].isArtifact {
                beatCount += 1
                windowDurationActual += Int64(series.points[j].rr_ms)
            }
            j += 1
        }
        guard beatCount >= 5, windowDurationActual > 0 else { return (nil, j) }
        let windowHR = (Double(beatCount) / Double(windowDurationActual)) * 60_000.0
        return (windowHR >= 30 && windowHR <= 200 ? windowHR : nil, j)
    }

    /// Last resort: a flat HR estimated from the window's mean RR.
    private static func meanRRFallback(
        series: RRSeries,
        flags: [ArtifactFlags],
        windowStart: Int,
        windowEnd: Int
    ) -> HRWindowStatistics {
        var cleanRR = [Double]()
        for i in windowStart ..< windowEnd where !flags[i].isArtifact {
            cleanRR.append(Double(series.points[i].rr_ms))
        }
        guard !cleanRR.isEmpty else {
            return HRWindowStatistics(mean: 60.0, sd: 0, min: 60.0, max: 60.0)
        }
        var meanRR: Double = 0
        vDSP_meanvD(cleanRR, 1, &meanRR, vDSP_Length(cleanRR.count))
        let meanHR = 60_000.0 / meanRR
        return HRWindowStatistics(mean: meanHR, sd: 0, min: meanHR, max: meanHR)
    }

    private static func statistics(of values: [Double]) -> HRWindowStatistics {
        var mean: Double = 0
        vDSP_meanvD(values, 1, &mean, vDSP_Length(values.count))
        return HRWindowStatistics(
            mean: mean,
            sd: standardDeviation(values, mean: mean),
            min: values.min() ?? mean,
            max: values.max() ?? mean
        )
    }
}
