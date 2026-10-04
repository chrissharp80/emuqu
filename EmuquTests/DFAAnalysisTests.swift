@testable import Emuqu
import XCTest

/// Tests for DFAAnalyzer
/// Validates Detrended Fluctuation Analysis computation
final class DFAAnalysisTests: XCTestCase {
    // MARK: - Test Helpers

    /// Create RR intervals with known statistical properties
    private func createRRIntervals(count: Int, meanMs: Double = 850, variability: Double = 50) -> [Double] {
        var rr = [Double]()
        for i in 0 ..< count {
            let variation = sin(Double(i) * 0.3) * variability
            rr.append(meanMs + variation)
        }
        return rr
    }

    /// Create white noise RR (should have α1 ≈ 0.5)
    private func createWhiteNoiseRR(count: Int) -> [Double] {
        var generator = DFAReferenceValidationTests.SeededGenerator(seed: 0xD1)
        return (0 ..< count).map { _ in 850 + Double.random(in: -50 ... 50, using: &generator) }
    }

    /// Create correlated RR (should have α1 close to 1.0)
    private func createCorrelatedRR(count: Int) -> [Double] {
        var rr = [Double]()
        var current = 850.0
        var generator = DFAReferenceValidationTests.SeededGenerator(seed: 0xD2)
        for i in 0 ..< count {
            // Pink noise-like: mix of short and long correlations
            let short = sin(Double(i) * 0.5) * 20
            let medium = sin(Double(i) * 0.1) * 30
            let long = sin(Double(i) * 0.02) * 15
            current = 850 + short + medium + long + Double.random(in: -5 ... 5, using: &generator)
            rr.append(current)
        }
        return rr
    }

    // MARK: - Basic Computation Tests

    func testDFARequiresMinimumSamples() {
        let shortRR = createRRIntervals(count: 50) // Less than 64
        let result = DFAAnalyzer.compute(shortRR)
        XCTAssertNil(result, "Should return nil with fewer than 64 samples")
    }

    func testDFAWithMinimumSamples() {
        let rr = createRRIntervals(count: 64)
        let result = DFAAnalyzer.compute(rr)
        XCTAssertNotNil(result, "Should compute with exactly 64 samples")
    }

    func testDFAAlpha1InPhysiologicalRange() throws {
        let rr = createCorrelatedRR(count: 300)
        let result = DFAAnalyzer.compute(rr)

        XCTAssertNotNil(result)
        // Physiological α1 typically ranges from 0.5 to 1.5
        XCTAssertGreaterThan(try XCTUnwrap(result?.alpha1), 0.3, "α1 should be above 0.3")
        XCTAssertLessThan(try XCTUnwrap(result?.alpha1), 2.0, "α1 should be below 2.0")
    }

