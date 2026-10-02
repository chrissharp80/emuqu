@testable import Emuqu
import XCTest

/// Tests for RecoveryScoreCalculator pure functions.
/// Validates z-score normalization, tier logic, training scoring, and vitals overrides.
final class RecoveryScoreCalculatorTests: XCTestCase {
    // MARK: - Test Helpers

    var defaultConfig: RecoveryScoreCalculator.ScoringConfiguration {
        RecoveryScoreCalculator.ScoringConfiguration(
            enableTrainingLoadIntegration: true,
            isOnTrainingBreak: false,
            enableSleepIntegration: true,
            penalizeMissingSleep: false,
            userAge: 40
        )
    }

    var baselineStats: BaselineTracker.RecoveryBaselineStats {
        BaselineTracker.RecoveryBaselineStats(
            lnRmssdMean: log(40.0), // ~3.689
            lnRmssdSD: 0.3,
            lnRmssdCV7Day: 6.0,
            meanHRBaseline: 58.0,
            meanHRSD: 3.0,
            daysInWindow: 30
        )
    }

    func makeSleepData(
        totalSleepMinutes: Int,
        inBedMinutes: Int,
        deepSleepMinutes: Int?,
        remSleepMinutes: Int?,
        awakeMinutes: Int,
        sleepEfficiency: Double
    ) -> SleepData {
        let end = Date()
        let inBedStart = end.addingTimeInterval(-Double(inBedMinutes) * 60.0)
        let sleepStart = end.addingTimeInterval(-Double(totalSleepMinutes) * 60.0)

        return SleepData(
            date: end,
            inBedStart: inBedStart,
            sleepStart: sleepStart,
            sleepEnd: end,
            totalSleepMinutes: totalSleepMinutes,
            inBedMinutes: inBedMinutes,
            deepSleepMinutes: deepSleepMinutes,
            remSleepMinutes: remSleepMinutes,
            awakeMinutes: awakeMinutes,
            sleepEfficiency: sleepEfficiency,
            boundarySource: .healthKit,
            segments: [],
            stageIntervals: [],
            boundaryValidation: nil,
            hrSleepQuality: nil
        )
    }

    // MARK: - zToPercentileScore Tests (utility, not used for recovery)

    func testZeroZScoreMapsToFifty() {
        let score = RecoveryScoreCalculator.zToPercentileScore(0)
        XCTAssertEqual(score, 50.0, accuracy: 0.1)
    }

    func testPositiveOneZScoreMapsToEightyFour() {
        let score = RecoveryScoreCalculator.zToPercentileScore(1.0)
        XCTAssertEqual(score, 84.1, accuracy: 0.5)
    }

    func testNegativeOneZScoreMapsToSixteen() {
        let score = RecoveryScoreCalculator.zToPercentileScore(-1.0)
        XCTAssertEqual(score, 15.9, accuracy: 0.5)
    }

    func testZScoreClampedAtThree() {
        let high = RecoveryScoreCalculator.zToPercentileScore(5.0)
        let atThree = RecoveryScoreCalculator.zToPercentileScore(3.0)
        XCTAssertEqual(
            high,
            atThree,
            accuracy: 0.01,
            "z > 3 should be clamped to z = 3"
        )
    }

    func testZScoreClampedAtNegativeThree() {
        let low = RecoveryScoreCalculator.zToPercentileScore(-5.0)
        let atNegThree = RecoveryScoreCalculator.zToPercentileScore(-3.0)
        XCTAssertEqual(
            low,
            atNegThree,
            accuracy: 0.01,
            "z < -3 should be clamped to z = -3"
        )
    }

    // MARK: - zToRecoveryScore Tests (SWC band model)

    func testRecoveryScoreAtBaseline() {
        // Tests encode the calibration in RecoveryScoreCalculator.zToRecoveryScore
        // (z=0 → 72). The mapping is designed so an average day with balanced
        // inputs lands in the mid-70s rather than the 80s — matching Plews/
        // Buchheit "stable within SWC" as neutral, not excellent.
        let score = RecoveryScoreCalculator.zToRecoveryScore(0)
        XCTAssertEqual(score, 72.0, accuracy: 0.1)
    }

