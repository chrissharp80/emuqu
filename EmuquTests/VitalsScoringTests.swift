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

    /// One SD above baseline costs the documented 10 points per SD
    /// (whitepaper 01, constants table): 100 − 10 = 90.
    func testOneStandardDeviationAboveBaselineCostsTheDocumentedPenalty() throws {
        let score = try XCTUnwrap(VitalsScoring.calculateVitalsScore(
            vitals: vitals(restingHeartRate: 61), baselineStats: baseline
        ))
        XCTAssertEqual(score, 90, accuracy: 0.0001)
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
        // The documented normal band ends at +0.3 °C (whitepaper 01).
        for deviation in [0.0, 0.1, 0.3] {
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
        // Documented bands (whitepaper 01): edges 0.3 / 0.5 / 1.0 °C,
        // scores 100 / 75 / 50 / 25.
        XCTAssertEqual(try score(0.4), 75, accuracy: 0.0001)
        XCTAssertEqual(try score(0.5), 75, accuracy: 0.0001)
        XCTAssertEqual(try score(0.8), 50, accuracy: 0.0001)
        XCTAssertEqual(try score(1.0), 50, accuracy: 0.0001)
        XCTAssertEqual(try score(1.5), 25, accuracy: 0.0001)
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
        // (90 + 100 + 25) / 3 = 71.666…
        XCTAssertEqual(score, 215.0 / 3.0, accuracy: 0.0001)
    }

    /// A missing input is left out of the mean, not counted as zero — that is
    /// what lets a user with only one working sensor still get a real score.
    func testAMissingInputIsExcludedRatherThanCountedAsZero() throws {
        let onlyTemperature = try XCTUnwrap(VitalsScoring.calculateVitalsScore(
            vitals: vitals(wristTemperature: 1.5), baselineStats: baseline
        ))
        XCTAssertEqual(onlyTemperature, 25, accuracy: 0.0001)
    }

    // MARK: - SpO2 override

    /// SpO2 is a flag, not a factor: one threshold, applied after the
    /// composite rather than blended into it.
    func testLowBloodOxygenAppliesTheDocumentedPenalty() {
        let adjusted = VitalsScoring.applyVitalsOverrides(
            score: 80, vitals: vitals(oxygenSaturation: 92)
        )
        // The documented SpO2 penalty is 10 points (user manual): 80 − 10 = 70.
        XCTAssertEqual(adjusted, 70, accuracy: 0.0001)
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

    // MARK: - Wrist temperature against the personal baseline

    private func tempVitals(reading: Double?, baseline: Double?) -> RecoveryVitals {
        RecoveryVitals(
            respiratoryRate: 15, respiratoryRateBaseline: nil, oxygenSaturation: nil, oxygenSaturationMin: nil,
            wristTemperature: reading, wristTemperatureBaseline: baseline, restingHeartRate: nil
        )
    }

    /// The stored reading is an offset from a population 36.5 °C; the
    /// deviation the app shows is tonight minus the user's own baseline.
    func testWristTemperatureDeviationIsTonightMinusBaseline() {
        XCTAssertEqual(tempVitals(reading: -0.4, baseline: -1.2).wristTemperatureDeviation ?? .nan, 0.8, accuracy: 0.0001)
        XCTAssertNil(tempVitals(reading: -0.4, baseline: nil).wristTemperatureDeviation)
    }

    /// A cool sleeper with a fever: raw offset reads normal, the personal
    /// deviation is elevated. Without a baseline nothing is flagged.
    func testTemperatureElevationReadsThePersonalDeviation() {
        XCTAssertTrue(tempVitals(reading: -0.4, baseline: -1.2).isTemperatureElevated)
        XCTAssertFalse(tempVitals(reading: 0.9, baseline: 0.8).isTemperatureElevated)
        XCTAssertFalse(tempVitals(reading: 0.9, baseline: nil).isTemperatureElevated)
    }

    /// Refreshing a frozen Vitals factor scores temperature the way a fresh
    /// score does: against the baseline, not as the raw offset.
    func testRefreshedVitalsFactorScoresTemperatureAgainstBaseline() {
        let frozen = RecoveryScoreCalculator.ScoreBreakdown(
            compositeScore: 70, tier: 3,
            factors: [.init(label: "Vitals", detail: "RR — no data", score: 50, weight: 0.15, impact: .neutral)],
            penalties: []
        )
        // RR 15 with no RR baseline is inside the 12-18 population window:
        // 100. A +0.1 °C deviation is normal: 100. Read as the raw +1.5 °C
        // offset it would be severe (25), giving 62.5.
        let refreshed = VitalsScoring.breakdownRefreshingVitalsFactor(
            frozen, freshVitals: tempVitals(reading: 1.5, baseline: 1.4), baselineStats: nil
        )
        XCTAssertEqual(refreshed.factors.first?.score ?? .nan, 100, accuracy: 0.0001)
        XCTAssertEqual(refreshed.compositeScore, 70, accuracy: 0.0001)
        // A cool sleeper running warm: raw -0.2 °C reads normal (100), but
        // +0.4 °C over the -0.6 °C baseline is mild (75): (100 + 75) / 2.
        let warm = VitalsScoring.breakdownRefreshingVitalsFactor(
            frozen, freshVitals: tempVitals(reading: -0.2, baseline: -0.6), baselineStats: nil
        )
        XCTAssertEqual(warm.factors.first?.score ?? .nan, 87.5, accuracy: 0.0001)
    }

    /// Before, a refreshed Vitals factor raised the factors' sum over the
    /// frozen composite, and the advice said baselines had improved since the
    /// night. The refresh's move is not a gap.
    func testARefreshedVitalsFactorLeavesTheFrozenGapAsItWas() {
        let frozen = RecoveryScoreCalculator.ScoreBreakdown(
            compositeScore: 70, tier: 3,
            factors: [
                .init(label: "HRV", detail: "", score: 70, weight: 0.6, impact: .neutral),
                .init(label: "Sleep", detail: "", score: 70, weight: 0.25, impact: .neutral),
                .init(label: "Vitals", detail: "RR — no data", score: 30, weight: 0.15, impact: .negative)
            ],
            penalties: []
        )
        let refreshed = VitalsScoring.breakdownRefreshingVitalsFactor(
            frozen, freshVitals: tempVitals(reading: 1.5, baseline: 1.4), baselineStats: nil
        )
        XCTAssertNotEqual(refreshed.factors.last?.score ?? .nan, 30, "the test needs the refresh to move the factor")
        XCTAssertEqual(refreshed.gapFromFactors, frozen.gapFromFactors, accuracy: 1e-9)
    }
}
