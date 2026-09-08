@testable import Emuqu
import XCTest

// The vitals, composite, comeback-mode and configuration cases, split out of
// `RecoveryScoreCalculatorTests.swift` when that test class passed
// the 500-line type-body limit. XCTest discovers test methods declared in an
// extension exactly as it does ones in the class body, so the split changes
// which file a case lives in and nothing else.

extension RecoveryScoreCalculatorTests {
    // MARK: - Vitals Overrides Tests

    func testVitalsNilReturnsOriginalScore() {
        let score = RecoveryScoreCalculator.applyVitalsOverrides(score: 75.0, vitals: nil)
        XCTAssertEqual(score, 75.0)
    }

    // MARK: - Composite (calculateWithBreakdown) Tests

    func testTier1OnlyWhenNoSleepOrTraining() {
        let breakdown = RecoveryScoreCalculator.calculateWithBreakdown(
            RecoveryScoreCalculator.ScoreInputs(
                hrvReadiness: nil, rmssd: 40.0, meanHR: 58.0, dfaAlpha1: 0.85, baselineStats: baselineStats,
                sleepData: nil, vitals: nil, typicalSleepHours: 7.5
            ),
            trainingContext: nil,
            config: defaultConfig
        )
        XCTAssertEqual(breakdown.tier, 1)
        XCTAssertEqual(breakdown.factors.count, 1)
        XCTAssertEqual(breakdown.factors.first?.label, "HRV")
    }

    func testTrainingBreakDisablesTrainingScore() {
        let breakConfig = RecoveryScoreCalculator.ScoringConfiguration(
            enableTrainingLoadIntegration: true,
            isOnTrainingBreak: true,
            enableSleepIntegration: false,
            penalizeMissingSleep: false,
            userAge: 40
        )
        let ctx = TrainingContext(atl: 50.0, ctl: 50.0, tsb: -10.0, yesterdayTrimp: 80.0, vo2Max: nil, daysSinceHardWorkout: 2, recentWorkouts: nil)
        let breakdown = RecoveryScoreCalculator.calculateWithBreakdown(
            RecoveryScoreCalculator.ScoreInputs(
                hrvReadiness: nil, rmssd: 40.0, meanHR: 58.0, dfaAlpha1: nil, baselineStats: baselineStats,
                sleepData: nil, vitals: nil, typicalSleepHours: 7.5
            ),
            trainingContext: ctx,
            config: breakConfig
        )
        // Training should be excluded due to training break
        XCTAssertEqual(breakdown.tier, 1)
    }

    func testSleepDisabledYieldsTier1() {
        let noSleepConfig = RecoveryScoreCalculator.ScoringConfiguration(
            enableTrainingLoadIntegration: false,
            isOnTrainingBreak: false,
            enableSleepIntegration: false,
            penalizeMissingSleep: false,
            userAge: 40
        )
        let breakdown = RecoveryScoreCalculator.calculateWithBreakdown(
            RecoveryScoreCalculator.ScoreInputs(
                hrvReadiness: nil, rmssd: 40.0, meanHR: 58.0, dfaAlpha1: nil, baselineStats: baselineStats,
                sleepData: nil, vitals: nil, typicalSleepHours: 7.5
            ),
            trainingContext: nil,
            config: noSleepConfig
        )
        XCTAssertEqual(breakdown.tier, 1)
    }

