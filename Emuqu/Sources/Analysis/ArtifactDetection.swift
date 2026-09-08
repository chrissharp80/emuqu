import Foundation

/// Artifact correction methods
enum ArtifactCorrectionMethod: String, CaseIterable, Identifiable {
    case none = "None"
    case deletion = "Deletion"
    case linearInterpolation = "Linear Interpolation"
    case cubicSpline = "Cubic Spline"
    case median = "Median Replacement"

    var id: String {
        rawValue
    }

    var description: String {
        switch self {
        case .none:
            "Keep artifacts in data (excluded from analysis)"
        case .deletion:
            "Remove artifact intervals entirely"
        case .linearInterpolation:
            "Replace with linearly interpolated values"
        case .cubicSpline:
            "Replace with cubic spline interpolated values"
        case .median:
            "Replace with local median value"
        }
    }
}

/// Artifact detection using rolling median and ratio-based classification
final class ArtifactDetector: Sendable {
    // MARK: - Configuration

    struct Config {
        /// Window size for rolling median (beats)
        var windowSize: Int = HRVConstants.Artifacts.windowSize
        /// Threshold for ectopic detection (ratio from median)
        var ectopicThreshold: Double = 0.20
        /// Threshold for missed beat detection (ratio from median)
        var missedThreshold: Double = 0.50
        /// Threshold for extra beat detection (ratio from median)
        var extraThreshold: Double = 0.30
        /// Minimum RR interval (ms)
        var minRR: Int = HRVConstants.RRInterval.minimum
        /// Maximum RR interval (ms)
        var maxRR: Int = HRVConstants.RRInterval.maximum

        static let `default` = Config()
    }

    private let config: Config

    init(config: Config = .default) {
        self.config = config
    }

    // MARK: - Public API

    /// Detect artifacts in an RR series
    /// - Parameter series: The RR series to analyze
    /// - Returns: Array of artifact flags for each point
    func detectArtifacts(in series: RRSeries) -> [ArtifactFlags] {
        let points = series.points
        guard !points.isEmpty else { return [] }
        let medians = computeRollingMedian(points.map { Double($0.rr_ms) }, windowSize: config.windowSize)
        var flags = [ArtifactFlags]()
        flags.reserveCapacity(points.count)
        for i in 0 ..< points.count {
            flags.append(classify(rrMs: points[i].rr_ms, median: medians[i]))
        }
        return flags
    }

    /// One beat, against the rolling median of its neighbourhood.
    private func classify(rrMs: Int, median: Double) -> ArtifactFlags {
        // Technical artifacts: out of physiological range.
        guard rrMs >= config.minRR, rrMs <= config.maxRR else {
            return ArtifactFlags(isArtifact: true, type: .technical, confidence: 1.0)
        }
        let rr = Double(rrMs)
        let ratio = abs(rr - median) / median
        if rr < median * (1 - config.extraThreshold) {
            return shortBeatFlags(rr: rr, median: median, ratio: ratio)
        }
        if rr > median * (1 + config.ectopicThreshold) {
            return longBeatFlags(rr: rr, median: median, ratio: ratio)
        }
        if ratio > config.ectopicThreshold {
            // General deviation beyond ectopic threshold.
            return ArtifactFlags(
                isArtifact: true, type: .ectopic,
                confidence: min(1.0, ratio / config.ectopicThreshold)
            )
        }
        return .clean
    }

    /// Shorter than expected: a very short beat is an extra detection, a
    /// moderately short one may be ectopic.
    private func shortBeatFlags(rr: Double, median: Double, ratio: Double) -> ArtifactFlags {
        let confidence = min(1.0, ratio / config.extraThreshold)
        guard rr >= median * 0.5 else {
            return ArtifactFlags(isArtifact: true, type: .extra, confidence: confidence)
        }
        return ArtifactFlags(
            isArtifact: ratio > config.ectopicThreshold, type: .ectopic, confidence: confidence
        )
    }

