import Accelerate
import Foundation

/// Nonlinear HRV analysis (Poincaré plot metrics and entropy)
enum NonlinearAnalyzer {
    // MARK: - Public API

    /// Compute nonlinear metrics for clean RR intervals
    /// - Parameters:
    ///   - series: The RR series
    ///   - flags: Artifact flags
    ///   - windowStart: Start index
    ///   - windowEnd: End index (exclusive)
    /// - Returns: Nonlinear metrics, or nil if insufficient data
    static func computeNonlinear(
        _ series: RRSeries,
        flags: [ArtifactFlags],
        windowStart: Int,
        windowEnd: Int
    ) -> NonlinearMetrics? {
        // `cleanWindow` is nil for bounds that cannot address both points and
        // flags; no adjacent pair is the time domain's insufficient-data case.
        guard let window = TimeDomainAnalyzer.cleanWindow(series, flags: flags, windowStart: windowStart, windowEnd: windowEnd),
              window.rr.count >= 10,
              let diffs = TimeDomainAnalyzer.successiveDifferences(in: window)
        else { return nil }
        return metrics(for: window, successiveDifferences: diffs)
    }

    /// The four nonlinear families over a window's clean beats. None of them
    /// treats a removed beat or a recording break as adjacency: SD1 uses the
    /// time domain's adjacent pairs, entropy templates stay inside runs of
    /// neighbouring beats, and DFA interpolates removed beats and splits at
    /// breaks (`DFAAnalyzer.compute(window:)`). A window with no removed beat
    /// and no break gives the textbook single-series values.
    private static func metrics(
        for window: CleanBeatWindow, successiveDifferences diffs: [Double]
    ) -> NonlinearMetrics {
        let (sd1, sd2) = computePoincareMetrics(window.rr, successiveDifferences: diffs)
        let dfaResult = DFAAnalyzer.compute(window: window)
        let followsGap = window.rr.indices.map { $0 > 0 && !window.isAdjacentToPrevious($0) }
        return NonlinearMetrics(
            sd1: sd1,
            sd2: sd2,
            sd1Sd2Ratio: sd2 > 0 ? sd1 / sd2 : 0,
            // Both entropies are O(n^2); each subsamples internally.
            sampleEntropy: computeSampleEntropy(window.rr, followsGap: followsGap, m: 2, r: 0.2),
            approxEntropy: computeApproxEntropy(window.rr, followsGap: followsGap, m: 2, r: 0.2),
            dfaAlpha1: dfaResult?.alpha1,
            dfaAlpha2: dfaResult?.alpha2,
            dfaAlpha1R2: dfaResult?.alpha1R2
        )
    }

    /// Beats in runs of neighbours, for entropy: a template of m beats must
    /// be m CONSECUTIVE beats (Pincus 1991; Richman & Moorman 2000), so one
    /// that would cross a removed beat or a recording break is not formed.
    private struct BeatRuns {
        let values: [Double]
        /// For each beat, how many beats its run has from it to the end.
        let runLength: [Int]

        init(values: [Double], followsGap: [Bool]) {
            self.values = values
            var lengths = [Int](repeating: 1, count: values.count)
            for i in stride(from: values.count - 2, through: 0, by: -1) where !followsGap[i + 1] {
                lengths[i] = lengths[i + 1] + 1
            }
            runLength = lengths
        }

        /// Starts of every template of `length` beats that lies inside a run.
        /// With no gap, every start from 0 through `values.count - length`.
        func templateStarts(length: Int) -> [Int] {
            values.indices.filter { runLength[$0] >= length }
        }
    }

    // MARK: - Approximate Entropy

    /// Compute approximate entropy
    /// - Parameters:
    ///   - rr: RR intervals
    ///   - m: Embedding dimension (typically 2)
    ///   - r: Tolerance as fraction of SD (typically 0.2)
    /// - Returns: Approximate entropy value
    private static func computeApproxEntropy(_ rr: [Double], followsGap: [Bool], m: Int, r: Double) -> Double? {
        guard rr.count >= m + 2 else { return nil }
        let tolerance = r * sampleStandardDeviation(rr)
        let runs = entropySubsample(rr, followsGap: followsGap)
        guard let phiM = computePhi(runs, templateLength: m, tolerance: tolerance),
              let phiM1 = computePhi(runs, templateLength: m + 1, tolerance: tolerance)
        else { return nil }
        return phiM - phiM1
    }

