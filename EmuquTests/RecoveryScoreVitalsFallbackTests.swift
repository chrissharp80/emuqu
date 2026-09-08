@testable import Emuqu
import XCTest

/// Coverage for the respiratory population-window fallback in the Vitals
/// sub-score. `respiratoryPopulationScore` is
/// the fallback used when a user has a respiratory rate but no 7-night
/// baseline yet — the common state for the first week of use — and every
/// existing vitals test supplied a baseline (hitting the deviation branch),
/// so the population branch was untested during the exact window when users
/// judge whether the app is trustworthy.
final class RecoveryScoreVitalsFallbackTests: XCTestCase {

    private let popMin = ScoringWeights.Vitals.respiratoryRatePopulationMinBPM // 12
    private let popMax = ScoringWeights.Vitals.respiratoryRatePopulationMaxBPM // 18

    // MARK: - respiratoryPopulationScore(rate:)

    func testRateInsideWindowScoresFull() {
        XCTAssertEqual(RecoveryScoreCalculator.respiratoryPopulationScore(rate: 15), 100, accuracy: 0.0001)
        XCTAssertEqual(RecoveryScoreCalculator.respiratoryPopulationScore(rate: popMin), 100, accuracy: 0.0001)
        XCTAssertEqual(RecoveryScoreCalculator.respiratoryPopulationScore(rate: popMax), 100, accuracy: 0.0001)
    }

    func testRateAboveWindowScoresGradedPenalty() {
        // 2 br/min above popMax at 15 pts/br/min → 100 - 30 = 70.
        let expected = 100 - 2 * ScoringWeights.Vitals.respiratoryRatePenaltyPerBreath
        XCTAssertEqual(RecoveryScoreCalculator.respiratoryPopulationScore(rate: popMax + 2), expected, accuracy: 0.0001)
    }

    func testRateFarAboveWindowFloorsAtZero() {
        XCTAssertEqual(RecoveryScoreCalculator.respiratoryPopulationScore(rate: popMax + 100), 0, accuracy: 0.0001)
    }

    func testRateBelowWindowScoresBelowPopulationConstant() {
        XCTAssertEqual(
            RecoveryScoreCalculator.respiratoryPopulationScore(rate: popMin - 3),
            ScoringWeights.Vitals.respiratoryRateBelowPopulationScore,
            accuracy: 0.0001
        )
    }

    // MARK: - calculateVitalsScore takes the fallback when rate present, baseline absent

    func testVitalsScoreUsesPopulationFallbackWhenBaselineMissing() throws {
        // Rate present, baseline nil → respiratoryDeviation is nil → the
        // `else if let rate` population branch fires. No other vitals, so the
        // vitals factor equals the population score for that rate.
        let vitals = RecoveryVitals(
            respiratoryRate: 15,
            respiratoryRateBaseline: nil,
            oxygenSaturation: nil,
            oxygenSaturationMin: nil,
            wristTemperature: nil,
            wristTemperatureBaseline: nil,
            restingHeartRate: nil
        )
        let score = try XCTUnwrap(RecoveryScoreCalculator.calculateVitalsScore(vitals: vitals, baselineStats: nil))
        XCTAssertEqual(score, 100, accuracy: 0.0001)
    }

    func testVitalsScoreFallbackPenalizesElevatedRate() throws {
        let rate = popMax + 2
        let vitals = RecoveryVitals(
            respiratoryRate: rate,
            respiratoryRateBaseline: nil,
            oxygenSaturation: nil,
            oxygenSaturationMin: nil,
            wristTemperature: nil,
            wristTemperatureBaseline: nil,
            restingHeartRate: nil
        )
        let score = try XCTUnwrap(RecoveryScoreCalculator.calculateVitalsScore(vitals: vitals, baselineStats: nil))
        XCTAssertEqual(score, RecoveryScoreCalculator.respiratoryPopulationScore(rate: rate), accuracy: 0.0001)
    }

    func testVitalsScorePrefersDeviationBranchWhenBaselinePresent() throws {
        // With a baseline, respiratoryDeviation is non-nil, so the deviation
        // branch is taken instead of the population fallback. Rate == baseline
        // → deviation 0 → within band → 100.
        let vitals = RecoveryVitals(
            respiratoryRate: 20,
            respiratoryRateBaseline: 20,
            oxygenSaturation: nil,
            oxygenSaturationMin: nil,
            wristTemperature: nil,
            wristTemperatureBaseline: nil,
            restingHeartRate: nil
        )
        let score = try XCTUnwrap(RecoveryScoreCalculator.calculateVitalsScore(vitals: vitals, baselineStats: nil))
        // 20 is outside the population window (>18); if the fallback had been
        // used it would NOT be 100. Asserting 100 proves the deviation branch ran.
        XCTAssertEqual(score, 100, accuracy: 0.0001)
    }
}
