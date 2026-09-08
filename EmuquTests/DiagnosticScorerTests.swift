@testable import Emuqu
import XCTest

/// Tests for DiagnosticScorer
/// Validates scoring logic produces expected results for various HRV patterns
final class DiagnosticScorerTests: XCTestCase {
    var scorer = DiagnosticScorer()

    // MARK: - Basic Scoring Tests

    func testExcellentMetricsProduceHighScore() {
        let metrics = DiagnosticMetrics(
            rmssd: 65.0, // Excellent
            stressIndex: 80.0, // Very low stress
            lfHfRatio: 1.2, // Optimal balance
            dfaAlpha1: 0.85, // Optimal recovery
            isConsolidated: true
        )

        let result = scorer.computeScore(from: metrics)

        XCTAssertGreaterThanOrEqual(result.score, 80.0, "Excellent metrics should produce score >= 80")
        XCTAssertEqual(result.status, .wellRecovered)
    }

    func testPoorMetricsProduceLowScore() {
        let metrics = DiagnosticMetrics(
            rmssd: 15.0, // Low
            stressIndex: 350.0, // High stress
            lfHfRatio: 4.0, // Sympathetic dominance
            dfaAlpha1: 1.3, // Elevated (fatigue)
            isConsolidated: false
        )

        let result = scorer.computeScore(from: metrics)

        XCTAssertLessThan(result.score, 40.0, "Poor metrics should produce score < 40")
        XCTAssertTrue(
            result.status == .incompleteRecovery ||
                result.status == .significantStress ||
                result.status == .recoveryNeeded
        )
    }

    func testModerateMetricsProduceMidRangeScore() {
        // base=50, rmssd 25 → reduced(+10), stress 250 → elevated(+0),
        // lfHf 3.5 → highSympathetic(-10), alpha1 1.2 → elevated(+0) = 50
        let metrics = DiagnosticMetrics(
            rmssd: 25.0, // Reduced
            stressIndex: 250.0, // Elevated stress
            lfHfRatio: 3.5, // High sympathetic
            dfaAlpha1: 1.2, // Elevated
            isConsolidated: true
        )

        let result = scorer.computeScore(from: metrics)

        XCTAssertGreaterThanOrEqual(result.score, 30.0)
        XCTAssertLessThan(result.score, 70.0)
    }

    // MARK: - RMSSD Contribution Tests

    func testHighRMSSDIncreasesScore() {
        let lowRMSSD = DiagnosticMetrics(rmssd: 20.0)
        let highRMSSD = DiagnosticMetrics(rmssd: 60.0)

        let lowResult = scorer.computeScore(from: lowRMSSD)
        let highResult = scorer.computeScore(from: highRMSSD)

        XCTAssertGreaterThan(highResult.score, lowResult.score, "Higher RMSSD should produce higher score")
    }

    func testRMSSDThresholdBoundaries() {
        // Test each RMSSD threshold boundary
        let excellent = DiagnosticMetrics(rmssd: 60.0)
        let good = DiagnosticMetrics(rmssd: 45.0)
        let moderate = DiagnosticMetrics(rmssd: 30.0)
        let reduced = DiagnosticMetrics(rmssd: 20.0)
        let low = DiagnosticMetrics(rmssd: 15.0)

        let excellentScore = scorer.computeScore(from: excellent).score
        let goodScore = scorer.computeScore(from: good).score
        let moderateScore = scorer.computeScore(from: moderate).score
        let reducedScore = scorer.computeScore(from: reduced).score
        let lowScore = scorer.computeScore(from: low).score

        XCTAssertGreaterThan(excellentScore, goodScore)
        XCTAssertGreaterThan(goodScore, moderateScore)
        XCTAssertGreaterThan(moderateScore, reducedScore)
        XCTAssertGreaterThan(reducedScore, lowScore)
    }

    // MARK: - Stress Index Contribution Tests

    func testLowStressIncreasesScore() {
        let highStress = DiagnosticMetrics(rmssd: 40.0, stressIndex: 350.0)
        let lowStress = DiagnosticMetrics(rmssd: 40.0, stressIndex: 80.0)

        let highStressResult = scorer.computeScore(from: highStress)
        let lowStressResult = scorer.computeScore(from: lowStress)

        XCTAssertGreaterThan(lowStressResult.score, highStressResult.score, "Lower stress should produce higher score")
    }

