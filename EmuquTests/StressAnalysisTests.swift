@testable import Emuqu
import XCTest

/// Tests for StressAnalyzer
/// Validates stress index, PNS/SNS indices, and readiness scoring
final class StressAnalysisTests: XCTestCase {
    // MARK: - Test Helpers

    private func createRRIntervals(count: Int, meanMs: Double = 850, variability: Double = 50) -> [Double] {
        var rr = [Double]()
        for i in 0 ..< count {
            // Create realistic RR variation
            let variation = sin(Double(i) * 0.5) * variability
            rr.append(meanMs + variation)
        }
        return rr
    }

    private func createLowVariabilityRR(count: Int, meanMs: Double = 850) -> [Double] {
        // Very low variability - high stress pattern
        (0 ..< count).map { _ in meanMs + Double.random(in: -5 ... 5) }
    }

    private func createHighVariabilityRR(count: Int, meanMs: Double = 850) -> [Double] {
        // High variability - low stress pattern
        (0 ..< count).map { _ in meanMs + Double.random(in: -100 ... 100) }
    }

    // MARK: - Stress Index Tests

    func testStressIndexRequiresMinimumSamples() {
        let shortRR = createRRIntervals(count: 15)
        let result = StressAnalyzer.computeStressIndex(shortRR)
        XCTAssertNil(result, "Should return nil with fewer than 20 samples")
    }

    func testStressIndexWithValidData() {
        let rr = createRRIntervals(count: 100)
        let result = StressAnalyzer.computeStressIndex(rr)
        XCTAssertNotNil(result)
        XCTAssertGreaterThan(result ?? 0, 0, "Stress index should be positive")
    }

    func testStressIndexHigherForLowVariability() throws {
        let lowVar = createLowVariabilityRR(count: 100)
        let highVar = createHighVariabilityRR(count: 100)

        let lowVarStress = StressAnalyzer.computeStressIndex(lowVar)
        let highVarStress = StressAnalyzer.computeStressIndex(highVar)

        XCTAssertNotNil(lowVarStress)
        XCTAssertNotNil(highVarStress)

        // Low variability should produce higher stress index
        XCTAssertGreaterThan(
            try XCTUnwrap(lowVarStress),
            try XCTUnwrap(highVarStress),
            "Low variability RR should have higher stress index"
        )
    }

    func testStressIndexWithConstantRR() {
        // All identical values - zero range
        let constantRR = [Double](repeating: 850, count: 50)
        let result = StressAnalyzer.computeStressIndex(constantRR)
        XCTAssertNil(result, "Constant RR (zero range) should return nil")
    }

    func testStressIndexReasonableRange() throws {
        let rr = createRRIntervals(count: 200, meanMs: 900, variability: 40)
        let result = StressAnalyzer.computeStressIndex(rr)

        XCTAssertNotNil(result)
        // Typical stress index range is 0-500+, with healthy resting ~50-150
        XCTAssertGreaterThan(try XCTUnwrap(result), 0)
        XCTAssertLessThan(try XCTUnwrap(result), 1000, "Stress index should be in reasonable range")
    }

    // MARK: - PNS Index Tests

    func testPNSIndexWithNormalValues() {
        // Using reference values should give ~0
        let pns = StressAnalyzer.computePNSIndex(meanRR: 926, rmssd: 42, sd1: 29)
        XCTAssertEqual(pns, 0, accuracy: 0.5, "Reference values should produce PNS near 0")
    }

    func testPNSIndexHighForHighVagalTone() {
        // High RMSSD and high mean RR indicate strong parasympathetic
        let pns = StressAnalyzer.computePNSIndex(meanRR: 1100, rmssd: 80, sd1: 60)
        XCTAssertGreaterThan(pns, 1.0, "High vagal tone should produce positive PNS")
    }

    func testPNSIndexLowForLowVagalTone() {
        // Low RMSSD and low mean RR indicate weak parasympathetic
        let pns = StressAnalyzer.computePNSIndex(meanRR: 700, rmssd: 15, sd1: 10)
        XCTAssertLessThan(pns, -1.0, "Low vagal tone should produce negative PNS")
    }

    func testPNSIndexSymmetry() {
        // Positive and negative deviations should be symmetric around 0
        let positive = StressAnalyzer.computePNSIndex(meanRR: 1016, rmssd: 61, sd1: 42) // +1 SD each
        let negative = StressAnalyzer.computePNSIndex(meanRR: 836, rmssd: 23, sd1: 16) // -1 SD each

        XCTAssertGreaterThan(positive, 0)
        XCTAssertLessThan(negative, 0)
        XCTAssertEqual(abs(positive), abs(negative), accuracy: 0.3)
    }

    // MARK: - SNS Index Tests

    func testSNSIndexWithNormalValues() {
        // Using reference values should give ~0
        // Reference: meanHR=66, stressIndex=100 (Baevsky SI normal), sd2=65
        let sns = StressAnalyzer.computeSNSIndex(meanHR: 66, stressIndex: 100, sd2: 65)
        XCTAssertEqual(sns, 0, accuracy: 0.5, "Reference values should produce SNS near 0")
    }

    func testSNSIndexHighForSympatheticDominance() {
        // High HR, high stress index, low SD2 indicate sympathetic dominance
        // Stress index reference is 100 (SD=50), so 200 is +2 SD above normal
        let sns = StressAnalyzer.computeSNSIndex(meanHR: 85, stressIndex: 200, sd2: 35)
        XCTAssertGreaterThan(sns, 1.0, "Sympathetic dominance should produce positive SNS")
    }

