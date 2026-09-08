@testable import Emuqu
import XCTest

/// Tests for HRVThresholds configuration values
/// Validates that thresholds are physiologically reasonable and consistent
final class HRVThresholdsTests: XCTestCase {
    // MARK: - RR Interval Validity Tests

    func testRRIntervalBoundsArePhysiologicallyValid() {
        // 300ms = 200 bpm (max reasonable HR)
        XCTAssertEqual(HRVThresholds.minimumRRIntervalMs, 300)
        // 2000ms = 30 bpm (min reasonable HR for sleeping adult)
        XCTAssertEqual(HRVThresholds.maximumRRIntervalMs, 2000)

        // Sanity check: min < max
        XCTAssertLessThan(HRVThresholds.minimumRRIntervalMs, HRVThresholds.maximumRRIntervalMs)
    }

    // MARK: - RMSSD Threshold Tests

    func testRMSSDThresholdsAreOrdered() {
        // Thresholds should be in descending order
        XCTAssertGreaterThan(HRVThresholds.rmssdExcellent, HRVThresholds.rmssdGood)
        XCTAssertGreaterThan(HRVThresholds.rmssdGood, HRVThresholds.rmssdReduced)
        XCTAssertGreaterThan(HRVThresholds.rmssdReduced, HRVThresholds.rmssdLow)
    }

    func testRMSSDThresholdsArePositive() {
        XCTAssertGreaterThan(HRVThresholds.rmssdExcellent, 0)
        XCTAssertGreaterThan(HRVThresholds.rmssdGood, 0)
        XCTAssertGreaterThan(HRVThresholds.rmssdReduced, 0)
        XCTAssertGreaterThan(HRVThresholds.rmssdLow, 0)
    }

    func testRMSSDThresholdsMatchResearchRanges() {
        // Research-based: excellent HRV is typically >50ms
        XCTAssertGreaterThanOrEqual(HRVThresholds.rmssdExcellent, 50.0)
        // Low HRV is typically <20ms
        XCTAssertLessThanOrEqual(HRVThresholds.rmssdLow, 20.0)
    }

    // MARK: - Diagnostic Score Threshold Tests

    func testDiagnosticScoreThresholdsAreOrdered() {
        XCTAssertGreaterThan(HRVThresholds.scoreWellRecovered, HRVThresholds.scoreAdequateRecovery)
        XCTAssertGreaterThan(HRVThresholds.scoreAdequateRecovery, HRVThresholds.scoreIncompleteRecovery)
        XCTAssertGreaterThan(HRVThresholds.scoreIncompleteRecovery, HRVThresholds.scoreSignificantStress)
    }

    func testDiagnosticScoreThresholdsAreWithinValidRange() {
        // Scores should be 0-100
        XCTAssertGreaterThanOrEqual(HRVThresholds.scoreWellRecovered, 0)
        XCTAssertLessThanOrEqual(HRVThresholds.scoreWellRecovered, 100)
        XCTAssertGreaterThanOrEqual(HRVThresholds.scoreSignificantStress, 0)
        XCTAssertLessThanOrEqual(HRVThresholds.scoreSignificantStress, 100)
    }

    // MARK: - Stress Index Threshold Tests

    func testStressIndexThresholdsAreOrdered() {
        XCTAssertLessThan(HRVThresholds.stressIndexLow, HRVThresholds.stressIndexNormal)
        XCTAssertLessThan(HRVThresholds.stressIndexNormal, HRVThresholds.stressIndexElevated)
        XCTAssertLessThan(HRVThresholds.stressIndexElevated, HRVThresholds.stressIndexHigh)
    }

    func testStressIndexThresholdsArePositive() {
        XCTAssertGreaterThan(HRVThresholds.stressIndexLow, 0)
        XCTAssertGreaterThan(HRVThresholds.stressIndexHigh, 0)
    }

    // MARK: - LF/HF Ratio Threshold Tests

    func testLfHfRatioThresholdsAreOrdered() {
        XCTAssertLessThan(HRVThresholds.lfHfParasympatheticDominance, HRVThresholds.lfHfBalancedLower)
        XCTAssertLessThan(HRVThresholds.lfHfBalancedLower, HRVThresholds.lfHfBalancedUpper)
        XCTAssertLessThan(HRVThresholds.lfHfBalancedUpper, HRVThresholds.lfHfOptimalUpper)
        XCTAssertLessThanOrEqual(HRVThresholds.lfHfOptimalUpper, HRVThresholds.lfHfModerateSympatheticUpper)
    }

    func testLfHfRatioThresholdsArePositive() {
        XCTAssertGreaterThan(HRVThresholds.lfHfParasympatheticDominance, 0)
        XCTAssertGreaterThan(HRVThresholds.lfHfSympatheticDominance, 0)
    }

    // MARK: - DFA Alpha1 Threshold Tests

    func testDfaAlpha1OptimalRangeIsValid() {
        // Optimal range should be 0.75-1.0 (research-based)
        XCTAssertEqual(HRVThresholds.dfaAlpha1OptimalLower, 0.75)
        XCTAssertEqual(HRVThresholds.dfaAlpha1OptimalUpper, 1.0)
        XCTAssertLessThan(HRVThresholds.dfaAlpha1OptimalLower, HRVThresholds.dfaAlpha1OptimalUpper)
    }

