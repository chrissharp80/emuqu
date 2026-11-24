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

    /// The documented population window, 12–18 br/min (whitepaper 01).
    private let popMin = 12.0
    private let popMax = 18.0

    // MARK: - respiratoryPopulationScore(rate:)

    func testRateInsideWindowScoresFull() {
        XCTAssertEqual(VitalsScoring.respiratoryPopulationScore(rate: 15), 100, accuracy: 0.0001)
        XCTAssertEqual(VitalsScoring.respiratoryPopulationScore(rate: popMin), 100, accuracy: 0.0001)
        XCTAssertEqual(VitalsScoring.respiratoryPopulationScore(rate: popMax), 100, accuracy: 0.0001)
    }

    func testRateAboveWindowScoresGradedPenalty() {
        // The documented penalty is 15 points per br/min above the band
        // (whitepaper 01, constants table): 2 br/min above popMax → 100 − 30 = 70.
        XCTAssertEqual(VitalsScoring.respiratoryPopulationScore(rate: popMax + 2), 70, accuracy: 0.0001)
    }

    func testRateFarAboveWindowFloorsAtZero() {
        XCTAssertEqual(VitalsScoring.respiratoryPopulationScore(rate: popMax + 100), 0, accuracy: 0.0001)
    }

    func testRateBelowWindowScoresBelowPopulationConstant() {
        // Below the window the documented score is a flat 90 (whitepaper 01).
        XCTAssertEqual(VitalsScoring.respiratoryPopulationScore(rate: popMin - 3), 90, accuracy: 0.0001)
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
        let score = try XCTUnwrap(VitalsScoring.calculateVitalsScore(vitals: vitals, baselineStats: nil))
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
        let score = try XCTUnwrap(VitalsScoring.calculateVitalsScore(vitals: vitals, baselineStats: nil))
        XCTAssertEqual(score, VitalsScoring.respiratoryPopulationScore(rate: rate), accuracy: 0.0001)
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
        let score = try XCTUnwrap(VitalsScoring.calculateVitalsScore(vitals: vitals, baselineStats: nil))
        // 20 is outside the population window (>18); if the fallback had been
        // used it would NOT be 100. Asserting 100 proves the deviation branch ran.
        XCTAssertEqual(score, 100, accuracy: 0.0001)
    }
}