    func testNilStressIndexDoesNotCrash() {
        let metrics = DiagnosticMetrics(rmssd: 40.0, stressIndex: nil)

        let result = scorer.computeScore(from: metrics)

        XCTAssertGreaterThanOrEqual(result.score, 0)
        XCTAssertLessThanOrEqual(result.score, 100)
    }

    // MARK: - LF/HF Ratio Contribution Tests

    func testOptimalLfHfIncreasesScore() {
        let sympathetic = DiagnosticMetrics(rmssd: 40.0, lfHfRatio: 4.0)
        let optimal = DiagnosticMetrics(rmssd: 40.0, lfHfRatio: 1.2)

        let sympatheticResult = scorer.computeScore(from: sympathetic)
        let optimalResult = scorer.computeScore(from: optimal)

        XCTAssertGreaterThan(optimalResult.score, sympatheticResult.score, "Optimal LF/HF should produce higher score")
    }

    func testParasympatheticDominanceIsPositive() {
        let parasympathetic = DiagnosticMetrics(rmssd: 40.0, lfHfRatio: 0.3)
        let neutral = DiagnosticMetrics(rmssd: 40.0, lfHfRatio: nil)

        let parasympatheticResult = scorer.computeScore(from: parasympathetic)
        let neutralResult = scorer.computeScore(from: neutral)

        // Parasympathetic dominance should add to score (though less than optimal)
        XCTAssertGreaterThanOrEqual(parasympatheticResult.score, neutralResult.score)
    }

    func testNilLfHfRatioDoesNotCrash() {
        let metrics = DiagnosticMetrics(rmssd: 40.0, lfHfRatio: nil)

        let result = scorer.computeScore(from: metrics)

        XCTAssertGreaterThanOrEqual(result.score, 0)
        XCTAssertLessThanOrEqual(result.score, 100)
    }

    // MARK: - DFA Alpha1 Contribution Tests

    func testOptimalAlpha1IncreasesScore() {
        let elevated = DiagnosticMetrics(rmssd: 40.0, dfaAlpha1: 1.3)
        let optimal = DiagnosticMetrics(rmssd: 40.0, dfaAlpha1: 0.85)

        let elevatedResult = scorer.computeScore(from: elevated)
        let optimalResult = scorer.computeScore(from: optimal)

        XCTAssertGreaterThan(optimalResult.score, elevatedResult.score, "Optimal DFA α1 should produce higher score")
    }

    func testNilAlpha1DoesNotCrash() {
        let metrics = DiagnosticMetrics(rmssd: 40.0, dfaAlpha1: nil)

        let result = scorer.computeScore(from: metrics)

        XCTAssertGreaterThanOrEqual(result.score, 0)
        XCTAssertLessThanOrEqual(result.score, 100)
    }

    // MARK: - Score Clamping Tests

    func testScoreIsClampedToMaximum100() {
        // Create metrics that would theoretically exceed 100
        let metrics = DiagnosticMetrics(
            rmssd: 100.0, // Way above excellent
            stressIndex: 10.0, // Extremely low
            lfHfRatio: 1.0, // Perfect
            dfaAlpha1: 0.9, // Optimal
            isConsolidated: true
        )

        let result = scorer.computeScore(from: metrics)

        XCTAssertLessThanOrEqual(result.score, 100.0, "Score should be clamped to 100")
    }

    func testScoreIsClampedToMinimum0() {
        // Create metrics that would theoretically go below 0
        let metrics = DiagnosticMetrics(
            rmssd: 5.0, // Extremely low
            stressIndex: 500.0, // Extremely high
            lfHfRatio: 10.0, // Extreme sympathetic
            dfaAlpha1: 2.0, // Very elevated
            isConsolidated: false
        )

        let result = scorer.computeScore(from: metrics)

        XCTAssertGreaterThanOrEqual(result.score, 0.0, "Score should be clamped to 0")
    }

    // MARK: - Status Determination Tests

    func testWellRecoveredStatus() {
        let metrics = DiagnosticMetrics(
            rmssd: 65.0,
            stressIndex: 80.0,
            lfHfRatio: 1.2,
            dfaAlpha1: 0.85
        )

        let result = scorer.computeScore(from: metrics)

        XCTAssertEqual(result.status, .wellRecovered)
        XCTAssertEqual(result.title, "Well Recovered")
    }