    func testTier3UsesDocumentedFactorWeights() {
        // Tier 3 is HRV+Sleep+Vitals (60/25/15), not
        // HRV+Sleep+Training (50/20/30).
        // Training load is not part of the recovery composite —
        // it lives on the Load & Trajectory surface and is shown but
        // not scored. See ScoringWeights doc-comment for the rationale
        // (Impellizzeri 2020/2021, Doherty/Altini 2025).
        let sleep = makeSleepData(
            totalSleepMinutes: 440,
            inBedMinutes: 470,
            deepSleepMinutes: 75,
            remSleepMinutes: 95,
            awakeMinutes: 30,
            sleepEfficiency: 93.6
        )
        let vitals = RecoveryVitals(
            respiratoryRate: 14.5,
            respiratoryRateBaseline: 14.5,
            oxygenSaturation: 97.0,
            oxygenSaturationMin: 96.0,
            wristTemperature: 0.1, // within ±0.3°C
            wristTemperatureBaseline: 0.0,
            restingHeartRate: 57.0 // at baseline (meanHRBaseline=58 in helper)
        )
        let breakdown = RecoveryScoreCalculator.calculateWithBreakdown(
            RecoveryScoreCalculator.ScoreInputs(
                hrvReadiness: nil, rmssd: 44.0, meanHR: 57.0, dfaAlpha1: 0.85, baselineStats: baselineStats,
                sleepData: sleep, vitals: vitals, typicalSleepHours: 7.5
            ),
            trainingContext: nil,
            config: defaultConfig
        )

        XCTAssertEqual(breakdown.tier, 3)
        let byLabel = Dictionary(uniqueKeysWithValues: breakdown.factors.map { ($0.label, $0) })
        XCTAssertEqual(byLabel["HRV"]?.weight ?? -1.0, 0.60, accuracy: 0.0001)
        XCTAssertEqual(byLabel["Sleep"]?.weight ?? -1.0, 0.25, accuracy: 0.0001)
        XCTAssertEqual(byLabel["Vitals"]?.weight ?? -1.0, 0.15, accuracy: 0.0001)
        XCTAssertNil(byLabel["Training Load"], "Training Load is no longer a recovery-score factor")

        let contributionSum = breakdown.factors.reduce(0.0) { $0 + $1.contribution }
        XCTAssertEqual(
            breakdown.compositeScore,
            contributionSum,
            accuracy: 0.0001,
            "Tier 3 composite should equal weighted factor contributions when no vitals penalties apply"
        )
    }

    func testTier3VitalsScoreContributesAtFifteenPercent() {
        // Sanity check: the Vitals factor's score field × its 0.15 weight
        // produces the right contribution to the composite. Catches any
        // change that lands the weight at 0.30 instead.
        let sleep = makeSleepData(
            totalSleepMinutes: 440, inBedMinutes: 470,
            deepSleepMinutes: 75, remSleepMinutes: 95,
            awakeMinutes: 30, sleepEfficiency: 93.6
        )
        // Elevated RR → vitals sub-score drops noticeably
        let vitals = RecoveryVitals(
            respiratoryRate: 17.5,
            respiratoryRateBaseline: 14.5, // +3 br/min above baseline
            oxygenSaturation: 97.0, oxygenSaturationMin: 96.0,
            wristTemperature: 0.1, wristTemperatureBaseline: 0.0,
            restingHeartRate: 58.0
        )
        let breakdown = RecoveryScoreCalculator.calculateWithBreakdown(
            RecoveryScoreCalculator.ScoreInputs(
                hrvReadiness: nil, rmssd: 44.0, meanHR: 57.0, dfaAlpha1: 0.85, baselineStats: baselineStats,
                sleepData: sleep, vitals: vitals, typicalSleepHours: 7.5
            ),
            trainingContext: nil,
            config: defaultConfig
        )
        let byLabel = Dictionary(uniqueKeysWithValues: breakdown.factors.map { ($0.label, $0) })
        let vitalsFactor = try? XCTUnwrap(byLabel["Vitals"])
        XCTAssertNotNil(vitalsFactor)
        XCTAssertEqual(vitalsFactor?.weight ?? 0, 0.15, accuracy: 0.0001)
        // Vitals sub-score with +3 br/min RR (penalty 15·(3-1) = 30) and
        // RHR/temp at baseline (100 each) averages to (70+100+100)/3 ≈ 90.
        XCTAssertEqual(vitalsFactor?.score ?? -1, 90, accuracy: 1.0)
    }

    func testTier2WhenVitalsAreAbsent() {
        // Without vitals data, the composite falls back to Tier 2 (HRV+Sleep).
        let sleep = makeSleepData(
            totalSleepMinutes: 440, inBedMinutes: 470,
            deepSleepMinutes: 75, remSleepMinutes: 95,
            awakeMinutes: 30, sleepEfficiency: 93.6
        )
        let breakdown = RecoveryScoreCalculator.calculateWithBreakdown(
            RecoveryScoreCalculator.ScoreInputs(
                hrvReadiness: nil, rmssd: 44.0, meanHR: 57.0, dfaAlpha1: 0.85, baselineStats: baselineStats,
                sleepData: sleep, vitals: nil, typicalSleepHours: 7.5
            ),
            trainingContext: nil,
            config: defaultConfig
        )
        XCTAssertEqual(breakdown.tier, 2)
        let labels = Set(breakdown.factors.map(\.label))
        XCTAssertEqual(labels, ["HRV", "Sleep"])
    }

