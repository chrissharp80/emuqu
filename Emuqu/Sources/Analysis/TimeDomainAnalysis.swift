import Accelerate
import Foundation

/// The non-artifact beats of an analysis window, each with its index in the
/// series, and the series indices whose beat follows a recording break
/// (`TimeDomainAnalyzer.beatsAfterRecordingBreak`).
///
/// Collapsing a window to its valid beats loses which of them were
/// neighbours. This keeps it, so every metric built on beat-to-beat
/// structure reads the same adjacency: time-domain RMSSD/pNN50/SDSD and
/// Poincaré SD1 difference only neighbouring beats, entropy templates stay
/// inside a run of neighbours, and DFA interpolates removed beats and splits
/// at breaks (`DFAAnalyzer.interpolatedSegments`).
struct CleanBeatWindow {
    let rr: [Double]
    let indices: [Int]
    let breaks: Set<Int>

    /// Whether beat `k` and beat `k - 1` were neighbours in the series with
    /// no recording break between them. False for the first beat.
    func isAdjacentToPrevious(_ k: Int) -> Bool {
        k > 0 && indices[k] == indices[k - 1] + 1 && !breaks.contains(indices[k])
    }
}

/// Time-domain HRV analysis
enum TimeDomainAnalyzer {
    // RMSSD=√(mean successive ΔRR²); pNN50; SDNN(N−1); triangular index 1/128s
    // bins — Task Force ESC/NASPE, Circulation 1996;93:1043-1065
    /// Compute RMSSD (ms) from a sequence of clean RR intervals: the pure
    /// Task Force formula over the array as given, with no ectopic gate and
    /// no adjacency check. It is the reference the RMSSD estimators are
    /// validated against (the RMSSD and HRV-reference tests, and
    /// `docs/hrv-reference-data.md`); the app's own RMSSD comes from
    /// `computeTimeDomain`, which differences only beats adjacent in the
    /// original series.
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
        // Missing is the honest answer for an unrepresentable one.
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
    /// A pair is also skipped when `followsBreak(i)` says a recording break
    /// separates beat `i` from beat `i - 1` (see `isRecordingBreak`): beats on
    /// either side of a break are not adjacent, so no successive difference
    /// is taken across it (Task Force 1996). `rmssd(points:range:isValid:)`
    /// supplies the breaks from the beats' timestamps.
    ///
    /// Shared by the overnight RMSSD chart, the live stats card and the
    /// peak scan, so the estimator exists as one transcription rather than
    /// several with nothing keeping them in step.
    ///
    /// Returns `nil` when no adjacent valid pair exists.
    static func rmssd(
        fromRRs rr: [Double], isValid: (Int) -> Bool, followsBreak: (Int) -> Bool = { _ in false }
    ) -> Double? {
        guard rr.count >= 2 else { return nil }
        var sumSquared: Double = 0
        var pairCount = 0
        for i in 1 ..< rr.count where isValid(i) && isValid(i - 1) && !followsBreak(i) {
            let diff = rr[i] - rr[i - 1]
            sumSquared += diff * diff
            pairCount += 1
        }
        guard pairCount >= 1 else { return nil }
        return finiteOrNil((sumSquared / Double(pairCount)).squareRoot())
    }

    /// The masked estimator over `points[range]`, skipping every pair split
    /// by a recording break. `isValid` takes an offset into the range.
    static func rmssd(points: [RRPoint], range: Range<Int>, isValid: (Int) -> Bool) -> Double? {
        guard range.lowerBound >= 0, range.upperBound <= points.count else { return nil }
        let breaks = beatsAfterRecordingBreak(in: points, range: range)
        return rmssd(
            fromRRs: points[range].map { Double($0.rr_ms) },
            isValid: isValid,
            followsBreak: { breaks.contains(range.lowerBound + $0) }
        )
    }

