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
    /// - Returns: DFA result with scaling exponents, or nil if insufficient data
    static func compute(
        _ rr: [Double],
        alpha1Range: ClosedRange<Int> = HRVConstants.DFA.alpha1ScaleMin ... HRVConstants.DFA.alpha1ScaleMax,
        alpha2Range: ClosedRange<Int> = HRVConstants.DFA.alpha2ScaleMin ... HRVConstants.DFA.alpha2ScaleMax
    ) -> DFAResult? {
        guard rr.count >= HRVConstants.DFA.alpha2ScaleMax else { return nil }
        let integrated = integratedSeries(rr)
        // Logarithmically-spaced box sizes per the PhysioNet reference
        // implementation (Peng et al. 1995). Log spacing keeps the log-log
        // regression domain evenly represented, avoiding the bias toward
        // smaller scales that linear spacing introduces.
        let maxBox = rr.count / 4
        let alpha1Sizes = logSpacedBoxSizes(from: alpha1Range.lowerBound, through: min(alpha1Range.upperBound, maxBox))
        let alpha2Sizes = logSpacedBoxSizes(from: alpha2Range.lowerBound, through: min(alpha2Range.upperBound, maxBox))
        guard alpha1Sizes.count >= 3 else { return nil }
        let alpha1Fluctuations = alpha1Sizes.map { computeFluctuation(integrated, boxSize: $0) }
        let (alpha1, alpha1R2) = logLogRegression(sizes: alpha1Sizes, fluctuations: alpha1Fluctuations)
        let alpha2 = alpha2Exponent(integrated: integrated, sizes: alpha2Sizes, beatCount: rr.count)
        return DFAResult(
            alpha1: alpha1,
            alpha2: alpha2?.value,
            alpha1R2: alpha1R2,
            alpha2R2: alpha2?.r2
        )
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
        beatCount: Int
    ) -> (value: Double, r2: Double)? {
        guard alpha2Sizes.count >= 3, beatCount >= HRVConstants.MinimumBeats.forDFA else { return nil }
        let fluctuations = alpha2Sizes.map { computeFluctuation(integrated, boxSize: $0) }
        let (a2, r2) = logLogRegression(sizes: alpha2Sizes, fluctuations: fluctuations)
        return (a2, r2)
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

    /// Compute RMS fluctuation for a given box size
    private static func computeFluctuation(_ integrated: [Double], boxSize: Int) -> Double {
        let numBoxes = integrated.count / boxSize
        guard numBoxes > 0 else { return 0 }
        var totalFluctuation: Double = 0
        for boxIdx in 0 ..< numBoxes {
            let start = boxIdx * boxSize
            totalFluctuation += detrendedSumOfSquares(Array(integrated[start ..< (start + boxSize)]))
        }
        return sqrt(totalFluctuation / Double(numBoxes * boxSize))
    }

    /// One box, linearly detrended (least-squares fit), as a sum of squares.
    private static func detrendedSumOfSquares(_ segment: [Double]) -> Double {
        let detrended = linearDetrend(segment)
        var sumSq: Double = 0
        vDSP_dotprD(detrended, 1, detrended, 1, &sumSq, vDSP_Length(detrended.count))
        return sumSq
    }

    /// Remove linear trend from segment (delegates to Statistics.linearDetrend)
    private static func linearDetrend(_ segment: [Double]) -> [Double] {
        Statistics.linearDetrend(segment)
    }

    /// Log-log linear regression to find scaling exponent
    /// Delegates core regression to Statistics.linearRegression.
    private static func logLogRegression(sizes: [Int], fluctuations: [Double]) -> (slope: Double, r2: Double) {
        let n = sizes.count
        guard n >= 2 else { return (0, 0) }

        let logN = sizes.map { log(Double($0)) }
        let logF = fluctuations.map { $0 > 0 ? log($0) : -10.0 }

        guard let result = Statistics.linearRegression(x: logN, y: logF) else {
            return (0, 0)
        }
        return (result.slope, result.r2)
    }
}