    func testRecoveryScoreWithinSWC() {
        // v2 — the ±0.5 SD band is a flat SWC deadband:
        // within-noise variation is not a real change (Plews/Buchheit), so
        // z=-0.5 and z=+0.5 both score 72 (== baseline), no penalty/bonus.
        let lower = RecoveryScoreCalculator.zToRecoveryScore(-0.5)
        let upper = RecoveryScoreCalculator.zToRecoveryScore(0.5)
        XCTAssertEqual(lower, 72.0, accuracy: 0.1)
        XCTAssertEqual(upper, 72.0, accuracy: 0.1)
    }

    func testRecoveryScoreAboveBaselinePlateaus() {
        // Above SWC plateaus at 90 — above baseline is ambiguous per research,
        // so additional z above 1.5 does not raise the score further.
        let atPlateau = RecoveryScoreCalculator.zToRecoveryScore(1.5)
        let wellAbove = RecoveryScoreCalculator.zToRecoveryScore(3.0)
        let extreme = RecoveryScoreCalculator.zToRecoveryScore(5.0)
        XCTAssertEqual(atPlateau, 90.0, accuracy: 0.1)
        XCTAssertEqual(wellAbove, 90.0, accuracy: 0.1)
        XCTAssertEqual(
            extreme,
            90.0,
            accuracy: 0.1,
            "z > 1.5 should plateau at 90"
        )
    }

    func testRecoveryScoreBelowBaselineDropsSteeply() {
        // Below SWC drops steeply — under-recovery is actionable.
        let belowSWC = RecoveryScoreCalculator.zToRecoveryScore(-1.5)
        let wellBelow = RecoveryScoreCalculator.zToRecoveryScore(-3.0)
        XCTAssertEqual(belowSWC, 25.0, accuracy: 0.1)
        XCTAssertEqual(wellBelow, 5.0, accuracy: 0.1)
    }

    func testRecoveryScoreFloorAndCeiling() {
        let floor = RecoveryScoreCalculator.zToRecoveryScore(-5.0)
        let ceiling = RecoveryScoreCalculator.zToRecoveryScore(5.0)
        XCTAssertEqual(
            floor,
            5.0,
            accuracy: 0.1,
            "z ≤ -3 should clamp to floor of 5"
        )
        XCTAssertEqual(
            ceiling,
            90.0,
            accuracy: 0.1,
            "z ≥ 1.5 should clamp to ceiling of 90"
        )
    }

    // MARK: - ScoringParameters Parity

    /// The default parameter set must match the shipped band values. If
    /// this fails, a band change landed without a version bump — fix the
    /// version, not the test.
    /// The default is v2 (SWC deadband: flat 72 across
    /// ±0.5 SD, steep drop starting below -0.75 SD).
    func testDefaultScoringParametersIsV2() {
        let params = RecoveryScoreCalculator.defaultScoringParameters
        XCTAssertEqual(params.version, "v2.2026-06-22")
        XCTAssertEqual(params.zScoreBands.count, 6)
        // Pin the exact bands so any literal edit shows up here
        let expected: [(Double, Double)] = [
            (-3.0, 5.0), (-1.5, 25.0), (-0.75, 64.0),
            (-0.5, 72.0), (0.5, 72.0), (1.5, 90.0)
        ]
        for (i, pair) in expected.enumerated() {
            XCTAssertEqual(params.zScoreBands[i].z, pair.0, accuracy: 1e-9)
            XCTAssertEqual(params.zScoreBands[i].score, pair.1, accuracy: 1e-9)
        }
    }

    /// Behavioural parity: passing the default parameters explicitly must
    /// produce the same outputs as the implicit-default call site. This is
    /// the safety net that catches accidental decoupling between the
    /// extracted struct and the function that consumes it.
    func testZToRecoveryScoreParityWithExplicitDefaultParameters() {
        let zs = [-5.0, -3.0, -1.5, -0.7, 0.0, 0.25, 0.5, 1.0, 1.5, 3.0, 5.0]
        for z in zs {
            let implicit = RecoveryScoreCalculator.zToRecoveryScore(z)
            let explicit = RecoveryScoreCalculator.zToRecoveryScore(
                z,
                parameters: RecoveryScoreCalculator.defaultScoringParameters
            )
            XCTAssertEqual(implicit, explicit, accuracy: 1e-9, "parity broken at z=\(z)")
        }
    }

