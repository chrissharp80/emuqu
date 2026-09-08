import Accelerate
import Foundation

// MARK: - Statistics

/// A namespace for pure statistical helper functions.
/// Uses the Accelerate framework where it provides a real performance benefit.
enum Statistics {
    // MARK: - Central Tendency

    /// Arithmetic mean of `values`, computed via `vDSP_meanvD`.
    /// Returns `0` when the array is empty.
    static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        var result: Double = 0
        vDSP_meanvD(values, 1, &result, vDSP_Length(values.count))
        return result
    }

    // MARK: - Dispersion

    /// Sample standard deviation (N-1 denominator).
    /// Uses Accelerate to subtract the mean and compute the sum of squares.
    /// Returns `0` when the array contains fewer than two elements.
    static func sampleStandardDeviation(_ values: [Double]) -> Double {
        sqrt(sampleVariance(values))
    }

    /// Sample variance (N-1 denominator).
    /// Returns `0` when the array contains fewer than two elements.
    static func sampleVariance(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }

        let mu = mean(values)

        // Subtract the mean from every element.
        var negMu = -mu
        var deviations = [Double](repeating: 0, count: values.count)
        vDSP_vsaddD(values, 1, &negMu, &deviations, 1, vDSP_Length(values.count))

        // Sum of squared deviations via dot product.
        var sumSquares: Double = 0
        vDSP_dotprD(deviations, 1, deviations, 1, &sumSquares, vDSP_Length(deviations.count))

        return sumSquares / Double(values.count - 1)
    }

    // MARK: - Root Mean Square

    /// Root mean square of `values`, computed via `vDSP_dotprD`.
    /// Returns `0` when the array is empty.
    static func rootMeanSquare(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }

        var sumSquares: Double = 0
        vDSP_dotprD(values, 1, values, 1, &sumSquares, vDSP_Length(values.count))
        return sqrt(sumSquares / Double(values.count))
    }

    // MARK: - Relative Dispersion

    /// Coefficient of variation (sample SD / mean).
    /// Returns `nil` when the mean is zero (ratio is undefined).
    /// Returns `0` when the array contains fewer than two elements.
    static func coefficientOfVariation(_ values: [Double]) -> Double? {
        let mu = mean(values)
        guard mu != 0 else { return nil }
        return sampleStandardDeviation(values) / mu
    }

    // MARK: - Linear Regression

    /// Result of a simple linear regression (y = intercept + slope * x).
    struct RegressionResult {
        let slope: Double
        let intercept: Double
        /// Coefficient of determination (0-1). Higher = better fit.
        let r2: Double
    }

    /// The five running sums an ordinary-least-squares fit needs.
    private struct RegressionSums {
        var sumX: Double = 0
        var sumY: Double = 0
        var sumXY: Double = 0
        var sumX2: Double = 0
        var sumY2: Double = 0
    }

    /// Ordinary least squares regression of `y` against `x`.
    /// Returns `nil` when fewer than 2 points are provided or the denominator is degenerate.
    static func linearRegression(x: [Double], y: [Double]) -> RegressionResult? {
        let n = x.count
        guard n >= 2, n == y.count else { return nil }
        let sums = regressionSums(x: x, y: y)
        let nD = Double(n)
        let denom = nD * sums.sumX2 - sums.sumX * sums.sumX
        guard abs(denom) > 1e-10 else { return nil }
        let slope = (nD * sums.sumXY - sums.sumX * sums.sumY) / denom
        let intercept = (sums.sumY - slope * sums.sumX) / nD
        let r2 = coefficientOfDetermination(x: x, y: y, slope: slope, intercept: intercept, sums: sums)
        return RegressionResult(slope: slope, intercept: intercept, r2: r2)
    }

    private static func regressionSums(x: [Double], y: [Double]) -> RegressionSums {
        var sums = RegressionSums()
        for i in 0 ..< x.count {
            sums.sumX += x[i]
            sums.sumY += y[i]
            sums.sumXY += x[i] * y[i]
            sums.sumX2 += x[i] * x[i]
            sums.sumY2 += y[i] * y[i]
        }
        return sums
    }

    /// R² via residuals. Zero when the data has no variance to explain.
    private static func coefficientOfDetermination(
        x: [Double], y: [Double], slope: Double, intercept: Double, sums: RegressionSums
    ) -> Double {
        let nD = Double(x.count)
        let ssTotal = sums.sumY2 - (sums.sumY * sums.sumY) / nD
        guard ssTotal > 0 else { return 0 }
        var ssResidual: Double = 0
        for i in 0 ..< x.count {
            let residual = y[i] - (intercept + slope * x[i])
            ssResidual += residual * residual
        }
        return max(0, min(1, 1.0 - ssResidual / ssTotal))
    }

    /// Subtract a linear trend from `segment`, returning the detrended values.
    /// Returns the input unchanged when fewer than 2 elements are provided.
    static func linearDetrend(_ segment: [Double]) -> [Double] {
        let n = segment.count
        guard n >= 2 else { return segment }

        let x = (0 ..< n).map { Double($0) }
        guard let reg = linearRegression(x: x, y: segment) else { return segment }

        var detrended = [Double](repeating: 0, count: n)
        for i in 0 ..< n {
            detrended[i] = segment[i] - (reg.intercept + reg.slope * Double(i))
        }
        return detrended
    }
}

// MARK: - Array Convenience

extension [Double] {
    /// Arithmetic mean of the array's elements.
    var mean: Double {
        Statistics.mean(self)
    }

    /// Sample standard deviation (N-1 denominator).
    var sampleSD: Double {
        Statistics.sampleStandardDeviation(self)
    }

    /// Root mean square of the array's elements.
    var rms: Double {
        Statistics.rootMeanSquare(self)
    }
}
