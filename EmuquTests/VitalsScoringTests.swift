@testable import Emuqu
import XCTest

/// Tests for the Vitals factor of the recovery score — resting HR against the
/// user's own baseline, wrist-temperature deviation bands, how the sub-scores
/// combine, and the SpO2 override.
///
/// The respiratory path is covered by `RecoveryScoreVitalsFallbackTests`; the
/// rest of the factor had no test, and it is 15% of the composite score the
/// whole app is built around.
final class VitalsScoringTests: XCTestCase {
    private func vitals(
        respiratoryRate: Double? = nil,
        respiratoryRateBaseline: Double? = nil,
        oxygenSaturation: Double? = nil,
        wristTemperature: Double? = nil,
        restingHeartRate: Double? = nil
    ) -> RecoveryVitals {
        RecoveryVitals(
            respiratoryRate: respiratoryRate,
            respiratoryRateBaseline: respiratoryRateBaseline,
            oxygenSaturation: oxygenSaturation,
            oxygenSaturationMin: nil,
            wristTemperature: wristTemperature,
            wristTemperatureBaseline: nil,
            restingHeartRate: restingHeartRate
        )
    }

    /// Baseline 58 bpm, SD 3 — so +3 bpm is exactly one standard deviation.
    private var baseline: BaselineTracker.RecoveryBaselineStats {
        BaselineTracker.RecoveryBaselineStats(
            lnRmssdMean: log(40.0), lnRmssdSD: 0.3, lnRmssdCV7Day: 6.0,
            meanHRBaseline: 58.0, meanHRSD: 3.0, daysInWindow: 30
        )
    }

    // MARK: - No inputs

    /// No vitals at all is "no data", not a zero. A zero would drag the
    /// composite down as if the user were unwell.
    func testNoVitalsYieldsNoScoreRatherThanZero() {
        XCTAssertNil(VitalsScoring.calculateVitalsScore(vitals: nil, baselineStats: baseline))
    }

    /// Every field nil is the same situation: nothing to average.
    func testVitalsWithNoUsableFieldYieldsNoScore() {
        XCTAssertNil(VitalsScoring.calculateVitalsScore(vitals: vitals(), baselineStats: baseline))
    }

    // MARK: - Resting heart rate

    /// Resting HR only means something against the user's own history. With no
    /// baseline there is no honest way to score it, so it contributes nothing
    /// rather than being scored against a population guess.
    func testRestingHeartRateWithoutABaselineContributesNothing() {
        XCTAssertNil(VitalsScoring.calculateVitalsScore(
            vitals: vitals(restingHeartRate: 58), baselineStats: nil
        ))
    }

    func testRestingHeartRateAtBaselineScoresFull() throws {
        let score = try XCTUnwrap(VitalsScoring.calculateVitalsScore(
            vitals: vitals(restingHeartRate: 58), baselineStats: baseline
        ))
        XCTAssertEqual(score, 100, accuracy: 0.0001)
    }

    /// One SD above baseline costs `rhrPenaltyPerSD`.
    func testOneStandardDeviationAboveBaselineCostsTheDocumentedPenalty() throws {
        let score = try XCTUnwrap(VitalsScoring.calculateVitalsScore(
            vitals: vitals(restingHeartRate: 61), baselineStats: baseline
        ))
        XCTAssertEqual(score, 100 - ScoringWeights.Vitals.rhrPenaltyPerSD, accuracy: 0.0001)
    }

    /// The penalty is one-sided. A resting HR BELOW baseline is a good sign,
    /// or at worst neutral — it must never be scored as a deficit, which a
    /// symmetric absolute-deviation would do.
    func testRestingHeartRateBelowBaselineIsNotPenalised() throws {
        let score = try XCTUnwrap(VitalsScoring.calculateVitalsScore(
            vitals: vitals(restingHeartRate: 50), baselineStats: baseline
        ))
        XCTAssertEqual(score, 100, accuracy: 0.0001)
    }

    /// An extreme reading floors at zero rather than going negative and
    /// dragging the average below what any other sub-score can lift.
    func testAnExtremeRestingHeartRateFloorsAtZero() throws {
        let score = try XCTUnwrap(VitalsScoring.calculateVitalsScore(
            vitals: vitals(restingHeartRate: 120), baselineStats: baseline
        ))
        XCTAssertEqual(score, 0, accuracy: 0.0001)
    }

    /// A zero-SD baseline (every night identical, or too few samples) would
    /// divide by zero. It contributes nothing instead.
    func testAZeroStandardDeviationBaselineIsNotUsed() {
        let degenerate = BaselineTracker.RecoveryBaselineStats(
            lnRmssdMean: log(40.0), lnRmssdSD: 0.3, lnRmssdCV7Day: nil,
            meanHRBaseline: 58.0, meanHRSD: 0, daysInWindow: 30
        )
        XCTAssertNil(VitalsScoring.calculateVitalsScore(
            vitals: vitals(restingHeartRate: 70), baselineStats: degenerate
        ))
    }

    // MARK: - Wrist temperature

    /// Wrist temperature arrives as a deviation, and the bands are asymmetric:
    /// a rise signals illness or inflammation, a dip does not.
    func testTemperatureWithinTheNormalBandScoresFull() throws {
        for deviation in [0.0, 0.1, ScoringWeights.Vitals.temperatureBandNormalCelsius] {
            let score = try XCTUnwrap(VitalsScoring.calculateVitalsScore(
                vitals: vitals(wristTemperature: deviation), baselineStats: nil
            ))
            XCTAssertEqual(score, 100, accuracy: 0.0001, "deviation \(deviation)")
        }
    }

