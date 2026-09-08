//
//  ScoringCharacterizationTests.swift
//  EmuquTests
//
//  Thirty single-token semantic mutations were
//  introduced one at a time into the functions whose output a user reads as a
//  number about themselves. Fifteen survived a 1,875-test suite — a 52% kill
//  rate — and the survival rate ROSE the closer the code got to the dashboard:
//  0% survived in `Statistics` and `TimeDomainAnalysis`, 59% survived in
//  `RecoveryScoreCalculator` and its extensions.
//
//  The suite was large and the domain files were well covered by line count
//  (`Statistics.swift` 100%, `DFAAnalysis.swift` 98.9%,
//  `SleepScienceAnalyzer.swift` 97.1%). Those two facts together read as "the
//  maths is verified". Mutation testing said the tests mostly asserted that the
//  functions RUN and return something in range, not that they return the RIGHT
//  number.
//
//  One test here per surviving mutation, named for what it pins. Each asserts
//  at the boundary the mutation moved, so the specific change that shipped
//  green now fails. Where a magic number would make the test brittle against
//  legitimate retuning, the assertion is on the RELATIONSHIP (direction, order,
//  bound) instead — a sign flip and a clamp removal are both caught by
//  direction and bound without pinning a value someone may legitimately tune.
//

@testable import Emuqu
import XCTest

final class ScoringCharacterizationTests: XCTestCase {
    // MARK: - Fixtures

    private var baseline: BaselineTracker.RecoveryBaselineStats {
        BaselineTracker.RecoveryBaselineStats(
            lnRmssdMean: log(40.0), lnRmssdSD: 0.3, lnRmssdCV7Day: 6.0,
            meanHRBaseline: 58.0, meanHRSD: 3.0, daysInWindow: 30
        )
    }

    private func staleBaseline(daysAgo: Int, referenceDate: Date) -> BaselineTracker.RecoveryBaselineStats {
        BaselineTracker.RecoveryBaselineStats(
            lnRmssdMean: log(40.0), lnRmssdSD: 0.3, lnRmssdCV7Day: 6.0,
            meanHRBaseline: 58.0, meanHRSD: 3.0, daysInWindow: 30,
            lastDataPointDate: Calendar.current.date(byAdding: .day, value: -daysAgo, to: referenceDate)
        )
    }

    private var config: RecoveryScoreCalculator.ScoringConfiguration {
        RecoveryScoreCalculator.ScoringConfiguration(
            enableTrainingLoadIntegration: true, isOnTrainingBreak: false,
            enableSleepIntegration: true, penalizeMissingSleep: false, userAge: 40
        )
    }

    private func vitals(spo2: Double? = nil, restingHR: Double? = nil) -> RecoveryVitals {
        RecoveryVitals(
            respiratoryRate: nil, respiratoryRateBaseline: nil,
            oxygenSaturation: spo2, oxygenSaturationMin: spo2,
            wristTemperature: nil, wristTemperatureBaseline: nil,
            restingHeartRate: restingHR
        )
    }

    private func tier1(
        rmssd: Double = 40, meanHR: Double? = nil, dfaAlpha1: Double? = nil,
        stats: BaselineTracker.RecoveryBaselineStats? = nil,
        readiness: Double? = nil, ansBalance: Double? = nil,
        referenceDate: Date = Date(timeIntervalSince1970: 1_760_000_000)
    ) -> Double {
        RecoveryScoreCalculator.calculateTier1(
            rmssd: rmssd, meanHR: meanHR, dfaAlpha1: dfaAlpha1,
            baselineStats: stats ?? baseline, readiness: readiness,
            ansBalance: ansBalance, referenceDate: referenceDate
        )
    }

    // MARK: - Resting-HR adjustment direction
    //
    // Mutation: `(hr - meanHRBaseline)` → `(meanHRBaseline - hr)`. Inverts
    // whether an elevated overnight heart rate helps or hurts the score.
    // The doc comment said "Inverted: higher HR = worse recovery" and was the
    // only record of the intent.

