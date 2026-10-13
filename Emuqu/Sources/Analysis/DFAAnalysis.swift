import Accelerate
import Foundation

/// Detrended Fluctuation Analysis (DFA)
/// Computes α1 (short-term) and α2 (long-term) fractal scaling exponents
enum DFAAnalyzer {
    // DFA: integrate→box linear detrend→RMS→log-log slope; α1 boxes 4–16,
    // α2 16–64 — Peng et al., Chaos 1995;5:82-87

    // MARK: - Public API

    struct DFAResult {
        /// Short-term scaling exponent (4-16 beats)
        let alpha1: Double
        /// Long-term scaling exponent (16-64 beats)
        let alpha2: Double?
        /// R² fit quality for α1
        let alpha1R2: Double
        /// R² fit quality for α2
        let alpha2R2: Double?
    }

    /// Compute DFA α1 and α2 from clean RR intervals
    /// - Parameters:
    ///   - rr: Array of RR intervals in ms
    ///   - alpha1Range: Box sizes for α1 (default 4-16)
    ///   - alpha2Range: Box sizes for α2 (default 16-64)
    /// - Returns: DFA result with scaling exponents, or nil if insufficient
    ///   data or a degenerate series (fewer than two box sizes with a non-zero
    ///   fluctuation, e.g. constant intervals), which has no scaling exponent
    static func compute(
        _ rr: [Double],
        alpha1Range: ClosedRange<Int> = HRVConstants.DFA.alpha1ScaleMin ... HRVConstants.DFA.alpha1ScaleMax,
        alpha2Range: ClosedRange<Int> = HRVConstants.DFA.alpha2ScaleMin ... HRVConstants.DFA.alpha2ScaleMax
    ) -> DFAResult? {
        compute(segments: [rr], alpha1Range: alpha1Range, alpha2Range: alpha2Range)
    }

    /// DFA over a window whose removed beats are interpolated and whose
    /// recording breaks split it (`interpolatedSegments`). A window with no
    /// removed beat and no break gives exactly `compute(_:)` on its beats.
    static func compute(window: CleanBeatWindow) -> DFAResult? {
        compute(segments: interpolatedSegments(window))
    }

    /// DFA over contiguous segments of one recording: the profile is the
    /// cumulative sum over all of them, but every box lies inside one
    /// segment, so no box spans the join between two (`computeFluctuation`).
    /// Box sizes run up to a quarter of the longest segment. One segment is
    /// the textbook single-series DFA.
    static func compute(
        segments: [[Double]],
        alpha1Range: ClosedRange<Int> = HRVConstants.DFA.alpha1ScaleMin ... HRVConstants.DFA.alpha1ScaleMax,
        alpha2Range: ClosedRange<Int> = HRVConstants.DFA.alpha2ScaleMin ... HRVConstants.DFA.alpha2ScaleMax
    ) -> DFAResult? {
        let rr = Array(segments.joined())
        guard rr.count >= HRVConstants.DFA.alpha2ScaleMax else { return nil }
        let integrated = integratedSeries(rr)
        let ranges = segmentRanges(segments)
        // Log-spaced box sizes per the PhysioNet reference implementation
        // (Peng et al. 1995), which keeps the log-log fit evenly represented.
        let maxBox = (segments.map(\.count).max() ?? 0) / 4
        let alpha1Sizes = logSpacedBoxSizes(from: alpha1Range.lowerBound, through: min(alpha1Range.upperBound, maxBox))
        let alpha2Sizes = logSpacedBoxSizes(from: alpha2Range.lowerBound, through: min(alpha2Range.upperBound, maxBox))
        guard alpha1Sizes.count >= 3 else { return nil }
        let alpha1Fluctuations = alpha1Sizes.map { computeFluctuation(integrated, boxSize: $0, segments: ranges) }
        guard let alpha1Fit = logLogRegression(sizes: alpha1Sizes, fluctuations: alpha1Fluctuations) else { return nil }
        let alpha2 = alpha2Exponent(integrated: integrated, sizes: alpha2Sizes, segments: ranges)
        return DFAResult(alpha1: alpha1Fit.slope, alpha2: alpha2?.value, alpha1R2: alpha1Fit.r2, alpha2R2: alpha2?.r2)
    }