    /// A custom parameter set with shifted bands should change the output —
    /// proves the function actually reads the supplied parameters and
    /// isn't hard-wired to the default literal.
    func testZToRecoveryScoreHonorsCustomParameters() {
        let custom = RecoveryScoreCalculator.ScoringParameters(
            version: "test",
            zScoreBands: [
                (-3.0, 0.0),
                (0.0, 50.0),
                (3.0, 100.0)
            ]
        )
        XCTAssertEqual(RecoveryScoreCalculator.zToRecoveryScore(0.0, parameters: custom), 50.0, accuracy: 0.01)
        XCTAssertEqual(RecoveryScoreCalculator.zToRecoveryScore(-3.0, parameters: custom), 0.0, accuracy: 0.01)
        XCTAssertEqual(RecoveryScoreCalculator.zToRecoveryScore(3.0, parameters: custom), 100.0, accuracy: 0.01)
        XCTAssertEqual(RecoveryScoreCalculator.zToRecoveryScore(1.5, parameters: custom), 75.0, accuracy: 0.01)
    }

    func testRecoveryScoreAsymmetry() {
        // Dropping 1 SD below baseline should hurt more than
        // rising 1 SD above baseline helps
        let above = RecoveryScoreCalculator.zToRecoveryScore(1.0) - RecoveryScoreCalculator.zToRecoveryScore(0)
        let below = RecoveryScoreCalculator.zToRecoveryScore(0) - RecoveryScoreCalculator.zToRecoveryScore(-1.0)
        XCTAssertGreaterThan(
            below,
            above,
            "Below-baseline penalty should exceed above-baseline bonus"
        )
    }

    // MARK: - Tier 1 (HRV-only) Tests

    func testTier1WithBaselineAboveAverage() {
        // RMSSD 55ms with baseline mean ~40ms -> z > 0 -> score > 80
        // With SWC model, above baseline scores 80+ (plus DFA bonus)
        let score = RecoveryScoreCalculator.calculateTier1(
            rmssd: 55.0, meanHR: 58.0, dfaAlpha1: 0.85,
            baselineStats: baselineStats, readiness: nil
        )
        XCTAssertGreaterThan(score, 80.0)
    }

    func testTier1WithBaselineBelowAverage() {
        // RMSSD 25ms with baseline mean ~40ms -> z < 0 -> score < 80
        // With SWC model, below baseline drops steeply from 80
        let score = RecoveryScoreCalculator.calculateTier1(
            rmssd: 25.0, meanHR: 58.0, dfaAlpha1: nil,
            baselineStats: baselineStats, readiness: nil
        )
        XCTAssertLessThan(score, 80.0)
    }

    func testTier1FallbackToReadiness() {
        // No baseline: readiness 7.0 -> score 70
        let score = RecoveryScoreCalculator.calculateTier1(
            rmssd: 40.0, meanHR: nil, dfaAlpha1: nil,
            baselineStats: nil, readiness: 7.0
        )
        XCTAssertEqual(score, 70.0, accuracy: 0.1)
    }

    func testTier1FallbackToAbsoluteThresholds() {
        // No baseline, no readiness: RMSSD 50 -> 70
        let score = RecoveryScoreCalculator.calculateTier1(
            rmssd: 50.0, meanHR: nil, dfaAlpha1: nil,
            baselineStats: nil, readiness: nil
        )
        XCTAssertEqual(score, 70.0, accuracy: 0.1)
    }

    func testTier1NoData() {
        let score = RecoveryScoreCalculator.calculateTier1(
            rmssd: 0, meanHR: nil, dfaAlpha1: nil,
            baselineStats: nil, readiness: nil
        )
        XCTAssertEqual(score, 50.0, accuracy: 0.1)
    }