    func testElevatedRestingHeartRateLowersTheHRVScore() {
        let atBaseline = tier1(meanHR: 58)
        let elevated = tier1(meanHR: 67)   // +3 SD
        let depressed = tier1(meanHR: 49)  // −3 SD
        XCTAssertLessThan(elevated, atBaseline, "An elevated overnight HR must LOWER the score")
        XCTAssertGreaterThan(depressed, atBaseline, "A depressed overnight HR must RAISE the score")
    }

    func testRestingHeartRateAdjustmentIsClampedBothWays() {
        let extremeHigh = tier1(rmssd: 40, meanHR: 200)
        let extremeLow = tier1(rmssd: 40, meanHR: 1)
        let neutral = tier1(rmssd: 40, meanHR: 58)
        let clamp = RecoveryScoreConstants.HRVAdjustments.rhrClampMax
        XCTAssertEqual(neutral - extremeHigh, clamp, accuracy: 0.001)
        XCTAssertEqual(extremeLow - neutral, clamp, accuracy: 0.001)
    }

    // MARK: - M11: DFA alpha-1 optimal band has an UPPER bound
    //
    // Mutation: drop `a1 <= dfaAlpha1OptimalUpper`. Every alpha-1 above the
    // lower bound then earns the optimal bonus — including values the next
    // branch of the same function calls fatigue.

    func testDFAAlpha1OptimalBandIsBoundedAbove() {
        let inBand = tier1(dfaAlpha1: 0.9)
        let aboveBand = tier1(dfaAlpha1: 1.1)   // > upper, < fatigue threshold
        let fatigued = tier1(dfaAlpha1: 1.5)    // > fatigue threshold
        let none = tier1(dfaAlpha1: nil)
        XCTAssertEqual(inBand - none, RecoveryScoreConstants.HRVAdjustments.dfaOptimalBonus, accuracy: 0.001)
        XCTAssertEqual(aboveBand, none, accuracy: 0.001, "Above the optimal band earns no bonus and no penalty")
        XCTAssertEqual(
            fatigued - none, RecoveryScoreConstants.HRVAdjustments.dfaFatiguePenalty, accuracy: 0.001,
            "Above the fatigue threshold is a penalty, not a bonus"
        )
    }

    func testDFAAlpha1BelowFlexibleLowerIsPenalised() {
        let irregular = tier1(dfaAlpha1: 0.4)
        let none = tier1(dfaAlpha1: nil)
        XCTAssertEqual(irregular - none, RecoveryScoreConstants.HRVAdjustments.dfaIrregularPenalty, accuracy: 0.001)
    }

    // MARK: - Baseline-staleness boundary
    //
    // Mutation: `daysSince >= staleAfterDays` → `>`. Moves the day the penalty
    // starts by one.