    func testComebackModeShiftsWeightsTo80_20_0() {
        // Comeback mode: HRV 80 / Sleep 20 / Vitals 0. Vitals factor still
        // surfaces in the breakdown for visibility, but at weight 0 so it
        // doesn't contribute to the composite.
        let sleep = makeSleepData(
            totalSleepMinutes: 440, inBedMinutes: 470,
            deepSleepMinutes: 75, remSleepMinutes: 95,
            awakeMinutes: 30, sleepEfficiency: 93.6
        )
        let vitals = RecoveryVitals(
            respiratoryRate: 14.5, respiratoryRateBaseline: 14.5,
            oxygenSaturation: 97.0, oxygenSaturationMin: 96.0,
            wristTemperature: 0.1, wristTemperatureBaseline: 0.0,
            restingHeartRate: 57.0
        )
        let comebackConfig = RecoveryScoreCalculator.ScoringConfiguration(
            enableTrainingLoadIntegration: true,
            isOnTrainingBreak: false,
            enableSleepIntegration: true,
            penalizeMissingSleep: false,
            userAge: 40,
            isComebackModeActive: true
        )
        let breakdown = RecoveryScoreCalculator.calculateWithBreakdown(
            RecoveryScoreCalculator.ScoreInputs(
                hrvReadiness: nil, rmssd: 44.0, meanHR: 57.0, dfaAlpha1: 0.85, baselineStats: baselineStats,
                sleepData: sleep, vitals: vitals, typicalSleepHours: 7.5
            ),
            trainingContext: nil,
            config: comebackConfig
        )
        let byLabel = Dictionary(uniqueKeysWithValues: breakdown.factors.map { ($0.label, $0) })
        XCTAssertEqual(byLabel["HRV"]?.weight ?? -1.0, 0.80, accuracy: 0.0001)
        XCTAssertEqual(byLabel["Sleep"]?.weight ?? -1.0, 0.20, accuracy: 0.0001)
        XCTAssertEqual(byLabel["Vitals"]?.weight ?? -1.0, 0.0, accuracy: 0.0001)
    }

    // MARK: - Vitals factor edge cases

    func testVitalsScoreReturnsNilWhenAllInputsMissing() {
        // No vitals data at all → calculateVitalsScore must return nil so
        // the tier composer falls back to Tier 2 (HRV+Sleep) instead of
        // attempting to weight a non-existent factor.
        let empty = RecoveryVitals(
            respiratoryRate: nil, respiratoryRateBaseline: nil,
            oxygenSaturation: nil, oxygenSaturationMin: nil,
            wristTemperature: nil, wristTemperatureBaseline: nil,
            restingHeartRate: nil
        )
        let score = RecoveryScoreCalculator.calculateVitalsScore(
            vitals: empty, baselineStats: baselineStats
        )
        XCTAssertNil(score, "All-nil vitals input must return nil so Tier 2 falls through")
    }

    func testVitalsScoreUsesAvailableSubInputsOnly() {
        // Only RR available (no temp, no RHR). Score should be the RR
        // sub-score alone — no penalty for missing temp/RHR.
        let onlyRR = RecoveryVitals(
            respiratoryRate: 14.5, respiratoryRateBaseline: 14.5, // dev = 0, score = 100
            oxygenSaturation: nil, oxygenSaturationMin: nil,
            wristTemperature: nil, wristTemperatureBaseline: nil,
            restingHeartRate: nil
        )
        let score = RecoveryScoreCalculator.calculateVitalsScore(
            vitals: onlyRR, baselineStats: baselineStats
        )
        XCTAssertEqual(score ?? -1, 100, accuracy: 0.5,
                       "Single-input RR at baseline must score 100, not be diluted by missing inputs")
    }

    func testVitalsScoreAveragesMultipleSubInputs() {
        // RR baseline (sub-score 100), temp +0.7°C (sub-score 50), RHR
        // baseline (sub-score 100). Mean = (100 + 50 + 100) / 3 = 83.33.
        let mixed = RecoveryVitals(
            respiratoryRate: 14.5, respiratoryRateBaseline: 14.5,
            oxygenSaturation: 97.0, oxygenSaturationMin: 96.0,
            wristTemperature: 0.7, wristTemperatureBaseline: 0.0,
            restingHeartRate: 58.0 // baseline meanHRBaseline=58 in helper
        )
        let score = RecoveryScoreCalculator.calculateVitalsScore(
            vitals: mixed, baselineStats: baselineStats
        )
        XCTAssertEqual(score ?? -1, 83.33, accuracy: 0.5)
    }