    /// Longer than expected: a missed beat above the missed threshold,
    /// otherwise an ectopic.
    ///
    /// Symmetric long-beat ectopic gate. The short
    /// side flags an ectopic at deviation > 0.20 (config.ectopicThreshold); if
    /// the long side only typed a beat as `.missed` above 0.50
    /// (config.missedThreshold), leaving the gap 0.20–0.50 to the generic
    /// `ratio > 0.20` branch. That made the long side's ectopic decision depend
    /// on branch ordering rather than an explicit symmetric rule — a
    /// post-ectopic compensatory pause (classically 20–50% long) is exactly the
    /// case that must be excluded so it can't inflate RMSSD via a large
    /// successive difference.
    private func longBeatFlags(rr: Double, median: Double, ratio: Double) -> ArtifactFlags {
        guard rr <= median * (1 + config.missedThreshold) else {
            return ArtifactFlags(
                isArtifact: true, type: .missed,
                confidence: min(1.0, ratio / config.missedThreshold)
            )
        }
        return ArtifactFlags(
            isArtifact: true, type: .ectopic,
            confidence: min(1.0, ratio / config.ectopicThreshold)
        )
    }

    /// Calculate artifact percentage for a window
    /// - Parameters:
    ///   - flags: Artifact flags array
    ///   - start: Window start index
    ///   - end: Window end index (exclusive)
    /// - Returns: Percentage of artifacts (0-100)
    func artifactPercentage(_ flags: [ArtifactFlags], start: Int, end: Int) -> Double {
        let clampedStart = max(0, start)
        let clampedEnd = min(flags.count, end)
        guard clampedEnd > clampedStart else { return 0 }

        let window = flags[clampedStart ..< clampedEnd]
        let artifactCount = window.filter(\.isArtifact).count
        return Double(artifactCount) / Double(window.count) * 100.0
    }

    // MARK: - Private

    /// Compute rolling median for each position.
    /// Uses an insertion-sorted sliding window: O(n * w) total — each step
    /// removes one element and inserts one via binary search, avoiding a
    /// full re-sort per position.
    private func computeRollingMedian(_ values: [Double], windowSize: Int) -> [Double] {
        guard !values.isEmpty else { return [] }
        let halfWindow = windowSize / 2
        var medians = [Double]()
        medians.reserveCapacity(values.count)
        var sorted = [Double]()
        sorted.reserveCapacity(windowSize + 1)
        // Bootstrap the centred window for position 0.
        for j in 0 ..< min(values.count, halfWindow + 1) {
            sorted.insert(values[j], at: sorted.sortedInsertionIndex(of: values[j]))
        }
        medians.append(medianOf(sorted))
        for i in 1 ..< values.count {
            slideWindow(&sorted, values: values, to: i, halfWindow: halfWindow)
            medians.append(medianOf(sorted))
        }
        return medians
    }

    /// Advances the sorted window one position: the beat entering on the right
    /// is inserted, the one leaving on the left removed.
    private func slideWindow(_ sorted: inout [Double], values: [Double], to i: Int, halfWindow: Int) {
        let newRight = i + halfWindow
        if newRight < values.count {
            sorted.insert(values[newRight], at: sorted.sortedInsertionIndex(of: values[newRight]))
        }
        let oldLeft = i - halfWindow - 1
        if oldLeft >= 0, let removeIdx = sorted.sortedFirstIndex(of: values[oldLeft]) {
            sorted.remove(at: removeIdx)
        }
    }

    /// Median of a sorted array.
    private func medianOf(_ sorted: [Double]) -> Double {
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2.0
        }
        return sorted[mid]
    }
}

// MARK: - Sorted-array binary search