    func testTemperatureBandsStepDownAtTheirDocumentedEdges() throws {
        func score(_ deviation: Double) throws -> Double {
            try XCTUnwrap(VitalsScoring.calculateVitalsScore(
                vitals: vitals(wristTemperature: deviation), baselineStats: nil
            ))
        }
        XCTAssertEqual(try score(0.4), ScoringWeights.Vitals.temperatureScoreMild, accuracy: 0.0001)
        XCTAssertEqual(try score(ScoringWeights.Vitals.temperatureBandMildCelsius),
                       ScoringWeights.Vitals.temperatureScoreMild, accuracy: 0.0001)
        XCTAssertEqual(try score(0.8), ScoringWeights.Vitals.temperatureScoreModerate, accuracy: 0.0001)
        XCTAssertEqual(try score(ScoringWeights.Vitals.temperatureBandModerateCelsius),
                       ScoringWeights.Vitals.temperatureScoreModerate, accuracy: 0.0001)
        XCTAssertEqual(try score(1.5), ScoringWeights.Vitals.temperatureScoreSevere, accuracy: 0.0001)
    }

    /// Bands never invert: hotter is never scored better.
    func testTemperatureScoreIsMonotonicallyWorseAsDeviationRises() throws {
        var previous = 101.0
        for deviation in stride(from: 0.0, through: 2.0, by: 0.1) {
            let score = try XCTUnwrap(VitalsScoring.calculateVitalsScore(
                vitals: vitals(wristTemperature: deviation), baselineStats: nil
            ))
            XCTAssertLessThanOrEqual(score, previous, "deviation \(deviation) scored higher than the one below it")
            previous = score
        }
    }

    /// A temperature BELOW baseline is clamped to zero deviation, so a cold
    /// night reads as normal rather than as a penalty.
    func testATemperatureBelowBaselineScoresAsNormal() throws {
        let score = try XCTUnwrap(VitalsScoring.calculateVitalsScore(
            vitals: vitals(wristTemperature: -0.9), baselineStats: nil
        ))
        XCTAssertEqual(score, 100, accuracy: 0.0001)
    }

    // MARK: - Combining sub-scores

    /// The factor is the plain mean of whichever sub-scores are available —
    /// the property the score-breakdown UI promises is reconstructable.
    func testTheFactorIsTheMeanOfTheAvailableSubScores() throws {
        // RHR one SD high (90), temperature severe (25), RR inside the
        // population window (100).
        let score = try XCTUnwrap(VitalsScoring.calculateVitalsScore(
            vitals: vitals(respiratoryRate: 15, wristTemperature: 1.5, restingHeartRate: 61),
            baselineStats: baseline
        ))
        let expected = ((100 - ScoringWeights.Vitals.rhrPenaltyPerSD)
            + 100
            + ScoringWeights.Vitals.temperatureScoreSevere) / 3
        XCTAssertEqual(score, expected, accuracy: 0.0001)
    }

    /// A missing input is left out of the mean, not counted as zero — that is
    /// what lets a user with only one working sensor still get a real score.
    func testAMissingInputIsExcludedRatherThanCountedAsZero() throws {
        let onlyTemperature = try XCTUnwrap(VitalsScoring.calculateVitalsScore(
            vitals: vitals(wristTemperature: 1.5), baselineStats: baseline
        ))
        XCTAssertEqual(onlyTemperature, ScoringWeights.Vitals.temperatureScoreSevere, accuracy: 0.0001)
    }

    // MARK: - SpO2 override

    /// SpO2 is a flag, not a factor: one threshold, applied after the
    /// composite rather than blended into it.
    func testLowBloodOxygenAppliesTheDocumentedPenalty() {
        let adjusted = VitalsScoring.applyVitalsOverrides(
            score: 80, vitals: vitals(oxygenSaturation: 92)
        )
        XCTAssertEqual(adjusted, 80 - RecoveryScoreConstants.Vitals.spo2Penalty, accuracy: 0.0001)
    }

    func testNormalBloodOxygenLeavesTheScoreAlone() {
        XCTAssertEqual(
            VitalsScoring.applyVitalsOverrides(score: 80, vitals: vitals(oxygenSaturation: 97)),
            80, accuracy: 0.0001
        )
    }

    func testNoVitalsLeavesTheScoreAlone() {
        XCTAssertEqual(VitalsScoring.applyVitalsOverrides(score: 80, vitals: nil), 80, accuracy: 0.0001)
    }

    /// The penalty must not push a already-low score negative.
    func testTheOverrideCannotProduceANegativeScore() {
        let adjusted = VitalsScoring.applyVitalsOverrides(
            score: 3, vitals: vitals(oxygenSaturation: 88)
        )
        XCTAssertEqual(adjusted, 0, accuracy: 0.0001)
    }

    /// What the user is told must match what was applied.
    func testThePenaltyDescriptionAppearsExactlyWhenThePenaltyDoes() {
        XCTAssertTrue(VitalsScoring.vitalsPenaltyDescriptions(vitals(oxygenSaturation: 92)).count == 1)
        XCTAssertTrue(VitalsScoring.vitalsPenaltyDescriptions(vitals(oxygenSaturation: 97)).isEmpty)
        XCTAssertTrue(VitalsScoring.vitalsPenaltyDescriptions(nil).isEmpty)
    }
}