    func testVitalsScoreSeverelyElevatedTemperatureClampsTo25() {
        // Temp deviation > 1.0°C should land on the severe band (25).
        let feverish = RecoveryVitals(
            respiratoryRate: nil, respiratoryRateBaseline: nil,
            oxygenSaturation: nil, oxygenSaturationMin: nil,
            wristTemperature: 1.4, wristTemperatureBaseline: 0.0,
            restingHeartRate: nil
        )
        let score = RecoveryScoreCalculator.calculateVitalsScore(
            vitals: feverish, baselineStats: baselineStats
        )
        XCTAssertEqual(score ?? -1, 25, accuracy: 0.01,
                       "Wrist temp >1.0°C above baseline must clamp to severe-band score of 25")
    }

    func testVitalsScoreNegativeTemperatureDeviationAlsoCounts() {
        // ASYMMETRIC temperature rule: only warmer-than-
        // baseline is penalized. Cooler-than-baseline is normal physiology
        // (bedroom temperature, lighter bedding, deeper SWS, menstrual
        // phase) and must score 100. A -0.7°C reading therefore lands on
        // the normal band, NOT the moderate band that +0.7°C would.
        let cold = RecoveryVitals(
            respiratoryRate: nil, respiratoryRateBaseline: nil,
            oxygenSaturation: nil, oxygenSaturationMin: nil,
            wristTemperature: -0.7, wristTemperatureBaseline: 0.0,
            restingHeartRate: nil
        )
        let score = RecoveryScoreCalculator.calculateVitalsScore(
            vitals: cold, baselineStats: baselineStats
        )
        XCTAssertEqual(score ?? -1, 100, accuracy: 0.01,
                       "Cooler-than-baseline wrist temp is not a recovery deficit and must score 100")
    }

    func testVitalsScoreSubBaselineRHRDoesNotPenalise() {
        // RHR below personal baseline = full sub-score. The penalty
        // applies only to elevated RHR (above-baseline z-score).
        let lowRHR = RecoveryVitals(
            respiratoryRate: nil, respiratoryRateBaseline: nil,
            oxygenSaturation: nil, oxygenSaturationMin: nil,
            wristTemperature: nil, wristTemperatureBaseline: nil,
            restingHeartRate: 50.0 // baseline 58 ± 3 → z = -2.67, well below baseline
        )
        let score = RecoveryScoreCalculator.calculateVitalsScore(
            vitals: lowRHR, baselineStats: baselineStats
        )
        XCTAssertEqual(score ?? -1, 100, accuracy: 0.5,
                       "Below-baseline RHR is positive — no penalty")
    }

    // MARK: - Comeback-mode boundary

    func testComebackModeIsActiveOnDayZero() {
        // Just-toggled today: day 0 of the 21-day window.
        var settings = UserSettings()
        settings.comebackModeStartDate = Date()
        XCTAssertTrue(settings.isComebackModeActive)
    }

    func testComebackModeIsActiveOnDay20() {
        // Day 20 still counts — the window is `daysSince < 21`.
        var settings = UserSettings()
        settings.comebackModeStartDate = Calendar.current.date(byAdding: .day, value: -20, to: Date())
        XCTAssertTrue(settings.isComebackModeActive,
                      "Day 20 of a 21-day window should still be active")
    }

    func testComebackModeAutoExpiresOnDay21() {
        // Day 21 is past the window — `daysSince < 21` evaluates false.
        var settings = UserSettings()
        settings.comebackModeStartDate = Calendar.current.date(byAdding: .day, value: -21, to: Date())
        XCTAssertFalse(settings.isComebackModeActive,
                       "Day 21 of a 21-day window must auto-expire")
    }

    func testComebackModeReturnsFalseWhenNeverEnabled() {
        var settings = UserSettings()
        settings.comebackModeStartDate = nil
        XCTAssertFalse(settings.isComebackModeActive)
    }