    func testSNSIndexLowForParasympatheticDominance() {
        // Low HR, low stress, high SD2 indicate parasympathetic dominance
        let sns = StressAnalyzer.computeSNSIndex(meanHR: 52, stressIndex: 3, sd2: 100)
        XCTAssertLessThan(sns, -1.0, "Parasympathetic dominance should produce negative SNS")
    }

    func testSNSIndexSD2Inversion() {
        // Higher SD2 should lower SNS (inverse relationship)
        let lowSD2 = StressAnalyzer.computeSNSIndex(meanHR: 66, stressIndex: 10, sd2: 40)
        let highSD2 = StressAnalyzer.computeSNSIndex(meanHR: 66, stressIndex: 10, sd2: 90)

        XCTAssertGreaterThan(
            lowSD2,
            highSD2,
            "Lower SD2 should produce higher SNS index"
        )
    }

    // MARK: - Readiness Score Tests

    func testReadinessScoreWithoutBaseline() {
        // Without baseline, uses absolute RMSSD
        let highRMSSD = StressAnalyzer.computeReadinessScore(rmssd: 60, baselineRMSSD: nil, alpha1: nil)
        let lowRMSSD = StressAnalyzer.computeReadinessScore(rmssd: 15, baselineRMSSD: nil, alpha1: nil)

        XCTAssertGreaterThan(highRMSSD, lowRMSSD)
        XCTAssertGreaterThanOrEqual(highRMSSD, 1)
        XCTAssertLessThanOrEqual(highRMSSD, 10)
    }

    func testReadinessScoreWithBaseline() {
        let baseline = 45.0

        // At baseline
        let atBaseline = StressAnalyzer.computeReadinessScore(rmssd: 45, baselineRMSSD: baseline, alpha1: nil)

        // Above baseline
        let aboveBaseline = StressAnalyzer.computeReadinessScore(rmssd: 50, baselineRMSSD: baseline, alpha1: nil)

        // Below baseline
        let belowBaseline = StressAnalyzer.computeReadinessScore(rmssd: 25, baselineRMSSD: baseline, alpha1: nil)

        XCTAssertGreaterThan(aboveBaseline, belowBaseline)
        XCTAssertGreaterThanOrEqual(atBaseline, 5) // Neutral baseline
    }

    func testReadinessScoreWithOptimalAlpha1() {
        // Optimal α1 range is 0.75-1.0
        let optimalAlpha = StressAnalyzer.computeReadinessScore(rmssd: 40, baselineRMSSD: 40, alpha1: 0.85)
        let highAlpha = StressAnalyzer.computeReadinessScore(rmssd: 40, baselineRMSSD: 40, alpha1: 1.3)
        let lowAlpha = StressAnalyzer.computeReadinessScore(rmssd: 40, baselineRMSSD: 40, alpha1: 0.4)

        XCTAssertGreaterThan(optimalAlpha, highAlpha)
        XCTAssertGreaterThan(optimalAlpha, lowAlpha)
    }

    func testReadinessScoreClamping() {
        // Even extreme values should clamp to 1-10
        let extreme1 = StressAnalyzer.computeReadinessScore(rmssd: 200, baselineRMSSD: 30, alpha1: 0.9)
        let extreme2 = StressAnalyzer.computeReadinessScore(rmssd: 5, baselineRMSSD: 100, alpha1: 2.0)

        XCTAssertLessThanOrEqual(extreme1, 10)
        XCTAssertGreaterThanOrEqual(extreme1, 1)
        XCTAssertLessThanOrEqual(extreme2, 10)
        XCTAssertGreaterThanOrEqual(extreme2, 1)
    }

    func testReadinessScoreNilAlpha1() {
        // Should work without α1
        let score = StressAnalyzer.computeReadinessScore(rmssd: 50, baselineRMSSD: 45, alpha1: nil)
        XCTAssertGreaterThanOrEqual(score, 1)
        XCTAssertLessThanOrEqual(score, 10)
    }

    // MARK: - Edge Cases

    func testStressIndexWithEmptyArray() {
        let result = StressAnalyzer.computeStressIndex([])
        XCTAssertNil(result)
    }

    func testStressIndexWithNegativeValues() {
        // Should handle gracefully (though shouldn't happen in practice)
        let rr = [-100.0, -200.0, -150.0] + createRRIntervals(count: 50)
        let result = StressAnalyzer.computeStressIndex(rr)
        // Should either return nil or a valid positive number
        if let r = result {
            XCTAssertGreaterThan(r, 0)
        }
    }

    func testPNSIndexWithZeroValues() {
        let pns = StressAnalyzer.computePNSIndex(meanRR: 0, rmssd: 0, sd1: 0)
        // Should return a valid number (negative since below reference)
        XCTAssertFalse(pns.isNaN)
        XCTAssertFalse(pns.isInfinite)
    }

    func testReadinessScoreWithZeroBaseline() {
        // Zero baseline should use absolute RMSSD path
        let score = StressAnalyzer.computeReadinessScore(rmssd: 50, baselineRMSSD: 0, alpha1: 0.9)
        XCTAssertGreaterThanOrEqual(score, 1)
        XCTAssertLessThanOrEqual(score, 10)
    }
}