    /// Peak-scan RMSSD for one window of a recording: the masked estimator
    /// above, over beats that are neither flagged artifact nor outside the
    /// physiological RR range, with no difference taken across a recording
    /// break, at least 30 such beats and a result in (0, 300) ms. Shared by
    /// the overnight chart's peak and the PDF report's peak so the two cannot
    /// disagree about the same window. Display only; window selection for
    /// the score does not use it.
    static func peakScanRMSSD(points: [RRPoint], flags: [ArtifactFlags], range: Range<Int>) -> Double? {
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= points.count else { return nil }
        let isValid: (Int) -> Bool = { offset in
            let j = range.lowerBound + offset
            let isArtifact = j < flags.count ? flags[j].isArtifact : false
            return !isArtifact && HRVConstants.RRInterval.isValid(points[j].rr_ms)
        }
        let cleanBeats = (0 ..< range.count).count { isValid($0) }
        guard cleanBeats >= 30,
              let rmssd = rmssd(points: points, range: range, isValid: isValid),
              rmssd > 0, rmssd < 300
        else { return nil }
        return rmssd
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
    /// This is now the one ectopic gate: the window selector calls
    /// `ectopicKeepMask` itself (`WindowSelector`'s window evaluation), so
    /// the selector and the report cannot drift apart. The threshold is
    /// `HRVThresholds.ectopicThresholdPercent` (0.20) from a
    /// `localMedianWindow`-beat (10) local median.
    private static let localMedianWindow = 10
    static func filterEctopicBeats(_ rr: [Double]) -> [Double] {
        zip(rr, ectopicKeepMask(rr)).filter { $0.1 }.map { $0.0 }
    }

    /// Per beat, whether the ectopic gate keeps it. Every beat is kept when
    /// there are too few to form a local median.
    static func ectopicKeepMask(_ rr: [Double]) -> [Bool] {
        guard rr.count > localMedianWindow else { return Array(repeating: true, count: rr.count) }
        let half = localMedianWindow / 2
        return rr.indices.map { isWithinLocalMedian(rr, index: $0, half: half) }
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

    /// Slack beyond one RR interval before a pause counts as a recording
    /// break: the significant-gap rule `DataSourceSelector` uses, wide enough
    /// to absorb the ~1 s batching of streamed beats' arrival times.
    private static let recordingBreakToleranceMs: Int64 = 2000

    /// Whether a recording break separates `next` from `previous`, so they are
    /// not adjacent beats and no successive difference may be taken across
    /// them (Task Force 1996: differences between ADJACENT NN intervals). A
    /// break is a pause more than 2 s longer than one RR interval, on the
    /// session timeline (two merged recordings, beats stitched in from the
    /// stream) or, for streamed beats, on the arrival clock, which keeps
    /// running through a Bluetooth dropout while the beat timeline does not.
    static func isRecordingBreak(between previous: RRPoint, and next: RRPoint) -> Bool {
        let tolerance = Int64(previous.rr_ms) + recordingBreakToleranceMs
        if next.t_ms - previous.endMs > tolerance { return true }
        guard let previousWall = previous.wallClockMs, let nextWall = next.wallClockMs else { return false }
        return nextWall - previousWall > Int64(next.rr_ms) + tolerance
    }

    /// Indices in `range` whose beat follows a recording break from the beat
    /// before it (see `isRecordingBreak`).
    static func beatsAfterRecordingBreak(in points: [RRPoint], range: Range<Int>) -> Set<Int> {
        var breaks = Set<Int>()
        for i in range where i > 0 && i < points.count && isRecordingBreak(between: points[i - 1], and: points[i]) {
            breaks.insert(i)
        }
        return breaks
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
        guard let window = cleanWindow(series, flags: flags, windowStart: windowStart, windowEnd: windowEnd),
              window.rr.count >= 10,
              let diffs = successiveDifferences(in: window)
        else { return nil }
        return metrics(
            cleanRR: window.rr, diffs: diffs,
            hrStats: computeHRStatistics(series: series, flags: flags, windowStart: windowStart, windowEnd: windowEnd, cleanRR: window.rr)
        )
    }

    /// The window's non-artifact beats with their series indices and the
    /// recording breaks in it; nil when the bounds cannot address both
    /// `series.points` and `flags`. Shared with `NonlinearAnalyzer`, so the
    /// two read the same beats with the same adjacency.
    static func cleanWindow(
        _ series: RRSeries, flags: [ArtifactFlags], windowStart: Int, windowEnd: Int
    ) -> CleanBeatWindow? {
        // Window bounds must be valid against BOTH points and flags (separate
        // parameters). Valid callers always satisfy this; a stale window index
        // applied to a shorter/re-loaded series would otherwise trap on the
        // subscript. nil = the existing insufficient-data contract.
        guard windowStart >= 0, windowStart <= windowEnd,
              windowEnd <= series.points.count, windowEnd <= flags.count else { return nil }
        var rr = [Double]()
        var indices = [Int]()
        for i in windowStart ..< windowEnd where !flags[i].isArtifact {
            rr.append(Double(series.points[i].rr_ms))
            indices.append(i)
        }
        let breaks = beatsAfterRecordingBreak(in: series.points, range: windowStart ..< windowEnd)
        return CleanBeatWindow(rr: rr, indices: indices, breaks: breaks)
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

    /// Successive differences for RMSSD / pNN50 / SDSD and Poincaré SD1,
    /// taken only between beats that are ADJACENT in the original series,
    /// both kept, and not separated by a recording break
    /// (`CleanBeatWindow.isAdjacentToPrevious`, see `isRecordingBreak`).
    /// `NonlinearAnalyzer` takes SD1 from these same pairs, so
    /// SD1² = ½·Var(these differences) stays tied to SDSD.
    ///
    /// The Task Force definition is the difference between adjacent NN
    /// intervals. Dropping a flagged or ectopic beat and differencing the
    /// collapsed array would make two non-adjacent beats neighbours and add one
    /// spurious large difference per removed beat, inflating RMSSD on exactly
    /// the nights that were already noisy (see `rmssd(fromRRs:isValid:)`).
    ///
    /// Applies the SAME ectopic gate the window selector uses, so the REPORTED
    /// RMSSD/pNN50/SDSD agree with the RMSSD selection chose the window on
    /// (`WindowSelector.maskedRMSSD`). The gate keeps every beat when there
    /// are too few to judge. If the gate leaves no adjacent pair, adjacent
    /// artifact-clean pairs are used without it.
    static func successiveDifferences(in window: CleanBeatWindow) -> [Double]? {
        let kept = ectopicKeepMask(window.rr)
        let gated = adjacentDifferences(in: window) { kept[$0] }
        if !gated.isEmpty { return gated }
        let ungated = adjacentDifferences(in: window) { _ in true }
        return ungated.isEmpty ? nil : ungated
    }

    /// `rr[k] - rr[k - 1]` for every k whose beat and predecessor are both
    /// kept, were neighbours in the original series, and have no recording
    /// break between them.
    private static func adjacentDifferences(in window: CleanBeatWindow, isKept: (Int) -> Bool) -> [Double] {
        let rr = window.rr
        guard rr.count > 1 else { return [] }
        var diffs = [Double]()
        diffs.reserveCapacity(rr.count - 1)
        for k in 1 ..< rr.count where isKept(k) && isKept(k - 1) && window.isAdjacentToPrevious(k) {
            diffs.append(rr[k] - rr[k - 1])
        }
        return diffs
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
    /// `cleanRR` is the window's non-artifact RR, never empty: the only
    /// caller, `computeTimeDomain`, returns before this for fewer than 10.
    private static func computeHRStatistics(
        series: RRSeries,
        flags: [ArtifactFlags],
        windowStart: Int,
        windowEnd: Int,
        cleanRR: [Double]
    ) -> HRWindowStatistics {
        if let stored = storedHRStatistics(series: series, flags: flags, windowStart: windowStart, windowEnd: windowEnd) {
            return stored
        }
        let hrSamples = rollingWindowHRSamples(series: series, flags: flags, windowStart: windowStart, windowEnd: windowEnd)
        guard !hrSamples.isEmpty else { return meanRRFallback(cleanRR: cleanRR) }
        return statistics(of: hrSamples)
    }

    /// HR as reported by the Polar sensor during streaming.
    ///
    /// Only when EVERY non-artifact beat in the window carries sensor HR. In
    /// a `DataSourceSelector`-merged night the internal-recording beats carry
    /// none and only the streamed gap-fill beats do, so averaging whatever
    /// beats have it would report the HR of a few gap-fill beats as the whole
    /// window's — and this mean HR feeds the recovery score's resting-HR
    /// z-score. Nil then, and nil when the window has no clean beat; the
    /// caller falls through to the RR-based rolling window, which derives HR
    /// from all the window's clean beats. Never a fabricated 60 bpm sentinel.
    private static func storedHRStatistics(
        series: RRSeries,
        flags: [ArtifactFlags],
        windowStart: Int,
        windowEnd: Int
    ) -> HRWindowStatistics? {
        var hrValues: [Double] = []
        var cleanBeats = 0
        for i in windowStart ..< windowEnd where !flags[i].isArtifact {
            cleanBeats += 1
            if let hr = series.points[i].hr { hrValues.append(Double(hr)) }
        }
        guard !hrValues.isEmpty, hrValues.count == cleanBeats else { return nil }
        return statistics(of: hrValues)
    }

    /// Rolling ~10-second windows, each started 5 beats after the last, for
    /// the irregular rhythms of sleep HRV. The step is in beats, not seconds,
    /// so the overlap is about 50% only near 60 bpm (about 58% at 50 bpm and
    /// 33% at 90 bpm).
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

    /// Last resort: a flat HR estimated from the window's mean clean RR
    /// (non-empty, see `computeHRStatistics`).
    private static func meanRRFallback(cleanRR: [Double]) -> HRWindowStatistics {
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