    /// Compute Phi value for ApEn calculation, over the templates that lie
    /// inside a run of neighbouring beats; nil with fewer than two.
    private static func computePhi(_ runs: BeatRuns, templateLength: Int, tolerance: Double) -> Double? {
        let starts = runs.templateStarts(length: templateLength)
        guard starts.count >= 2 else { return nil }
        let numTemplates = starts.count
        var logSum: Double = 0
        for i in starts {
            // Includes the self-match, so the count is always at least 1.
            let count = starts.count { j in
                templatesMatch(runs.values, i, j, templateLength: templateLength, tolerance: tolerance)
            }
            let ci = Double(count) / Double(numTemplates)
            if ci > 0 { logSum += log(ci) }
        }
        return logSum / Double(numTemplates)
    }

    /// Chebyshev distance: every element of the two templates within tolerance.
    private static func templatesMatch(
        _ data: [Double],
        _ i: Int,
        _ j: Int,
        templateLength: Int,
        tolerance: Double
    ) -> Bool {
        for k in 0 ..< templateLength where abs(data[i + k] - data[j + k]) > tolerance {
            return false
        }
        return true
    }

    // MARK: - Poincaré Plot

    /// Compute SD1 and SD2 from Poincaré plot
    /// SD1 = short-term variability (perpendicular to line of identity)
    /// SD2 = long-term variability (along line of identity)
    ///
    /// Both use population variance (expected-value approach) per Brennan et al. (2001)
    /// to preserve the fundamental identity: SD1² + SD2² = 2·Var(RR)
    /// Poincaré SD1²=½·SDSD², SD1²+SD2²=2·SDNN² — Brennan, Palaniswami, Kamen,
    /// IEEE TBME 2001;48:1342-1347.
    ///
    /// `diffs` are the time domain's successive differences
    /// (`TimeDomainAnalyzer.successiveDifferences(in:)`): adjacent beats only,
    /// never across a removed beat or a recording break, through the same
    /// ectopic gate. Each Poincaré point (RR(n), RR(n+1)) is a pair of
    /// neighbouring beats, so SD1 comes from exactly the pairs SDSD does:
    /// SD1² = ½·Var(diffs), population variance here where SDSD divides by
    /// N−1. SD2 keeps Brennan's identity with the variance of every clean
    /// beat, the beats SDNN is taken over.
    private static func computePoincareMetrics(
        _ rr: [Double], successiveDifferences diffs: [Double]
    ) -> (sd1: Double, sd2: Double) {
        guard rr.count >= 2 else { return (0, 0) }
        // SD1 = SDSD / sqrt(2), using the population variance of successive
        // differences. Per Brennan et al. (2001): SD1^2 = Var(diffs) / 2.
        let sd1 = sqrt(max(0, successiveDifferenceVariance(diffs)) / 2.0)
        // SD2^2 = 2*Var(RR) - SD1^2. Population variance again, so the Brennan
        // identity SD1^2 + SD2^2 = 2*Var(RR) holds exactly.
        let variance = populationVariance(rr)
        return (sd1, sqrt(max(0, 2 * variance - sd1 * sd1)))
    }

    /// Population variance of a series of successive differences.
    private static func successiveDifferenceVariance(_ diffs: [Double]) -> Double {
        // No differences: `nDiffs` would be a zero divisor.
        guard !diffs.isEmpty else { return 0 }
        var diffSum: Double = 0
        var diffSumSq: Double = 0
        for diff in diffs {
            diffSum += diff
            diffSumSq += diff * diff
        }
        let nDiffs = Double(diffs.count)
        let meanDiff = diffSum / nDiffs
        return diffSumSq / nDiffs - meanDiff * meanDiff
    }

