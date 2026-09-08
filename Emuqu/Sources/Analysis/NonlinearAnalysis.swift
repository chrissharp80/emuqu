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
        guard cleanRR.count >= 10 else { return nil }
        return metrics(forCleanRR: cleanRR)
    }

    /// The four nonlinear families over an already-cleaned RR array.
    private static func metrics(forCleanRR cleanRR: [Double]) -> NonlinearMetrics {
        let (sd1, sd2) = computePoincareMetrics(cleanRR)
        let dfaResult = DFAAnalyzer.compute(cleanRR)
        return NonlinearMetrics(
            sd1: sd1,
            sd2: sd2,
            sd1Sd2Ratio: sd2 > 0 ? sd1 / sd2 : 0,
            // Both entropies are O(n^2); each subsamples internally.
            sampleEntropy: computeSampleEntropy(cleanRR, m: 2, r: 0.2),
            approxEntropy: computeApproxEntropy(cleanRR, m: 2, r: 0.2),
            dfaAlpha1: dfaResult?.alpha1,
            dfaAlpha2: dfaResult?.alpha2,
            dfaAlpha1R2: dfaResult?.alpha1R2
        )
    }

    // MARK: - Approximate Entropy

    /// Compute approximate entropy
    /// - Parameters:
    ///   - rr: RR intervals
    ///   - m: Embedding dimension (typically 2)
    ///   - r: Tolerance as fraction of SD (typically 0.2)
    /// - Returns: Approximate entropy value
    private static func computeApproxEntropy(_ rr: [Double], m: Int, r: Double) -> Double? {
        guard rr.count >= m + 2 else { return nil }
        let tolerance = r * sampleStandardDeviation(rr)
        let entropyValues = entropySubsample(rr)
        guard let phiM = computePhi(entropyValues, templateLength: m, tolerance: tolerance),
              let phiM1 = computePhi(entropyValues, templateLength: m + 1, tolerance: tolerance)
        else { return nil }
        return phiM - phiM1
    }

    /// Compute Phi value for ApEn calculation
    private static func computePhi(_ data: [Double], templateLength: Int, tolerance: Double) -> Double? {
        let n = data.count
        guard n > templateLength else { return nil }
        let numTemplates = n - templateLength + 1
        var logSum: Double = 0
        for i in 0 ..< numTemplates {
            // Includes the self-match, so the count is always at least 1.
            let count = (0 ..< numTemplates).count { j in
                templatesMatch(data, i, j, templateLength: templateLength, tolerance: tolerance)
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
    private static func computePoincareMetrics(_ rr: [Double]) -> (sd1: Double, sd2: Double) {
        guard rr.count >= 2 else { return (0, 0) }
        // SD1 = SDSD / sqrt(2), using the population variance of successive
        // differences. Per Brennan et al. (2001): SD1^2 = Var(diffs) / 2.
        let sd1 = sqrt(max(0, successiveDifferenceVariance(rr)) / 2.0)
        // SD2^2 = 2*Var(RR) - SD1^2. Population variance again, so the Brennan
        // identity SD1^2 + SD2^2 = 2*Var(RR) holds exactly.
        let variance = populationVariance(rr)
        return (sd1, sqrt(max(0, 2 * variance - sd1 * sd1)))
    }

    /// Population variance of the RR(n+1) - RR(n) series.
    private static func successiveDifferenceVariance(_ rr: [Double]) -> Double {
        // Fewer than two beats yields no differences: the loop bound would be
        // invalid and `nDiffs` would be a zero divisor.
        guard rr.count >= 2 else { return 0 }
        var diffSum: Double = 0
        var diffSumSq: Double = 0
        for i in 0 ..< (rr.count - 1) {
            let diff = rr[i + 1] - rr[i]
            diffSum += diff
            diffSumSq += diff * diff
        }
        let nDiffs = Double(rr.count - 1)
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
    private static func entropySubsample(_ rr: [Double]) -> [Double] {
        let maxEntropyPoints = 1_000
        guard rr.count > maxEntropyPoints else { return rr }
        let stride = Double(rr.count) / Double(maxEntropyPoints)
        return (0 ..< maxEntropyPoints).map { rr[Int(Double($0) * stride)] }
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
    private static func computeSampleEntropy(_ rr: [Double], m: Int, r: Double) -> Double? {
        guard rr.count >= m + 2 else { return nil }
        let tolerance = r * sampleStandardDeviation(rr)
        let entropyValues = entropySubsample(rr)
        let countM = countTemplateMatches(entropyValues, templateLength: m, tolerance: tolerance)
        let countM1 = countTemplateMatches(entropyValues, templateLength: m + 1, tolerance: tolerance)
        guard countM > 0, countM1 > 0 else { return nil }
        return -log(Double(countM1) / Double(countM))
    }

    /// Count matching template pairs using Chebyshev distance
    private static func countTemplateMatches(_ data: [Double], templateLength: Int, tolerance: Double) -> Int {
        let n = data.count
        guard n > templateLength else { return 0 }
        var count = 0
        for i in 0 ..< (n - templateLength) {
            count += ((i + 1) ..< (n - templateLength)).count { j in
                templatesMatch(data, i, j, templateLength: templateLength, tolerance: tolerance)
            }
        }
        return count
    }
}