    func testAdequateRecoveryStatus() {
        // Create metrics that produce score in 60-80 range
        let metrics = DiagnosticMetrics(
            rmssd: 45.0,
            stressIndex: 120.0,
            lfHfRatio: 1.5,
            dfaAlpha1: 0.95
        )

        let result = scorer.computeScore(from: metrics)

        // Allow for either adequate or well recovered depending on exact calculation
        XCTAssertTrue(
            result.status == .adequateRecovery || result.status == .wellRecovered,
            "Expected adequate or well recovered, got \(result.status)"
        )
    }

    func testRecoveryNeededStatus() {
        let metrics = DiagnosticMetrics(
            rmssd: 10.0,
            stressIndex: 400.0,
            lfHfRatio: 5.0,
            dfaAlpha1: 1.5
        )

        let result = scorer.computeScore(from: metrics)

        XCTAssertTrue(
            result.status == .recoveryNeeded || result.status == .significantStress,
            "Very poor metrics should indicate recovery needed or significant stress"
        )
    }

    // MARK: - Icon Tests

    func testWellRecoveredHasCheckmarkIcon() {
        let metrics = DiagnosticMetrics(
            rmssd: 65.0,
            stressIndex: 80.0,
            lfHfRatio: 1.2,
            dfaAlpha1: 0.85
        )

        let result = scorer.computeScore(from: metrics)

        XCTAssertEqual(result.icon, "checkmark.circle.fill")
    }

    func testRecoveryNeededHasBedIcon() {
        let metrics = DiagnosticMetrics(
            rmssd: 10.0,
            stressIndex: 400.0,
            lfHfRatio: 5.0,
            dfaAlpha1: 1.5
        )

        let result = scorer.computeScore(from: metrics)

        // Could be bed or warning depending on exact score
        XCTAssertTrue(
            result.icon == "bed.double.fill" || result.icon == "exclamationmark.triangle.fill",
            "Poor metrics should show bed or warning icon"
        )
    }

    // MARK: - Custom Configuration Tests

    func testCustomConfigurationIsUsed() {
        let customConfig = DiagnosticScoringConfig(
            baseScore: 70.0, // Higher base
            rmssdScores: DiagnosticScoringConfig.RMSSDScores(
                excellent: 20, good: 15, moderate: 10, reduced: 5, low: 0
            ),
            stressScores: DiagnosticScoringConfig.StressScores(
                veryLow: 10, low: 8, moderate: 5, elevated: 0, high: -5
            ),
            lfHfScores: DiagnosticScoringConfig.LFHFScores(
                optimal: 10, parasympathetic: 8, mildSympathetic: 3, highSympathetic: -5
            ),
            dfaScores: DiagnosticScoringConfig.DFAScores(
                optimal: 10, acceptable: 5, elevated: 0
            )
        )

        let customScorer = DiagnosticScorer(config: customConfig)
        let defaultScorer = DiagnosticScorer()

        let metrics = DiagnosticMetrics(rmssd: 40.0)

        let customResult = customScorer.computeScore(from: metrics)
        let defaultResult = defaultScorer.computeScore(from: metrics)

        // Custom config has higher base score, so results should differ
        XCTAssertNotEqual(customResult.score, defaultResult.score)
    }

    // MARK: - Edge Case Tests

    func testZeroRMSSDHandled() {
        let metrics = DiagnosticMetrics(rmssd: 0.0)

        let result = scorer.computeScore(from: metrics)

        XCTAssertGreaterThanOrEqual(result.score, 0)
        XCTAssertLessThanOrEqual(result.score, 100)
    }

    func testNegativeRMSSDHandled() {
        // Shouldn't happen in practice, but shouldn't crash
        let metrics = DiagnosticMetrics(rmssd: -10.0)

        let result = scorer.computeScore(from: metrics)

        XCTAssertGreaterThanOrEqual(result.score, 0)
        XCTAssertLessThanOrEqual(result.score, 100)
    }

    func testExtremeValuesHandled() {
        let metrics = DiagnosticMetrics(
            rmssd: 1000.0, // Unrealistic but shouldn't crash
            stressIndex: 0.0,
            lfHfRatio: 0.0,
            dfaAlpha1: 0.0
        )

        let result = scorer.computeScore(from: metrics)

        XCTAssertGreaterThanOrEqual(result.score, 0)
        XCTAssertLessThanOrEqual(result.score, 100)
    }
}