/// Binary searches over an ascending `[Double]`, used by the sliding-window
/// median filters here and in `WindowSelector` to keep their window sorted
/// without re-sorting per step.
extension Array where Element == Double {
    /// Index at which `value` inserts while keeping the array sorted.
    func sortedInsertionIndex(of value: Double) -> Int {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if self[mid] < value { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// First index holding exactly `value`, or nil when absent.
    func sortedFirstIndex(of value: Double) -> Int? {
        let lo = sortedInsertionIndex(of: value)
        guard lo < count, self[lo] == value else { return nil }
        return lo
    }
}

// MARK: - Artifact Correction

/// Artifact correction algorithms
enum ArtifactCorrector {
    /// Apply artifact correction to RR intervals
    /// - Parameters:
    ///   - rrValues: Original RR intervals in ms
    ///   - flags: Artifact flags for each interval
    ///   - method: Correction method to apply
    /// - Returns: Corrected RR intervals and updated flags
    static func correct(
        rrValues: [Int],
        flags: [ArtifactFlags],
        method: ArtifactCorrectionMethod
    ) -> (corrected: [Int], flags: [ArtifactFlags]) {
        guard rrValues.count == flags.count else {
            return (rrValues, flags)
        }

        switch method {
        case .none:
            return (rrValues, flags)

        case .deletion:
            return deletionCorrection(rrValues: rrValues, flags: flags)

        case .linearInterpolation:
            return linearInterpolationCorrection(rrValues: rrValues, flags: flags)

        case .cubicSpline:
            return cubicSplineCorrection(rrValues: rrValues, flags: flags)

        case .median:
            return medianCorrection(rrValues: rrValues, flags: flags)
        }
    }

    // MARK: - Deletion Method

    /// Remove artifacts entirely from the series
    private static func deletionCorrection(
        rrValues: [Int],
        flags: [ArtifactFlags]
    ) -> (corrected: [Int], flags: [ArtifactFlags]) {
        var corrected = [Int]()
        var newFlags = [ArtifactFlags]()

        for i in 0 ..< rrValues.count where !flags[i].isArtifact {
            corrected.append(rrValues[i])
            newFlags.append(.clean)
        }

        return (corrected, newFlags)
    }

    // MARK: - Linear Interpolation

    /// Replace artifacts with linearly interpolated values
    private static func linearInterpolationCorrection(
        rrValues: [Int],
        flags: [ArtifactFlags]
    ) -> (corrected: [Int], flags: [ArtifactFlags]) {
        var corrected = rrValues
        var newFlags = flags
        var i = 0
        while i < corrected.count {
            guard flags[i].isArtifact else {
                i += 1
                continue
            }
            var endIdx = i
            while endIdx < corrected.count, flags[endIdx].isArtifact {
                endIdx += 1
            }
            fillArtifactRun(
                i ..< endIdx, corrected: &corrected, newFlags: &newFlags, flags: flags
            )
            i = endIdx
        }
        return (corrected, newFlags)
    }

    /// Bridges one run of artifacts between the clean beats either side of it.
    /// A run at the very start or end of the recording has only one anchor, so
    /// it is held flat at that value rather than extrapolated.
    private static func fillArtifactRun(
        _ run: Range<Int>,
        corrected: inout [Int],
        newFlags: inout [ArtifactFlags],
        flags: [ArtifactFlags]
    ) {
        let beforeIdx = (0 ..< run.lowerBound).reversed().first { !flags[$0].isArtifact }
        let afterIdx = (run.upperBound ..< corrected.count).first { !flags[$0].isArtifact }
        for j in run {
            guard let value = bridgedValue(
                at: j, before: beforeIdx, after: afterIdx, corrected: corrected
            ) else { continue }
            corrected[j] = value
            newFlags[j] = ArtifactFlags(
                isArtifact: false,
                type: flags[j].type,
                confidence: flags[j].confidence,
                corrected: true
            )
        }
    }

    /// The interpolated (or held) value for one artifact beat. Nil when the run
    /// has no clean beat on either side, in which case it stays flagged.
    private static func bridgedValue(
        at j: Int,
        before beforeIdx: Int?,
        after afterIdx: Int?,
        corrected: [Int]
    ) -> Int? {
        switch (beforeIdx, afterIdx) {
        case let (before?, after?):
            let startVal = Double(corrected[before])
            let endVal = Double(corrected[after])
            let frac = Double(j - before) / Double(after - before)
            return Int(round(startVal + frac * (endVal - startVal)))
        case let (before?, nil): return corrected[before]
        case let (nil, after?): return corrected[after]
        case (nil, nil): return nil
        }
    }

    // MARK: - Cubic Spline Interpolation

    /// Replace artifacts with cubic spline interpolated values
    /// Provides smoother correction than linear interpolation
    private static func cubicSplineCorrection(
        rrValues: [Int],
        flags: [ArtifactFlags]
    ) -> (corrected: [Int], flags: [ArtifactFlags]) {
        var cleanIndices = [Int]()
        var cleanValues = [Double]()
        for i in 0 ..< rrValues.count where !flags[i].isArtifact {
            cleanIndices.append(i)
            cleanValues.append(Double(rrValues[i]))
        }
        // A natural cubic spline needs four knots; below that, fall back.
        guard cleanIndices.count >= 4 else {
            return linearInterpolationCorrection(rrValues: rrValues, flags: flags)
        }
        let spline = NaturalCubicSpline(x: cleanIndices.map { Double($0) }, y: cleanValues)
        return splineCorrected(rrValues: rrValues, flags: flags, spline: spline)
    }

    /// A natural cubic spline through the clean beats, solved once and then
    /// evaluated at each artifact position.
    private struct NaturalCubicSpline {
        let x: [Double]
        let y: [Double]
        private let b: [Double]
        private let c: [Double]
        private let d: [Double]

        init(x: [Double], y: [Double]) {
            self.x = x
            self.y = y
            let h = Self.spacing(x)
            let c = Self.secondDerivatives(x: x, y: y, h: h)
            self.c = c
            (self.b, self.d) = Self.firstAndThirdDerivatives(y: y, h: h, c: c)
        }

        /// Knot spacing.
        private static func spacing(_ x: [Double]) -> [Double] {
            // `count: -1` traps before the loop ever runs. The one caller
            // guards on four knots, but the guard belongs next to the code
            // that depends on it.
            guard x.count >= 2 else { return [] }
            var h = [Double](repeating: 0, count: x.count - 1)
            for i in 0 ..< x.count - 1 {
                h[i] = x[i + 1] - x[i]
            }
            return h
        }

        /// Solves the tridiagonal system for the second derivatives (Thomas
        /// algorithm). Natural end conditions leave c[0] and c[n-1] at zero.
        private static func secondDerivatives(x: [Double], y: [Double], h: [Double]) -> [Double] {
            let n = x.count
            // A natural spline needs interior knots to solve for; with fewer
            // than three the system is empty and `1 ..< n - 1` is invalid.
            guard n >= 3 else { return [Double](repeating: 0, count: n) }
            var alpha = [Double](repeating: 0, count: n)
            for i in 1 ..< n - 1 where h[i - 1] > 0 && h[i] > 0 {
                alpha[i] = 3.0 / h[i] * (y[i + 1] - y[i]) - 3.0 / h[i - 1] * (y[i] - y[i - 1])
            }
            let (mu, z) = thomasForwardSweep(x: x, h: h, alpha: alpha)
            var c = [Double](repeating: 0, count: n)
            for j in stride(from: n - 2, through: 0, by: -1) {
                c[j] = z[j] - mu[j] * c[j + 1]
            }
            return c
        }

        /// Thomas forward elimination. A zero pivot means two knots coincide;
        /// that row is skipped, leaving its `mu`/`z` at the natural-end zeros
        /// so the back substitution treats it as a straight segment.
        private static func thomasForwardSweep(
            x: [Double],
            h: [Double],
            alpha: [Double]
        ) -> (mu: [Double], z: [Double]) {
            let n = x.count
            var l = [Double](repeating: 1, count: n)
            var mu = [Double](repeating: 0, count: n)
            var z = [Double](repeating: 0, count: n)
            for i in 1 ..< max(1, n - 1) {
                l[i] = 2.0 * (x[i + 1] - x[i - 1]) - h[i - 1] * mu[i - 1]
                guard l[i] != 0 else { continue }
                mu[i] = h[i] / l[i]
                z[i] = (alpha[i] - h[i - 1] * z[i - 1]) / l[i]
            }
            return (mu, z)
        }

        private static func firstAndThirdDerivatives(
            y: [Double],
            h: [Double],
            c: [Double]
        ) -> ([Double], [Double]) {
            let n = y.count
            // As in `spacing`: `count: -1` traps before the loop.
            guard n >= 2 else { return ([], []) }
            var b = [Double](repeating: 0, count: n - 1)
            var d = [Double](repeating: 0, count: n - 1)
            for i in 0 ..< n - 1 where h[i] > 0 {
                b[i] = (y[i + 1] - y[i]) / h[i] - h[i] * (c[i + 1] + 2.0 * c[i]) / 3.0
                d[i] = (c[i + 1] - c[i]) / (3.0 * h[i])
            }
            return (b, d)
        }

        /// The segment containing `xi`, clamped to the spline's own range.
        private func segmentIndex(for xi: Double) -> Int {
            // The `max(0, x.count - 2)` fallback below already anticipates a
            // short knot list; the loop bound has to as well.
            for j in 0 ..< max(0, x.count - 1) {
                if x[j] <= xi, xi <= x[j + 1] { return j }
                if x[j] > xi { return max(0, j - 1) }
            }
            return max(0, x.count - 2)
        }

        func value(at xi: Double) -> Double {
            let segIdx = segmentIndex(for: xi)
            let dt = xi - x[segIdx]
            return y[segIdx] + b[segIdx] * dt + c[segIdx] * dt * dt + d[segIdx] * dt * dt * dt
        }
    }

    /// Evaluates the spline at each artifact index, clamped to a physiological
    /// RR range so an overshooting segment can't invent an impossible beat.
    private static func splineCorrected(
        rrValues: [Int],
        flags: [ArtifactFlags],
        spline: NaturalCubicSpline
    ) -> (corrected: [Int], flags: [ArtifactFlags]) {
        var corrected = rrValues
        var newFlags = flags
        for i in 0 ..< rrValues.count where flags[i].isArtifact {
            corrected[i] = Int(round(max(300, min(2_000, spline.value(at: Double(i))))))
            newFlags[i] = ArtifactFlags(
                isArtifact: false,
                type: flags[i].type,
                confidence: flags[i].confidence,
                corrected: true
            )
        }
        return (corrected, newFlags)
    }

    // MARK: - Median Replacement

    /// Replace artifacts with local median value
    /// Simple and robust method, good for isolated artifacts
    private static func medianCorrection(
        rrValues: [Int],
        flags: [ArtifactFlags],
        windowSize: Int = 11
    ) -> (corrected: [Int], flags: [ArtifactFlags]) {
        var corrected = rrValues
        var newFlags = flags
        for i in 0 ..< rrValues.count where flags[i].isArtifact {
            // A window with no clean beat at all leaves the artifact flagged.
            guard let median = localCleanMedian(
                at: i, rrValues: rrValues, flags: flags, halfWindow: windowSize / 2
            ) else { continue }
            corrected[i] = median
            newFlags[i] = ArtifactFlags(
                isArtifact: false,
                type: flags[i].type,
                confidence: flags[i].confidence,
                corrected: true
            )
        }
        return (corrected, newFlags)
    }

    /// Median of the clean beats within `halfWindow` either side of `i`.
    private static func localCleanMedian(
        at i: Int,
        rrValues: [Int],
        flags: [ArtifactFlags],
        halfWindow: Int
    ) -> Int? {
        let start = max(0, i - halfWindow)
        let end = min(rrValues.count, i + halfWindow + 1)
        var windowClean = [Int]()
        for j in start ..< end where !flags[j].isArtifact {
            windowClean.append(rrValues[j])
        }
        guard !windowClean.isEmpty else { return nil }
        windowClean.sort()
        let mid = windowClean.count / 2
        return windowClean.count.isMultiple(of: 2)
            ? (windowClean[mid - 1] + windowClean[mid]) / 2
            : windowClean[mid]
    }
}