    /// Population variance (divisor N), matching the Brennan convention.
    private static func populationVariance(_ rr: [Double]) -> Double {
        var mean: Double = 0
        vDSP_meanvD(rr, 1, &mean, vDSP_Length(rr.count))
        var sumSq: Double = 0
        for val in rr {
            let diff = val - mean
            sumSq += diff * diff
        }
        return sumSq / Double(rr.count)
    }

    /// Sample standard deviation (divisor N-1), the basis for entropy tolerance.
    private static func sampleStandardDeviation(_ rr: [Double]) -> Double {
        var mean: Double = 0
        vDSP_meanvD(rr, 1, &mean, vDSP_Length(rr.count))
        var sumSq: Double = 0
        for val in rr {
            let diff = val - mean
            sumSq += diff * diff
        }
        return sqrt(sumSq / Double(rr.count - 1))
    }

    /// Both entropies are O(n^2), so they cap at 1000 points. Evenly-spaced
    /// sampling preserves temporal structure better than random, and 1000
    /// points still gives reliable estimates for m=2, r=0.2*SD (Richman &
    /// Moorman 2000). Tolerance is always computed from the FULL dataset, which
    /// keeps the statistical basis correct regardless of the subsampling.
    /// Two picks continue one run only when no gap (`followsGap`) lies
    /// between the beats they were taken from.
    private static func entropySubsample(_ rr: [Double], followsGap: [Bool]) -> BeatRuns {
        let maxEntropyPoints = 1_000
        guard rr.count > maxEntropyPoints else { return BeatRuns(values: rr, followsGap: followsGap) }
        let stride = Double(rr.count) / Double(maxEntropyPoints)
        let picks = (0 ..< maxEntropyPoints).map { Int(Double($0) * stride) }
        // gapsThrough[i]: how many gaps lie at or before beat i.
        var gapsThrough = [Int]()
        gapsThrough.reserveCapacity(rr.count)
        for gap in followsGap {
            gapsThrough.append((gapsThrough.last ?? 0) + (gap ? 1 : 0))
        }
        let pickedGaps = picks.indices.map { $0 > 0 && gapsThrough[picks[$0]] > gapsThrough[picks[$0 - 1]] }
        return BeatRuns(values: picks.map { rr[$0] }, followsGap: pickedGaps)
    }

    // MARK: - Sample Entropy

    /// Compute sample entropy
    /// - Parameters:
    ///   - rr: RR intervals
    ///   - m: Embedding dimension (typically 2)
    ///   - r: Tolerance as fraction of SD (typically 0.2)
    /// - Returns: Sample entropy value, or nil if cannot compute
    /// Sample entropy m=2, r=0.2·SD, −ln(A/B) — Richman & Moorman, Am J Physiol
    /// 2000;278:H2039.
    private static func computeSampleEntropy(_ rr: [Double], followsGap: [Bool], m: Int, r: Double) -> Double? {
        guard rr.count >= m + 2 else { return nil }
        let tolerance = r * sampleStandardDeviation(rr)
        let runs = entropySubsample(rr, followsGap: followsGap)
        // Both lengths compare the same templates (Richman & Moorman): those
        // with room for m + 1 beats inside their run — the first N − m when
        // there is no gap — so A is not counted over fewer templates than B.
        let starts = runs.templateStarts(length: m + 1)
        let countM = countTemplateMatches(runs.values, starts: starts, templateLength: m, tolerance: tolerance)
        let countM1 = countTemplateMatches(runs.values, starts: starts, templateLength: m + 1, tolerance: tolerance)
        guard countM > 0, countM1 > 0 else { return nil }
        return -log(Double(countM1) / Double(countM))
    }

    /// Count matching template pairs among the templates of `templateLength`
    /// beginning at `starts`, using Chebyshev distance. Every start must
    /// leave room for `templateLength` beats.
    private static func countTemplateMatches(_ data: [Double], starts: [Int], templateLength: Int, tolerance: Double) -> Int {
        var count = 0
        for (position, i) in starts.enumerated() {
            count += starts[(position + 1)...].count { j in
                templatesMatch(data, i, j, templateLength: templateLength, tolerance: tolerance)
            }
        }
        return count
    }
}