    /// The window's beats as DFA input: split at every recording break, and
    /// with each run of removed beats inside a segment replaced by linear
    /// interpolation between the kept beats either side of it, one value per
    /// removed beat.
    ///
    /// Removed beats are interpolated, not dropped, because DFA works in
    /// beat index: dropping one makes its neighbours adjacent and shifts every
    /// later beat into another box. Interpolation is the Kubios correction
    /// (Lipponen & Tarvainen, J Med Eng Technol 2019;43:173-181) and the one
    /// `LiveDFAAnalyzer.cleanRRForDFA` already applies to live α1. A break
    /// is not interpolated: it can last minutes, and the beats either side of
    /// it are not neighbours at all, so the series is split there instead.
    /// Removed beats before a segment's first kept beat or after its last
    /// have one neighbour only and are left out.
    static func interpolatedSegments(_ window: CleanBeatWindow) -> [[Double]] {
        var segments: [[Double]] = []
        var current: [Double] = []
        for k in window.rr.indices {
            if k > 0, spansBreak(window, at: k) {
                segments.append(current)
                current = []
            } else if k > 0 {
                let missing = window.indices[k] - window.indices[k - 1] - 1
                current += interpolation(from: window.rr[k - 1], to: window.rr[k], missing: missing)
            }
            current.append(window.rr[k])
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    /// Whether a recording break separates beat `k - 1` from beat `k`: some
    /// series index after the first, up to the second, follows a break.
    private static func spansBreak(_ window: CleanBeatWindow, at k: Int) -> Bool {
        let previous = window.indices[k - 1]
        let next = window.indices[k]
        guard next > previous else { return true }
        return ((previous + 1) ... next).contains { window.breaks.contains($0) }
    }

    /// `missing` values evenly spaced strictly between `left` and `right`.
    private static func interpolation(from left: Double, to right: Double, missing: Int) -> [Double] {
        guard missing > 0 else { return [] }
        let steps = Double(missing + 1)
        return (1 ... missing).map { left + (right - left) * Double($0) / steps }
    }

    /// Each segment's index range in the joined series.
    private static func segmentRanges(_ segments: [[Double]]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        for segment in segments {
            ranges.append(start ..< start + segment.count)
            start += segment.count
        }
        return ranges
    }

    /// Step 1: integrate the series — the cumulative sum of deviations from the
    /// mean.
    private static func integratedSeries(_ rr: [Double]) -> [Double] {
        var mean: Double = 0
        vDSP_meanvD(rr, 1, &mean, vDSP_Length(rr.count))
        var integrated = [Double](repeating: 0, count: rr.count)
        var cumSum: Double = 0
        for i in 0 ..< rr.count {
            cumSum += rr[i] - mean
            integrated[i] = cumSum
        }
        return integrated
    }

    /// α2 needs both enough box sizes and enough beats; nil when either is
    /// short.
    private static func alpha2Exponent(
        integrated: [Double],
        sizes alpha2Sizes: [Int],
        segments: [Range<Int>]
    ) -> (value: Double, r2: Double)? {
        guard alpha2Sizes.count >= 3, integrated.count >= HRVConstants.MinimumBeats.forDFA else { return nil }
        let fluctuations = alpha2Sizes.map { computeFluctuation(integrated, boxSize: $0, segments: segments) }
        return logLogRegression(sizes: alpha2Sizes, fluctuations: fluctuations).map { (value: $0.slope, r2: $0.r2) }
    }

    // MARK: - Private Helpers

    /// Generate logarithmically-spaced box sizes for DFA regression.
    /// Uses a ratio of 2^(1/8) between successive sizes per PhysioNet reference,
    /// then rounds to unique integers.
    private static func logSpacedBoxSizes(from lower: Int, through upper: Int) -> [Int] {
        guard upper >= lower else { return [] }
        let ratio = pow(2.0, 1.0 / 8.0) // ~1.0905, per PhysioNet
        var sizes = [Int]()
        var current = Double(lower)
        while Int(round(current)) <= upper {
            let rounded = Int(round(current))
            if sizes.last != rounded {
                sizes.append(rounded)
            }
            current *= ratio
        }
        // Ensure the upper bound is included
        if let last = sizes.last, last != upper {
            sizes.append(upper)
        }
        return sizes
    }

    /// RMS fluctuation for a given box size: non-overlapping boxes laid from
    /// the start of each segment, none spanning two segments; 0 when no
    /// segment holds a whole box (the log-log fit then leaves the size out).
    private static func computeFluctuation(_ integrated: [Double], boxSize: Int, segments: [Range<Int>]) -> Double {
        var totalFluctuation: Double = 0
        var numBoxes = 0
        for segment in segments {
            for start in stride(from: segment.lowerBound, through: segment.upperBound - boxSize, by: boxSize) {
                totalFluctuation += detrendedSumOfSquares(integrated[start ..< (start + boxSize)])
                numBoxes += 1
            }
        }
        guard numBoxes > 0 else { return 0 }
        return sqrt(totalFluctuation / Double(numBoxes * boxSize))
    }

    /// One box, linearly detrended (least-squares fit), as a sum of squares.
    ///
    /// Takes a slice and fits in place. The box was copied into a new array
    /// and detrended into a second one, two allocations per box — and a night
    /// is tens of thousands of boxes across all scales, recomputed for every
    /// window the selector tries. The arithmetic is unchanged: the same
    /// least-squares line, the same residuals.
    private static func detrendedSumOfSquares(_ segment: ArraySlice<Double>) -> Double {
        let count = segment.count
        guard count >= 2, let line = leastSquaresLine(segment) else {
            return segment.reduce(0) { $0 + $1 * $1 }
        }
        var sumSq: Double = 0
        for (index, value) in segment.enumerated() {
            let residual = value - (line.intercept + line.slope * Double(index))
            sumSq += residual * residual
        }
        return sumSq
    }

    /// Least-squares fit of the segment against its own index, or nil when the
    /// x values are degenerate — the same condition `Statistics.linearRegression`
    /// reports, and the same answer: leave the segment untrended.
    private static func leastSquaresLine(_ segment: ArraySlice<Double>) -> (slope: Double, intercept: Double)? {
        let count = Double(segment.count)
        var sumX = 0.0, sumY = 0.0, sumXY = 0.0, sumXX = 0.0
        for (index, value) in segment.enumerated() {
            let x = Double(index)
            sumX += x
            sumY += value
            sumXY += x * value
            sumXX += x * x
        }
        let denominator = count * sumXX - sumX * sumX
        guard denominator != 0 else { return nil }
        let slope = (count * sumXY - sumX * sumY) / denominator
        return (slope, (sumY - slope * sumX) / count)
    }

    /// Log-log linear regression to find scaling exponent
    /// Delegates core regression to Statistics.linearRegression. A box size
    /// whose fluctuation is zero has no logarithm and is left out; nil when
    /// fewer than two sizes remain or the regression fails, rather than
    /// reporting an exponent of 0.
    private static func logLogRegression(sizes: [Int], fluctuations: [Double]) -> (slope: Double, r2: Double)? {
        let usable = zip(sizes, fluctuations).filter { $0.1 > 0 }
        guard usable.count >= 2 else { return nil }
        let logN = usable.map { log(Double($0.0)) }
        let logF = usable.map { log($0.1) }
        guard let result = Statistics.linearRegression(x: logN, y: logF) else { return nil }
        return (result.slope, result.r2)
    }
}