    func testTier1ClampedTo0To100() {
        let veryLow = RecoveryScoreCalculator.calculateTier1(
            rmssd: 5.0, meanHR: 80.0, dfaAlpha1: 1.5,
            baselineStats: baselineStats, readiness: nil
        )
        XCTAssertGreaterThanOrEqual(veryLow, 0.0)
        XCTAssertLessThanOrEqual(veryLow, 100.0)
    }

    // MARK: - Tier 1 Baseline Staleness Tests

    /// The staleness penalty must follow the injected referenceDate, not the
    /// wall clock. Penalty shape (RecoveryScoreConstants.BaselineStaleness):
    /// kicks in at 7 days, 5 points/week from there, capped at 20.
    func testTier1StalenessPenaltyFollowsReferenceDate() throws {
        let lastDate = Date(timeIntervalSince1970: 1_700_000_000)
        var stats = baselineStats
        stats.lastDataPointDate = lastDate

        func score(daysLater: Int) throws -> Double {
            let reference = try XCTUnwrap(
                Calendar.current.date(byAdding: .day, value: daysLater, to: lastDate)
            )
            return RecoveryScoreCalculator.calculateTier1(
                rmssd: 40.0, meanHR: 58.0, dfaAlpha1: nil,
                baselineStats: stats, readiness: nil,
                referenceDate: reference
            )
        }

        // rmssd 40 = baseline mean → z = 0 → 72; HR at baseline (no RHR
        // adjustment), CV 6.0 inside the 2–12 deadband, no DFA. The only
        // difference between calls is the staleness penalty.
        let fresh = try score(daysLater: 2) // < 7 days stale: no penalty
        let stale = try score(daysLater: 14) // (14-7)/7 = 1 week past: 5 × (1 + 1) = 10
        let ancient = try score(daysLater: 365) // capped at maxPenalty
        XCTAssertEqual(fresh, 72.0, accuracy: 0.1, "fresh baseline should carry no staleness penalty")
        XCTAssertEqual(fresh - stale, 10.0, accuracy: 1e-9, "14 days stale should cost exactly 10 points")
        XCTAssertEqual(fresh - ancient, 20.0, accuracy: 1e-9, "staleness penalty should cap at 20")
    }

    /// Same inputs + same referenceDate must yield identical scores —
    /// proves no hidden wall-clock read remains in the Tier 1 path.
    func testTier1DeterministicForFixedReferenceDate() {
        let lastDate = Date(timeIntervalSince1970: 1_700_000_000)
        var stats = baselineStats
        stats.lastDataPointDate = lastDate
        let reference = lastDate.addingTimeInterval(20 * 86_400)

        let first = RecoveryScoreCalculator.calculateTier1(
            rmssd: 33.0, meanHR: 61.0, dfaAlpha1: 0.85,
            baselineStats: stats, readiness: nil,
            referenceDate: reference
        )
        let second = RecoveryScoreCalculator.calculateTier1(
            rmssd: 33.0, meanHR: 61.0, dfaAlpha1: 0.85,
            baselineStats: stats, readiness: nil,
            referenceDate: reference
        )
        XCTAssertEqual(first, second, "identical inputs + referenceDate must produce identical scores")
    }

    // MARK: - Monotony/Strain Tests

    func testFosterMonotonyStrainNeedsTraining() {
        // No training at all — should return nil
        let result = RecoveryScoreCalculator.fosterMonotonyStrain(dailyTrimp: [:])
        XCTAssertNil(result)
    }

    func testFosterMonotonyStrainVariedTraining() throws {
        // Varied training: some hard, some easy, some rest
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var daily: [Date: Double] = [:]
        let loads = [120.0, 0.0, 80.0, 0.0, 100.0, 40.0, 0.0]
        for (i, load) in loads.enumerated() {
            try daily[XCTUnwrap(calendar.date(byAdding: .day, value: -i, to: today))] = load
        }
        let result = RecoveryScoreCalculator.fosterMonotonyStrain(dailyTrimp: daily)
        XCTAssertNotNil(result)
        // Varied training should have low monotony (<2.0)
        XCTAssertLessThan(try XCTUnwrap(result?.monotony), 2.0)
    }