    func testStalenessPenaltyStartsExactlyOnTheThresholdDay() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let threshold = RecoveryScoreConstants.BaselineStaleness.staleAfterDays
        let dayBefore = tier1(stats: staleBaseline(daysAgo: threshold - 1, referenceDate: now), referenceDate: now)
        let onThreshold = tier1(stats: staleBaseline(daysAgo: threshold, referenceDate: now), referenceDate: now)
        XCTAssertLessThan(
            onThreshold, dayBefore,
            "The staleness penalty must apply ON day \(threshold), not from day \(threshold + 1)"
        )
    }

    // MARK: - The staleness penalty exists at all, and is bounded

    func testStalenessPenaltyGrowsWithAgeAndIsCapped() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let twoWeeks = tier1(stats: staleBaseline(daysAgo: 14, referenceDate: now), referenceDate: now)
        let oneYear = tier1(stats: staleBaseline(daysAgo: 365, referenceDate: now), referenceDate: now)
        let fresh = tier1(stats: staleBaseline(daysAgo: 0, referenceDate: now), referenceDate: now)
        XCTAssertLessThan(twoWeeks, fresh)
        XCTAssertLessThanOrEqual(
            fresh - oneYear, RecoveryScoreConstants.BaselineStaleness.maxPenalty + 0.001,
            "The staleness penalty must be capped"
        )
    }

    // MARK: - rmssd == 0 must not enter the log-normal path
    //
    // Mutation: `rmssd > 0` → `rmssd >= 0`. With rmssd 0, `log(0)` is −inf, the
    // z-score is −inf, and the score becomes the band floor instead of falling
    // through to the readiness / absolute fallback.

    func testZeroRMSSDFallsThroughToTheReadinessFallback() {
        let withReadiness = tier1(rmssd: 0, readiness: 7.0)
        XCTAssertEqual(withReadiness, 70, accuracy: 0.001, "Readiness 7/10 → 70, not the z-score floor")
    }

    func testZeroRMSSDWithNoReadinessUsesTheNeutralFallback() {
        let neutral = tier1(rmssd: 0, readiness: nil)
        XCTAssertEqual(neutral, RecoveryScoreConstants.AbsoluteRMSSDFallback.neutralScore, accuracy: 0.001)
    }

    // MARK: - M12: stage ratio is capped at 1
    //
    // Mutation: remove `min(…, 1.0)`. An unusually deep night then pushes the
    // sleep sub-score above its stated 0–100 range.

    func testSleepStageRatioIsCappedSoAnExceptionalNightCannotExceedTheRange() {
        let normal = basicSleepScore(deep: 90, rem: 110, night: 450)
        let allDeep = basicSleepScore(deep: 440, rem: 110, night: 450)
        XCTAssertLessThanOrEqual(allDeep, ScoringBounds.maxScore)
        XCTAssertGreaterThanOrEqual(allDeep, normal, "More deep sleep should not score worse")
        // The cap is what makes these equal: both are already at target share.
        XCTAssertEqual(
            allDeep, basicSleepScore(deep: 300, rem: 110, night: 450), accuracy: 0.001,
            "Deep-sleep share above target must not keep adding score"
        )
    }

    // MARK: - M13: deep and REM weights are not interchangeable
    //
    // Mutation: swap `Sleep.deepSleep` and `Sleep.remSleep`.

    func testDeepAndREMSleepCarryDifferentWeight() {
        let deepHeavy = basicSleepScore(deep: 90, rem: 20, night: 450)
        let remHeavy = basicSleepScore(deep: 20, rem: 90, night: 450)
        XCTAssertNotEqual(
            deepHeavy, remHeavy, accuracy: 0.0001,
            "Swapping deep and REM minutes must change the score — the weights differ (0.25 vs 0.15) and the targets differ (0.20 vs 0.25)"
        )
        // The DIRECTION is deliberately not asserted. With stage minutes
        // present, `calculateSleepScore` routes through
        // `SleepScienceAnalyzer.enhancedScore` rather than the basic weighted
        // formula, and that model weighs architecture and cycles as well as
        // stage share — so which of the two nights scores higher is a property
        // of the science model, not of these two constants. What must hold, and
        // what the weight-swap mutation broke, is that the two are NOT
        // interchangeable.
        XCTAssertEqual(
            ScoringWeights.Sleep.duration + ScoringWeights.Sleep.efficiency
                + ScoringWeights.Sleep.deepSleep + ScoringWeights.Sleep.remSleep,
            1.0, accuracy: 0.0001,
            "The basic sleep sub-score weights must still sum to 1"
        )
        XCTAssertNotEqual(
            ScoringWeights.Sleep.deepSleep, ScoringWeights.Sleep.remSleep, accuracy: 0.0001,
            "Deep and REM weights are distinct; swapping them is a behaviour change"
        )
        XCTAssertNotEqual(
            ScoringWeights.Sleep.deepSleepTargetProportion,
            ScoringWeights.Sleep.remSleepTargetProportion, accuracy: 0.0001
        )
    }

    private func basicSleepScore(deep: Int, rem: Int, night: Int) -> Double {
        let end = Date(timeIntervalSince1970: 1_760_000_000)
        let sleep = SleepData(
            date: end, inBedStart: end.addingTimeInterval(-Double(night) * 60),
            sleepStart: end.addingTimeInterval(-Double(night) * 60), sleepEnd: end,
            totalSleepMinutes: night, inBedMinutes: night,
            deepSleepMinutes: deep, remSleepMinutes: rem, awakeMinutes: 0,
            sleepEfficiency: 92, boundarySource: .healthKit,
            segments: [], stageIntervals: [], boundaryValidation: nil, hrSleepQuality: nil
        )
        // stageIntervals empty → SleepScienceAnalyzer returns nil → basic formula.
        return RecoveryScoreCalculator.calculateSleepScore(
            sleepData: sleep, typicalSleepHours: 8, userAge: 40
        ) ?? -1
    }

    // MARK: - M14 / M29: the SpO2 override and the composite clamp
    //
    // Mutant M14 deletes the SpO2 penalty entirely — the one clinical-safety
    // override in the model. M29 removes the 0–100 clamp on the composite.

    func testLowSpO2AppliesTheFlatPenaltyToTheComposite() {
        let healthy = breakdown(spo2: 98)
        let concerning = breakdown(spo2: 88)
        XCTAssertEqual(
            healthy.compositeScore - concerning.compositeScore,
            RecoveryScoreConstants.Vitals.spo2Penalty, accuracy: 0.001,
            "SpO2 below 95% must cost exactly the documented flat penalty"
        )
        XCTAssertFalse(concerning.penalties.isEmpty, "The penalty must also be described to the user")
    }

    func testSpO2ThresholdIsExactlyNinetyFive() {
        XCTAssertEqual(breakdown(spo2: 95).compositeScore, breakdown(spo2: 99).compositeScore, accuracy: 0.001)
        XCTAssertLessThan(breakdown(spo2: 94.9).compositeScore, breakdown(spo2: 95).compositeScore)
    }

    func testCompositeStaysWithinRangeAtBothExtremes() {
        for spo2 in [Double.nan, 0, 50, 88, 94.999, 95, 100, 200] {
            let score = breakdown(spo2: spo2).compositeScore
            XCTAssertTrue(score.isFinite, "Composite must be finite for SpO2 \(spo2)")
            XCTAssertGreaterThanOrEqual(score, ScoringBounds.minScore)
            XCTAssertLessThanOrEqual(score, ScoringBounds.maxScore)
        }
    }

    private func breakdown(spo2: Double) -> RecoveryScoreCalculator.ScoreBreakdown {
        RecoveryScoreCalculator.calculateWithBreakdown(
            RecoveryScoreCalculator.ScoreInputs(
                hrvReadiness: nil, rmssd: 40, meanHR: 58, dfaAlpha1: 0.9,
                baselineStats: baseline, sleepData: nil,
                vitals: vitals(spo2: spo2), typicalSleepHours: 8
            ),
            trainingMetrics: nil, config: config,
            referenceDate: Date(timeIntervalSince1970: 1_760_000_000)
        )
    }

    // MARK: - The perceived-readiness blend
    //
    // Nothing exercised this path, so two things could go wrong unnoticed: the
    // documented 70% baseline / 30% subjective weighting could be inverted, and
    // the composite could be rebuilt from the weighted factor sum, dropping BOTH
    // the clamp and the SpO2 override.

    func testPerceivedReadinessBlendFavoursTheBaselineSeventyThirty() {
        let low = perceivedBreakdown(perceived: 0.0)
        let high = perceivedBreakdown(perceived: 1.0)
        let mid = perceivedBreakdown(perceived: 0.5)

        guard let lowHRV = hrvFactor(low), let highHRV = hrvFactor(high), let midHRV = hrvFactor(mid) else {
            return XCTFail("Expected an HRV factor in the blended breakdown")
        }
        // Subjective moves the factor across a 0…100 span at its own weight.
        let span = highHRV.score - lowHRV.score
        XCTAssertEqual(
            span, 100 * ScoringWeights.PerceivedReadiness.subjective, accuracy: 0.001,
            "The subjective term must carry exactly its documented weight"
        )
        XCTAssertEqual(midHRV.score, (lowHRV.score + highHRV.score) / 2, accuracy: 0.001)
        XCTAssertGreaterThan(
            ScoringWeights.PerceivedReadiness.baseline, ScoringWeights.PerceivedReadiness.subjective,
            "Baseline HRV outweighs the subjective answer, not the other way round"
        )
    }

    /// The SpO2 penalty must survive the perceived-readiness blend.
    func testPerceivedReadinessBlendKeepsTheSpO2Penalty() {
        let withoutPerceived = perceivedBreakdown(perceived: nil, spo2: 88)
        let withPerceived = perceivedBreakdown(perceived: 0.5, spo2: 88)
        let factorSum = withPerceived.factors.reduce(0.0) { $0 + $1.contribution }
        XCTAssertFalse(withPerceived.penalties.isEmpty)
        XCTAssertEqual(
            factorSum - withPerceived.compositeScore,
            RecoveryScoreConstants.Vitals.spo2Penalty, accuracy: 0.001,
            "The blended composite must still carry the SpO2 penalty — it used to be rebuilt from the factor sum, which dropped it"
        )
        XCTAssertLessThan(withoutPerceived.compositeScore, 100)
    }

    /// An out-of-domain perceived value must not escape 0…100.
    ///
    /// Two assertions, because the composite clamp alone would mask a missing
    /// input clamp: `perceived = 100` produced a factor score of 10,000 and a
    /// composite of 3050.4 before this was fixed. The FACTOR must be in range
    /// too, or the breakdown the user reads contradicts the number.
    func testPerceivedReadinessOutsideItsDomainCannotBreakTheRange() {
        for perceived in [-5.0, 0, 0.5, 1.0, 100.0, 1e9, Double.nan] {
            let breakdown = perceivedBreakdown(perceived: perceived)
            XCTAssertTrue(breakdown.compositeScore.isFinite, "perceived=\(perceived) produced a non-finite composite")
            XCTAssertGreaterThanOrEqual(breakdown.compositeScore, ScoringBounds.minScore)
            XCTAssertLessThanOrEqual(breakdown.compositeScore, ScoringBounds.maxScore)
            for factor in breakdown.factors {
                XCTAssertGreaterThanOrEqual(
                    factor.score, ScoringBounds.minScore,
                    "perceived=\(perceived) drove factor \(factor.label) below 0"
                )
                XCTAssertLessThanOrEqual(
                    factor.score, ScoringBounds.maxScore,
                    "perceived=\(perceived) drove factor \(factor.label) above 100 — the input clamp is missing"
                )
            }
        }
        // The subjective mapping itself, directly.
        XCTAssertEqual(RecoveryScoreCalculator.subjectiveScore(from: 1.0), 100, accuracy: 0.001)
        XCTAssertEqual(RecoveryScoreCalculator.subjectiveScore(from: 100), 100, accuracy: 0.001)
        XCTAssertEqual(RecoveryScoreCalculator.subjectiveScore(from: -5), 0, accuracy: 0.001)
        XCTAssertEqual(RecoveryScoreCalculator.subjectiveScore(from: .nan), ScoringBounds.neutralSubjectiveScore)
    }

    /// M29 — the composite clamp, exercised with weights that would overflow it.
    /// A tier-1-only breakdown carries a single factor at weight 1, so a factor
    /// score above 100 goes straight through unless the clamp catches it.
    func testCompositeIsClampedEvenWhenAFactorWouldOverflowIt() {
        let breakdown = perceivedBreakdown(perceived: 1e9)
        let weightedSum = breakdown.factors.reduce(0.0) { $0 + $1.contribution }
        XCTAssertLessThanOrEqual(breakdown.compositeScore, ScoringBounds.maxScore)
        XCTAssertGreaterThanOrEqual(breakdown.compositeScore, ScoringBounds.minScore)
        XCTAssertLessThanOrEqual(
            weightedSum, ScoringBounds.maxScore + 0.001,
            "Every factor is clamped, so their weighted sum cannot exceed the range either"
        )
    }

    private func perceivedBreakdown(perceived: Double?, spo2: Double = 98) -> RecoveryScoreCalculator.ScoreBreakdown {
        RecoveryScoreCalculator.calculateWithBreakdown(
            RecoveryScoreCalculator.ScoreInputs(
                hrvReadiness: nil, rmssd: nil, meanHR: nil, dfaAlpha1: nil,
                baselineStats: baseline, sleepData: nil,
                vitals: vitals(spo2: spo2), typicalSleepHours: 8
            ),
            trainingContext: nil, config: config,
            useBaselineHRV: true, perceivedReadiness: perceived,
            ansBalance: nil, referenceDate: Date(timeIntervalSince1970: 1_760_000_000)
        )
    }

    private func hrvFactor(_ breakdown: RecoveryScoreCalculator.ScoreBreakdown) -> RecoveryScoreCalculator.ScoreFactor? {
        breakdown.factors.first { $0.label == "HRV" }
    }

    // MARK: - M25: the intra-day freshness bonus is capped

    func testFreshnessBonusIsCapped() {
        let cap = RecoveryScoreConstants.Readiness.freshnessGainCap
        let multiplier = RecoveryScoreConstants.Readiness.freshnessGainMultiplier
        let underCapDrop = (cap / multiplier) - 1

        // Tested on the unit, not through `calculateReadiness`: the recovery
        // modulation stage rescales the result afterwards and hides the cap.
        let base = 50.0
        let small = RecoveryScoreCalculator.applyFreshnessBonus(base, morningATL: 40 + underCapDrop, atl: 40)
        let huge = RecoveryScoreCalculator.applyFreshnessBonus(base, morningATL: 10_000, atl: 40)

        XCTAssertEqual(small - base, underCapDrop * multiplier, accuracy: 0.001, "Below the cap the bonus is linear")
        XCTAssertEqual(huge - base, cap, accuracy: 0.001, "Above the cap the bonus stops — it must not keep climbing")
        // No morning reading, or ATL that went UP, means no bonus at all.
        XCTAssertEqual(RecoveryScoreCalculator.applyFreshnessBonus(base, morningATL: nil, atl: 40), base)
        XCTAssertEqual(RecoveryScoreCalculator.applyFreshnessBonus(base, morningATL: 30, atl: 40), base)
    }

    // MARK: - M26: the low-CTL confidence ramp on the ACWR penalty
    //
    // From a tester report: CTL 16, ACWR 1.63
    // produced a 21.5% penalty and a "Fatigued" readout while the HRV pill
    // simultaneously read 10.0 "Ready". The fix for a reported user-facing bug
    // was untested.

    func testACWRPenaltyRampsLinearlyWithCTL() {
        let full = RecoveryScoreConstants.Readiness.acwrFullConfidenceCTL
        let acr = 1.7
        // Recovery below the rescue threshold so only the ramp is in play.
        let below = RecoveryScoreConstants.Readiness.acwrRescueRecoveryThreshold - 10
        let atFull = RecoveryScoreCalculator.dampenedACWRPenalty(acr: acr, ctl: full, recoveryScore: below)
        let atHalf = RecoveryScoreCalculator.dampenedACWRPenalty(acr: acr, ctl: full / 2, recoveryScore: below)
        let atZero = RecoveryScoreCalculator.dampenedACWRPenalty(acr: acr, ctl: 0, recoveryScore: below)

        XCTAssertGreaterThan(atFull, 0)
        XCTAssertEqual(atHalf, atFull / 2, accuracy: 0.0001, "Half the confidence CTL must mean half the penalty")
        XCTAssertEqual(atZero, 0, accuracy: 0.0001, "No training history means no ACWR penalty at all")
        // Above full confidence the ramp saturates rather than continuing.
        XCTAssertEqual(
            RecoveryScoreCalculator.dampenedACWRPenalty(acr: acr, ctl: full * 4, recoveryScore: below),
            atFull, accuracy: 0.0001
        )
    }

    func testACWRPenaltyIsCappedWhenRecoveryIsClearlyGood() {
        let r = RecoveryScoreConstants.Readiness.self
        let severe = 1.9
        let rescued = RecoveryScoreCalculator.dampenedACWRPenalty(
            acr: severe, ctl: r.acwrFullConfidenceCTL, recoveryScore: r.acwrRescueRecoveryThreshold
        )
        let notRescued = RecoveryScoreCalculator.dampenedACWRPenalty(
            acr: severe, ctl: r.acwrFullConfidenceCTL, recoveryScore: r.acwrRescueRecoveryThreshold - 1
        )
        XCTAssertEqual(rescued, r.acwrPenaltyAutonomicRescueCap, accuracy: 0.0001)
        XCTAssertGreaterThan(
            notRescued, rescued,
            "Below the rescue threshold the full penalty applies; at or above it the proxy is capped"
        )
    }

    // MARK: - M27: readiness is clamped

    func testReadinessStaysWithinRangeAcrossExtremeInputs() {
        let values: [Double] = [-100, 0, 1, 50, 1e6, .nan, .infinity]
        for recovery in [0.0, 50, 100] {
            for trimp in values where trimp.isFinite {
                for ctl in values where ctl.isFinite {
                    let readiness = RecoveryScoreCalculator.calculateReadiness(
                        recoveryScore: recovery, todayTrimp: trimp, ctl: ctl, atl: trimp,
                        morningATL: trimp, acuteChronicRatio: ctl > 0 ? trimp / ctl : nil
                    )
                    XCTAssertTrue(readiness.isFinite)
                    XCTAssertGreaterThanOrEqual(readiness, ScoringBounds.minScore)
                    XCTAssertLessThanOrEqual(readiness, ScoringBounds.maxScore)
                }
            }
        }
    }

    // MARK: - M28: the readiness label bands
    //
    // Mutation: "Ready" threshold 7.0 → 4.5. Nothing asserted which band
    // produced which word.

    func testReadinessLabelBands() {
        let labels = RecoveryScoreConstants.ReadinessLabels.self
        XCTAssertEqual(RecoveryScoreCalculator.readinessLabel(for: labels.readyThreshold), "Ready")
        XCTAssertEqual(RecoveryScoreCalculator.readinessLabel(for: labels.readyThreshold - 0.01), "Moderate")
        XCTAssertEqual(RecoveryScoreCalculator.readinessLabel(for: labels.moderateThreshold), "Moderate")
        XCTAssertEqual(RecoveryScoreCalculator.readinessLabel(for: labels.moderateThreshold - 0.01), "Fatigued")
        XCTAssertEqual(RecoveryScoreCalculator.readinessLabel(for: labels.fatiguedThreshold), "Fatigued")
        XCTAssertEqual(RecoveryScoreCalculator.readinessLabel(for: labels.fatiguedThreshold - 0.01), "Rest")
        XCTAssertEqual(RecoveryScoreCalculator.readinessLabel(for: 0), "Rest")
    }

    /// The label takes a 0–10 value while `calculateReadiness` returns 0–100.
    /// Every call site converts, but the signature invited the mistake, so the
    /// clamp is now part of the contract.
    func testReadinessLabelClampsAnUnconvertedHundredScaleValue() {
        XCTAssertEqual(RecoveryScoreCalculator.readinessLabel(for: 100), "Ready")
        XCTAssertEqual(RecoveryScoreCalculator.readinessLabel(for: Double.nan), "Moderate")
    }

    // MARK: - M30: the displayed sub-score is the one that fed the composite
    //
    // If the RHR sub-score maths exists twice in `+Vitals.swift` — once for the
    // score, once for the sentence describing it — doubling the penalty in the
    // display copy alone passes the suite.

    /// The RHR sub-score itself, at a known offset. The detail-vs-score
    /// agreement test below cannot catch a re-tune because both read the
    /// same function, so the value is pinned here.
    func testRestingHRSubScoreIsLinearAtTheDocumentedRate() throws {
        func subScore(_ bpm: Double) throws -> Double {
            try XCTUnwrap(
                RecoveryScoreCalculator.calculateVitalsScore(
                    vitals: vitals(restingHR: bpm), baselineStats: baseline
                ),
                "Expected a vitals sub-score for \(bpm) bpm"
            )
        }
        // 70 bpm against a 58 / 3 baseline is exactly +4 SD.
        XCTAssertEqual(try subScore(58), 100, accuracy: 0.001, "At or below baseline scores 100")
        XCTAssertEqual(
            try subScore(70), 100 - 4 * ScoringWeights.Vitals.rhrPenaltyPerSD, accuracy: 0.001,
            "The RHR sub-score falls by exactly rhrPenaltyPerSD for each SD above baseline"
        )
        // Below baseline must not earn a bonus — the max(0, …) on the deviation.
        XCTAssertEqual(try subScore(40), 100, accuracy: 0.001)
    }

    func testSleepHRDetailReportsTheSubScoreThatFedTheComposite() {
        let readings = vitals(restingHR: 70) // +4 SD above a 58 / 3 baseline
        guard let vitalsScore = RecoveryScoreCalculator.calculateVitalsScore(
            vitals: readings, baselineStats: baseline
        ) else { return XCTFail("Expected a vitals sub-score") }

        let detail = RecoveryScoreCalculator.buildVitalsDetail(
            vitals: readings, baselineStats: baseline, score: vitalsScore
        )
        // With only RHR present the vitals score IS the RHR sub-score, so the
        // number printed after the arrow must equal it.
        let printed = Self.trailingIntegers(in: detail)
        XCTAssertTrue(
            printed.contains(Int(vitalsScore.rounded())),
            "The Sleep HR detail must print the same sub-score that fed the composite. Detail: \(detail), score: \(vitalsScore)"
        )
    }

    private static func trailingIntegers(in text: String) -> [Int] {
        text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    // MARK: - Band-table invariants

    func testShippedScoringParametersAreMonotonicAndInRange() {
        for parameters in [
            RecoveryScoreCalculator.scoringParametersV1,
            RecoveryScoreCalculator.scoringParametersV2,
            RecoveryScoreCalculator.defaultScoringParameters
        ] {
            XCTAssertTrue(
                parameters.isMonotonicInZ,
                "\(parameters.version) is not monotonic in z — the interpolation factor would go negative"
            )
            XCTAssertTrue(
                parameters.hasScoresInRange,
                "\(parameters.version) has a band outside 0…100"
            )
        }
    }

    func testZToRecoveryScoreDegradesToNeutralOnNonFiniteInput() {
        XCTAssertEqual(RecoveryScoreCalculator.zToRecoveryScore(.nan), ScoringBounds.neutralScore)
        XCTAssertEqual(RecoveryScoreCalculator.zToPercentileScore(.nan), ScoringBounds.neutralScore)
        // ±infinity is a real ordering, so it still maps to the endpoints.
        XCTAssertEqual(RecoveryScoreCalculator.zToRecoveryScore(.infinity), 90, accuracy: 0.001)
        XCTAssertEqual(RecoveryScoreCalculator.zToRecoveryScore(-.infinity), 5, accuracy: 0.001)
    }

    // MARK: - RMSSD primitives must never emit a non-finite measurement

    func testRMSSDReturnsNilRatherThanANonFiniteValue() {
        XCTAssertNil(TimeDomainAnalyzer.rmssd(fromCleanRRs: [.nan, .nan]))
        XCTAssertNil(TimeDomainAnalyzer.rmssd(fromCleanRRs: [1e308, -1e308]))
        XCTAssertNil(TimeDomainAnalyzer.rmssd(fromRRs: [.nan, .nan], isValid: { _ in true }))
        XCTAssertNotNil(TimeDomainAnalyzer.rmssd(fromCleanRRs: [800, 820, 810]))
    }
}