    func testDFAReturnsValidR2() throws {
        let rr = createCorrelatedRR(count: 200)
        let result = DFAAnalyzer.compute(rr)

        XCTAssertNotNil(result)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(result?.alpha1R2), 0, "R² should be >= 0")
        XCTAssertLessThanOrEqual(try XCTUnwrap(result?.alpha1R2), 1, "R² should be <= 1")
    }

    // MARK: - Alpha2 Tests

    func testAlpha2RequiresSufficientData() {
        let shortRR = createRRIntervals(count: 100) // Less than 256
        let result = DFAAnalyzer.compute(shortRR)

        XCTAssertNotNil(result)
        XCTAssertNil(result?.alpha2, "α2 should be nil without sufficient data")
    }

    func testAlpha2WithSufficientData() throws {
        let rr = createCorrelatedRR(count: 500)
        let result = DFAAnalyzer.compute(rr)

        XCTAssertNotNil(result)
        XCTAssertNotNil(try XCTUnwrap(result?.alpha2), "α2 should be computed with 500+ samples")
        XCTAssertNotNil(try XCTUnwrap(result?.alpha2R2))
    }

    func testAlpha2InReasonableRange() throws {
        let rr = createCorrelatedRR(count: 500)
        let result = DFAAnalyzer.compute(rr)

        XCTAssertNotNil(result?.alpha2)
        // α2 typically ranges from 0.5 to 1.5 for physiological signals
        XCTAssertGreaterThan(try XCTUnwrap(result?.alpha2), 0.2)
        XCTAssertLessThan(try XCTUnwrap(result?.alpha2), 2.0)
    }

    // MARK: - Statistical Property Tests

    func testWhiteNoiseProducesLowAlpha() {
        // White noise should have α1 ≈ 0.5
        var alphas: [Double] = []
        for _ in 0 ..< 5 {
            let rr = createWhiteNoiseRR(count: 300)
            if let result = DFAAnalyzer.compute(rr) {
                alphas.append(result.alpha1)
            }
        }

        XCTAssertFalse(alphas.isEmpty)
        let avgAlpha = alphas.reduce(0, +) / Double(alphas.count)
        // Should be closer to 0.5 than 1.0
        XCTAssertLessThan(avgAlpha, 0.9, "White noise should produce α1 closer to 0.5")
    }

    func testCorrelatedSignalProducesModerateAlpha() throws {
        // Correlated signal should have α1 closer to 1.0
        let rr = createCorrelatedRR(count: 300)
        let result = DFAAnalyzer.compute(rr)

        XCTAssertNotNil(result)
        // Correlated signal should have α1 in physiological range
        // Sinusoidal mixing can push α1 higher than pure pink noise
        XCTAssertGreaterThan(try XCTUnwrap(result?.alpha1), 0.4, "Correlated signal should have α1 > 0.4")
        XCTAssertLessThan(try XCTUnwrap(result?.alpha1), 2.0, "Correlated signal should have α1 < 2.0")
    }

    // MARK: - Custom Range Tests

    func testCustomAlpha1Range() throws {
        let rr = createCorrelatedRR(count: 200)

        let defaultResult = DFAAnalyzer.compute(rr)
        let customResult = DFAAnalyzer.compute(rr, alpha1Range: 5 ... 12)

        XCTAssertNotNil(defaultResult)
        XCTAssertNotNil(customResult)
        // Results may differ slightly due to different box sizes
        XCTAssertNotEqual(try XCTUnwrap(defaultResult?.alpha1), try XCTUnwrap(customResult?.alpha1), accuracy: 0.01)
    }

    // MARK: - Reproducibility Tests

    func testDFAIsReproducible() throws {
        let rr = createCorrelatedRR(count: 300)

        let result1 = DFAAnalyzer.compute(rr)
        let result2 = DFAAnalyzer.compute(rr)

        XCTAssertNotNil(result1)
        XCTAssertNotNil(result2)
        XCTAssertEqual(
            try XCTUnwrap(result1?.alpha1),
            try XCTUnwrap(result2?.alpha1),
            accuracy: 0.0001,
            "Same input should produce identical output"
        )
    }

    // MARK: - Edge Cases

    func testDFAWithConstantRR() {
        let constantRR = [Double](repeating: 850, count: 100)
        let result = DFAAnalyzer.compute(constantRR)

        // Constant signal has zero fluctuation - may produce extreme values
        // The algorithm should still complete without crashing
        if let r = result {
            XCTAssertFalse(r.alpha1.isNaN, "α1 should not be NaN")
            XCTAssertFalse(r.alpha1.isInfinite, "α1 should not be infinite")
        }
    }

    func testDFAWithLargeDataset() throws {
        // Simulate long recording (2 hours at 60bpm = 7200 beats)
        let rr = createCorrelatedRR(count: 7200)
        let result = DFAAnalyzer.compute(rr)

        XCTAssertNotNil(result)
        XCTAssertNotNil(try XCTUnwrap(result?.alpha2), "Should compute α2 with large dataset")
    }

    func testDFAWithHighVariability() throws {
        // Very high variability (large RR range)
        var rr = [Double]()
        for i in 0 ..< 300 {
            rr.append(600 + sin(Double(i) * 0.2) * 300) // Range 300-900ms
        }

        let result = DFAAnalyzer.compute(rr)
        XCTAssertNotNil(result)
        XCTAssertFalse(try XCTUnwrap(result?.alpha1.isNaN))
    }

    // MARK: - R² Quality Tests

    func testGoodFitProducesHighR2() throws {
        // Well-structured data should produce good R² fit
        let rr = createCorrelatedRR(count: 500)
        let result = DFAAnalyzer.compute(rr)

        XCTAssertNotNil(result)
        XCTAssertGreaterThan(
            try XCTUnwrap(result?.alpha1R2),
            0.7,
            "Well-structured data should have R² > 0.7"
        )
    }
}