    func testFosterMonotonyStrainMonotonousTraining() throws {
        // Same load every day = high monotony
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var daily: [Date: Double] = [:]
        for i in 0 ..< 7 {
            try daily[XCTUnwrap(calendar.date(byAdding: .day, value: -i, to: today))] = 100.0
        }
        let result = RecoveryScoreCalculator.fosterMonotonyStrain(dailyTrimp: daily)
        XCTAssertNotNil(result)
        // Identical loads → SD ≈ 0 → monotony should be very high (capped at 10)
        XCTAssertGreaterThan(try XCTUnwrap(result?.monotony), 2.0)
    }

    // MARK: - Readiness ACWR Zone Tests

    func testReadinessAdvisoryZoneSoftens() {
        // ATL=40, CTL=50 → ratio 0.8 → base readiness 85.
        // ACWR 1.4: excess=0.1, penalty=0.10 → 85*0.9 ≈ 76.5
        let readiness = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 90.0, todayTrimp: 0, ctl: 50,
            atl: 40, morningATL: nil, acuteChronicRatio: 1.4
        )
        XCTAssertLessThan(readiness, 85.0)
        XCTAssertGreaterThan(
            readiness,
            60.0,
            "ACWR 1.4 should scale down, not hard-cap to old level"
        )
    }

    func testReadinessDangerZoneContinuousPenalty() {
        // Dampener interaction (test pinned to match the
        // shipped behaviour — see RecoveryScoreCalculator+Readiness.
        // applyACWRModifier doc-comment for the "real tester case"
        // rationale that introduced these dampeners):
        //   ATL=40, CTL=50 → capacityRatio 0.8 → base readiness 85.
        //   ACWR 1.6 → excess 0.3, raw penalty 0.20 (=base 0.05 + 0.3·0.50).
        //   acwrConfidence at CTL=50 → min(50/50, 1.0) = 1.0 (full).
        //   recoveryScore=90 ≥ acwrRescueRecoveryThreshold (70)
        //     → penalty capped at acwrPenaltyAutonomicRescueCap (0.10).
        //   readiness after ACWR = 85·(1 − 0.10) = 76.5.
        //   recovery modulation: readiness < recoveryScore (76.5 < 90),
        //     readiness += (90 − 76.5)·recoveryUpliftFraction (0.30) ≈ 80.55.
        // The autonomic rescue is intentional: when HRV directly says
        // "recovered", the ACR proxy shouldn't override it.
        let readiness = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 90.0, todayTrimp: 0, ctl: 50,
            atl: 40, morningATL: nil, acuteChronicRatio: 1.6
        )
        XCTAssertEqual(
            readiness,
            80.55,
            accuracy: 0.5,
            "ACWR 1.6 with recovery=90 + CTL=50: rescue caps the penalty and recovery uplift modulates back"
        )
        XCTAssertLessThan(
            readiness,
            85.0,
            "ACWR 1.6 still registers a (capped) penalty even with autonomic rescue"
        )
        XCTAssertGreaterThan(
            readiness,
            70.0,
            "ACWR 1.6 with high HRV recovery should not crush readiness — autonomic rescue is the design"
        )
    }

    // MARK: - Readiness Capacity Ratio Tests

    func testReadinessDrivenByCapacityRatio() {
        // CTL=40, ATL=30, no strain → ratio 30/40 = 0.75 → readiness ~86
        // Purely fitness-fatigue driven, independent of recovery score.
        let readiness = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 95.0, todayTrimp: 0, ctl: 40,
            atl: 30, morningATL: nil, acuteChronicRatio: nil
        )
        XCTAssertGreaterThan(
            readiness,
            80.0,
            "Low capacity ratio (0.75) should yield high readiness"
        )
        XCTAssertLessThanOrEqual(
            readiness,
            100.0,
            "Readiness should be within 0-100 range"
        )
    }

    func testReadinessOverloadedAthlete() {
        // CTL=40, ATL=55 → ratio 55/40 = 1.375 → model readiness ~42.5
        // Recovery uplift: 42.5 + (90-42.5)*0.30 = 56.75. Overreaching zone.
        let readiness = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 90.0, todayTrimp: 0, ctl: 40,
            atl: 55, morningATL: nil, acuteChronicRatio: nil
        )
        XCTAssertLessThan(
            readiness,
            60.0,
            "Overloaded athlete (ratio > 1.3) should have suppressed readiness"
        )
    }

    func testReadinessFreshnessGainFromDissipation() {
        // Morning ATL=60, current ATL=55 → 5 points dissipated.
        let withDissipation = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 90.0, todayTrimp: 0, ctl: 50,
            atl: 55, morningATL: 60, acuteChronicRatio: nil
        )
        let withoutDissipation = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 90.0, todayTrimp: 0, ctl: 50,
            atl: 55, morningATL: nil, acuteChronicRatio: nil
        )
        XCTAssertGreaterThan(
            withDissipation,
            withoutDissipation,
            "ATL dissipation should improve readiness"
        )
    }

    func testReadinessStrainIncreasesEffectiveLoad() {
        // CTL=40, ATL=30, todayTrimp=100 → effective load = 30 + 35 = 65
        // ratio = 65/40 = 1.625 → readiness ~25
        let readiness = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 90.0, todayTrimp: 100, ctl: 40,
            atl: 30, morningATL: nil, acuteChronicRatio: nil
        )
        XCTAssertLessThan(
            readiness,
            75.0,
            "Today's strain should reduce readiness by increasing effective load"
        )
    }

    func testReadinessACWRSuppression() {
        // Same training state, but with high ACWR → reduced readiness.
        let base = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 90.0, todayTrimp: 0, ctl: 40,
            atl: 40, morningATL: nil, acuteChronicRatio: 1.0
        )
        let suppressed = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 90.0, todayTrimp: 0, ctl: 40,
            atl: 40, morningATL: nil, acuteChronicRatio: 1.6
        )
        XCTAssertLessThan(
            suppressed,
            base,
            "ACWR > 1.3 should suppress readiness"
        )
    }

    // MARK: - Score versioning
    //
    // "Changing history is a product-migration concern, not a scientific
    // justification." Several inputs to this score are unvalidated
    // heuristics, and the argument for leaving them alone is that
    // changing them rewrites stored scores. Stamping the version removes that
    // argument — a future version can drop a heuristic and the archive stays
    // readable and correctly attributed.

    func testFreshBreakdownCarriesTheCurrentScoringVersion() {
        let b = RecoveryScoreCalculator.ScoreBreakdown(
            compositeScore: 72, tier: 3, factors: [], penalties: []
        )
        XCTAssertEqual(b.scoringVersion, ScoringVersion.current)
    }

    func testLegacyBreakdownDecodesAsUnversionedNotAsCurrent() throws {
        // A record written before the field existed. It could have come from v1
        // or v2 and the archive cannot tell, so it must NOT claim to be current.
        let legacy = Data("""
        {"compositeScore": 68, "tier": 2, "factors": [], "penalties": []}
        """.utf8)
        let decoded = try JSONDecoder().decode(
            RecoveryScoreCalculator.ScoreBreakdown.self, from: legacy
        )
        XCTAssertEqual(decoded.scoringVersion, ScoringVersion.unversioned)
        XCTAssertNotEqual(decoded.scoringVersion, ScoringVersion.current,
                          "an unknown version must never be reported as the current one")
        XCTAssertEqual(decoded.compositeScore, 68, accuracy: 0.001)
    }

    func testVersionSurvivesAnEncodeDecodeRoundTrip() throws {
        let b = RecoveryScoreCalculator.ScoreBreakdown(
            compositeScore: 81, tier: 3, factors: [], penalties: []
        )
        let data = try JSONEncoder().encode(b)
        let back = try JSONDecoder().decode(RecoveryScoreCalculator.ScoreBreakdown.self, from: data)
        XCTAssertEqual(back.scoringVersion, ScoringVersion.current)
    }
}