    func testTier2UsesDefaultWeightsWithoutDoublePenalty() {
        let config = RecoveryScoreCalculator.ScoringConfiguration(
            enableTrainingLoadIntegration: false,
            isOnTrainingBreak: false,
            enableSleepIntegration: true,
            penalizeMissingSleep: false,
            userAge: 40
        )
        let sleep = makeSleepData(
            totalSleepMinutes: 430,
            inBedMinutes: 460,
            deepSleepMinutes: 70,
            remSleepMinutes: 90,
            awakeMinutes: 30,
            sleepEfficiency: 93.5
        )
        let breakdown = RecoveryScoreCalculator.calculateWithBreakdown(
            RecoveryScoreCalculator.ScoreInputs(
                hrvReadiness: nil, rmssd: 42.0, meanHR: 58.0, dfaAlpha1: 0.85, baselineStats: baselineStats,
                sleepData: sleep, vitals: nil, typicalSleepHours: 7.5
            ),
            trainingContext: nil,
            config: config
        )

        XCTAssertEqual(breakdown.tier, 2)
        let byLabel = Dictionary(uniqueKeysWithValues: breakdown.factors.map { ($0.label, $0) })
        XCTAssertEqual(byLabel["HRV"]?.weight ?? -1.0, 0.70, accuracy: 0.0001)
        XCTAssertEqual(byLabel["Sleep"]?.weight ?? -1.0, 0.30, accuracy: 0.0001)
    }

    func testTier2DoublePenaltyDampeningUsesEightyFiveFifteenWeights() {
        let config = RecoveryScoreCalculator.ScoringConfiguration(
            enableTrainingLoadIntegration: false,
            isOnTrainingBreak: false,
            enableSleepIntegration: true,
            penalizeMissingSleep: false,
            userAge: 40
        )
        let poorSleep = makeSleepData(
            totalSleepMinutes: 180,
            inBedMinutes: 300,
            deepSleepMinutes: 5,
            remSleepMinutes: 12,
            awakeMinutes: 120,
            sleepEfficiency: 60.0
        )
        let breakdown = RecoveryScoreCalculator.calculateWithBreakdown(
            RecoveryScoreCalculator.ScoreInputs(
                hrvReadiness: nil, rmssd: 15.0, meanHR: 68.0, dfaAlpha1: 1.25, baselineStats: baselineStats,
                sleepData: poorSleep, vitals: nil, typicalSleepHours: 7.5
            ),
            trainingContext: nil,
            config: config
        )

        XCTAssertEqual(breakdown.tier, 2)
        let byLabel = Dictionary(uniqueKeysWithValues: breakdown.factors.map { ($0.label, $0) })
        XCTAssertLessThan(
            byLabel["Sleep"]?.score ?? 100.0,
            50.0,
            "Double-penalty dampening should only trigger when sleep score is poor"
        )
        XCTAssertEqual(byLabel["HRV"]?.weight ?? -1.0, 0.85, accuracy: 0.0001)
        XCTAssertEqual(byLabel["Sleep"]?.weight ?? -1.0, 0.15, accuracy: 0.0001)
    }

    // MARK: - Display Helpers

    func testLabelBuckets() {
        XCTAssertEqual(RecoveryScoreCalculator.label(for: 85), "Excellent")
        XCTAssertEqual(RecoveryScoreCalculator.label(for: 65), "Good")
        XCTAssertEqual(RecoveryScoreCalculator.label(for: 45), "Fair")
        XCTAssertEqual(RecoveryScoreCalculator.label(for: 20), "Low")
    }

    func testToTenScale() {
        XCTAssertEqual(RecoveryScoreCalculator.toTenScale(80.0), 8.0, accuracy: 0.01)
        XCTAssertEqual(RecoveryScoreCalculator.toTenScale(0.0), 0.0, accuracy: 0.01)
        XCTAssertEqual(RecoveryScoreCalculator.toTenScale(100.0), 10.0, accuracy: 0.01)
    }

    // MARK: - ScoringConfiguration Tests

    func testScoringConfigurationConstruction() {
        let config = RecoveryScoreCalculator.ScoringConfiguration(
            enableTrainingLoadIntegration: true,
            isOnTrainingBreak: false,
            enableSleepIntegration: true,
            penalizeMissingSleep: true,
            userAge: 35
        )
        XCTAssertTrue(config.enableTrainingLoadIntegration)
        XCTAssertFalse(config.isOnTrainingBreak)
        XCTAssertTrue(config.enableSleepIntegration)
        XCTAssertTrue(config.penalizeMissingSleep)
        XCTAssertEqual(config.userAge, 35)
    }
}