    func testDfaAlpha1ThresholdsAreOrdered() {
        XCTAssertLessThan(HRVThresholds.dfaAlpha1FlexibleLower, HRVThresholds.dfaAlpha1OptimalLower)
        XCTAssertLessThan(HRVThresholds.dfaAlpha1OptimalUpper, HRVThresholds.dfaAlpha1HighVariability)
        XCTAssertLessThanOrEqual(HRVThresholds.dfaAlpha1HighVariability, HRVThresholds.dfaAlpha1Fatigue)
    }

    // MARK: - Sleep Threshold Tests

    func testSleepDurationThresholdsAreOrdered() {
        XCTAssertLessThan(HRVThresholds.sleepShortMinutes, HRVThresholds.sleepVeryShortMinutes)
        XCTAssertLessThan(HRVThresholds.sleepVeryShortMinutes, HRVThresholds.sleepMinimumMinutes)
    }

    func testSleepDurationThresholdsAreReasonable() {
        // 7 hours = 420 minutes minimum recommended
        XCTAssertEqual(HRVThresholds.sleepMinimumMinutes, 420)
        // 5 hours = 300 minutes short sleep
        XCTAssertEqual(HRVThresholds.sleepShortMinutes, 300)
    }

    func testSleepEfficiencyThresholdsAreOrdered() {
        XCTAssertGreaterThan(HRVThresholds.sleepEfficiencyGood, HRVThresholds.sleepEfficiencyAcceptable)
        XCTAssertGreaterThan(HRVThresholds.sleepEfficiencyAcceptable, HRVThresholds.sleepEfficiencyLow)
    }

    func testSleepEfficiencyThresholdsAreValidPercentages() {
        XCTAssertGreaterThanOrEqual(HRVThresholds.sleepEfficiencyGood, 0)
        XCTAssertLessThanOrEqual(HRVThresholds.sleepEfficiencyGood, 100)
        XCTAssertGreaterThanOrEqual(HRVThresholds.sleepEfficiencyLow, 0)
        XCTAssertLessThanOrEqual(HRVThresholds.sleepEfficiencyLow, 100)
    }

    // MARK: - Window Selection Threshold Tests

    func testWindowPositionThresholdsAreValid() {
        // Window should be in 30-70% of sleep
        XCTAssertEqual(HRVThresholds.windowPositionStart, 0.30)
        XCTAssertEqual(HRVThresholds.windowPositionEnd, 0.70)
        XCTAssertLessThan(HRVThresholds.windowPositionStart, HRVThresholds.windowPositionEnd)
    }

    func testWindowBeatThresholdsAreReasonable() {
        XCTAssertGreaterThan(HRVThresholds.windowTargetBeats, HRVThresholds.windowMinimumBeats)
        XCTAssertGreaterThanOrEqual(HRVThresholds.windowMinimumBeats, 60) // At least 1 minute of data
    }

    func testWindowCVThresholdIsReasonable() {
        // 8% CV is the threshold for HR stability
        XCTAssertEqual(HRVThresholds.windowUnstableCVThreshold, 0.08)
        XCTAssertGreaterThan(HRVThresholds.windowUnstableCVThreshold, 0)
        XCTAssertLessThan(HRVThresholds.windowUnstableCVThreshold, 1.0)
    }

    // MARK: - Artifact Threshold Tests

    func testArtifactRateThresholdsAreOrdered() {
        XCTAssertLessThan(HRVThresholds.warnArtifactRate, HRVThresholds.maxArtifactRate)
    }

    func testArtifactRateThresholdsAreValidPercentages() {
        XCTAssertGreaterThanOrEqual(HRVThresholds.maxArtifactRate, 0)
        XCTAssertLessThanOrEqual(HRVThresholds.maxArtifactRate, 1.0)
        XCTAssertGreaterThanOrEqual(HRVThresholds.warnArtifactRate, 0)
        XCTAssertLessThanOrEqual(HRVThresholds.warnArtifactRate, 1.0)
    }

    // MARK: - Illness Detection Threshold Tests

    func testIllnessThresholdsAreNegative() {
        // HRV drops are negative percentages
        XCTAssertLessThan(HRVThresholds.illnessSevereHRVCrash, 0)
        XCTAssertLessThan(HRVThresholds.illnessMajorHRVDrop, 0)
    }

    func testIllnessThresholdsAreOrdered() {
        // Severe crash is a bigger drop than major drop
        XCTAssertLessThan(HRVThresholds.illnessSevereHRVCrash, HRVThresholds.illnessMajorHRVDrop)
    }

    // MARK: - Diagnostic Scoring Config Tests

    func testDefaultDiagnosticScoringConfigExists() {
        let config = DiagnosticScoringConfig.default
        XCTAssertEqual(config.baseScore, 50.0)
    }

    func testDiagnosticScoringConfigRMSSDScoresAreOrdered() {
        let scores = DiagnosticScoringConfig.default.rmssdScores
        XCTAssertGreaterThan(scores.excellent, scores.good)
        XCTAssertGreaterThan(scores.good, scores.moderate)
        XCTAssertGreaterThan(scores.moderate, scores.reduced)
        XCTAssertGreaterThan(scores.reduced, scores.low)
    }

    func testDiagnosticScoringConfigStressScoresAreOrdered() {
        let scores = DiagnosticScoringConfig.default.stressScores
        XCTAssertGreaterThan(scores.veryLow, scores.low)
        XCTAssertGreaterThan(scores.low, scores.moderate)
        XCTAssertGreaterThan(scores.moderate, scores.elevated)
        XCTAssertGreaterThan(scores.elevated, scores.high)
    }
}
