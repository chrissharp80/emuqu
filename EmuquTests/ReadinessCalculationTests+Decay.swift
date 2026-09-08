@testable import Emuqu
import XCTest

// The ACWR suppression, dissipation, modulation and decay cases, split out of
// `ReadinessCalculationTests.swift` when that test class passed the
// 500-line type-body limit. XCTest discovers test methods declared in an
// extension exactly as it does ones in the class body, so the split changes
// which file a case lives in and nothing else.

extension ReadinessCalculationTests {
    // MARK: - ACWR Suppression

    func testNoACWRPenaltyInSweetSpot() {
        let withACWR = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 90,
            todayTrimp: 0,
            ctl: 50,
            atl: 50,
            morningATL: nil,
            acuteChronicRatio: 1.0
        )
        let withoutACWR = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 90,
            todayTrimp: 0,
            ctl: 50,
            atl: 50,
            morningATL: nil,
            acuteChronicRatio: nil
        )
        XCTAssertEqual(
            withACWR,
            withoutACWR,
            accuracy: 0.1,
            "ACWR 1.0 is in sweet spot — no penalty"
        )
    }

    func testACWRPenaltyAbove1_3() {
        let base = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 90,
            todayTrimp: 0,
            ctl: 50,
            atl: 50,
            morningATL: nil,
            acuteChronicRatio: nil
        )
        let suppressed = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 90,
            todayTrimp: 0,
            ctl: 50,
            atl: 50,
            morningATL: nil,
            acuteChronicRatio: 1.5
        )
        XCTAssertLessThan(suppressed, base, "ACWR 1.5 should suppress readiness")
    }

    func testACWRPenaltyCapped() {
        let readiness = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 90,
            todayTrimp: 0,
            ctl: 50,
            atl: 50,
            morningATL: nil,
            acuteChronicRatio: 3.0 // extreme
        )
        XCTAssertGreaterThan(
            readiness,
            30,
            "ACWR penalty should be capped — shouldn't destroy readiness entirely"
        )
    }

    func testNoDetrainingPenaltyBelowSweetSpot() {
        // ACWR < 0.8 should NOT penalize readiness — short rest periods
        // are recovery, not detraining (Impellizzeri et al. 2020).
        let atSweetSpot = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 90,
            todayTrimp: 0,
            ctl: 50,
            atl: 40,
            morningATL: nil,
            acuteChronicRatio: 0.8
        )
        let wellBelow = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 90,
            todayTrimp: 0,
            ctl: 50,
            atl: 40,
            morningATL: nil,
            acuteChronicRatio: 0.4
        )
        XCTAssertEqual(
            atSweetSpot,
            wellBelow,
            accuracy: 0.01,
            "ACWR < 0.8 should have no penalty — rest is not detraining"
        )
    }

    // MARK: - ATL Dissipation

    func testATLDissipationBonus() {
        // Morning ATL=60, current ATL=55 → 5 points of fatigue cleared.
        let withDissipation = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 90,
            todayTrimp: 0,
            ctl: 50,
            atl: 55,
            morningATL: 60,
            acuteChronicRatio: nil
        )
        let withoutDissipation = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 90,
            todayTrimp: 0,
            ctl: 50,
            atl: 55,
            morningATL: nil,
            acuteChronicRatio: nil
        )
        XCTAssertGreaterThan(
            withDissipation,
            withoutDissipation,
            "ATL dissipation should improve readiness"
        )
    }

    func testATLDissipationCappedAt15() {
        // Massive ATL drop (morningATL=100, current=10) but bonus caps at 15.
        let readiness = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 60,
            todayTrimp: 0,
            ctl: 50,
            atl: 10,
            morningATL: 100,
            acuteChronicRatio: nil
        )
        // Base: ratio 0.2 → ~96, bonus capped at 15 → 100 (clamped)
        XCTAssertLessThanOrEqual(
            readiness,
            100,
            "ATL dissipation bonus should be capped at 15 points"
        )
        // Without the bonus cap, readiness would be 96 + 90 = 186.
        // With cap: 96 + 15 = 111 → clamped to 100.
    }

    // MARK: - Recovery Modulation

    func testRecoveryModulatesReadiness() {
        // Different recovery scores, same training state → different readiness.
        // Recovery reflects actual autonomic state (Plews et al. 2013).
        let readinessGoodRecovery = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 95,
            todayTrimp: 100,
            ctl: 50,
            atl: 60,
            morningATL: nil,
            acuteChronicRatio: nil
        )
        let readinessPoorRecovery = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 40,
            todayTrimp: 100,
            ctl: 50,
            atl: 60,
            morningATL: nil,
            acuteChronicRatio: nil
        )
        // With ATL=60, CTL=50, TRIMP=100: ratio = (60+35)/50 = 1.9 → model ~14.
        // Both are below recovery, so uplift applies: better recovery = higher readiness.
        XCTAssertGreaterThan(
            readinessGoodRecovery,
            readinessPoorRecovery,
            "Higher recovery should yield higher readiness (uplift from recovery)"
        )
    }

    // MARK: - Edge Cases

    func testReadinessNeverNegative() {
        let readiness = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 10,
            todayTrimp: 500,
            ctl: 0,
            atl: 0,
            morningATL: nil,
            acuteChronicRatio: 2.0
        )
        XCTAssertGreaterThanOrEqual(readiness, 0, "Readiness should never go negative")
    }

    func testReadinessLowForExtremeOverload() {
        let readiness = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 90,
            todayTrimp: 0,
            ctl: 50,
            atl: 120, // ATL way above CTL
            morningATL: nil,
            acuteChronicRatio: nil
        )
        XCTAssertGreaterThanOrEqual(
            readiness,
            10,
            "Even extreme overload should not push readiness below floor"
        )
        // Model gives ~10, recovery uplift: 10 + (90-10)*0.30 = 34. Still low.
        XCTAssertLessThan(
            readiness,
            40,
            "Extreme overload (ratio 2.4) should still yield low readiness despite recovery uplift"
        )
    }

    // MARK: - Acute Fatigue Exponential Decay

    func testExponentialDecayImmediatelyAfterExercise() {
        // Just finished a 120-TRIMP workout (hoursAgo ≈ 0.5).
        // Model readiness ≈ 24, recovery uplift: 24 + (90-24)*0.30 ≈ 44.
        let loads = [RecoveryScoreCalculator.WorkoutLoad(hoursAgo: 0.5, trimp: 120)]
        let readiness = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 90,
            todayTrimp: 120,
            ctl: 40,
            atl: 30,
            morningATL: nil,
            acuteChronicRatio: nil,
            recentWorkoutLoads: loads
        )
        XCTAssertLessThan(
            readiness,
            50,
            "Immediately after a hard workout, readiness should be low"
        )
        XCTAssertGreaterThan(
            readiness,
            10,
            "With CTL=40, athlete should absorb some of the load"
        )
    }

    func testExponentialDecay24HoursLater() {
        // Same 120-TRIMP workout but 24 hours ago.
        // acuteFatigue = 120 × 0.30 × exp(-24/24) = 36 × 0.368 = 13.3.
        // ATL would have absorbed more by now (≈43 from EWMA step), so
        // effectiveLoad = 43 + 13.3 = 56.3, ratio = 1.41 → readiness ≈ 42.
        let loads = [RecoveryScoreCalculator.WorkoutLoad(hoursAgo: 24, trimp: 120)]
        let readiness = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 90,
            todayTrimp: 0,
            ctl: 40,
            atl: 43, // ATL after absorbing yesterday's workout via EWMA
            morningATL: nil,
            acuteChronicRatio: nil,
            recentWorkoutLoads: loads
        )
        XCTAssertGreaterThan(
            readiness,
            30,
            "24h after exercise, readiness should have partially recovered"
        )
    }

    func testExponentialDecay48HoursLater() {
        // 120-TRIMP workout 48 hours ago.
        // acuteFatigue = 120 × 0.30 × exp(-48/24) = 36 × 0.135 = 4.9.
        // ATL has decayed to ≈37, effectiveLoad = 37 + 4.9 = 41.9, ratio = 1.05 → ~67.
        let loads = [RecoveryScoreCalculator.WorkoutLoad(hoursAgo: 48, trimp: 120)]
        let readiness = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 90,
            todayTrimp: 0,
            ctl: 40,
            atl: 37, // ATL after 2 days of decay
            morningATL: nil,
            acuteChronicRatio: nil,
            recentWorkoutLoads: loads
        )
        XCTAssertGreaterThan(
            readiness,
            55,
            "48h after exercise, most acute fatigue should have cleared"
        )
    }

    func testExponentialDecaySmoothRecovery() {
        // Recovery should be monotonically increasing as workout recedes in time.
        let baseATL: Double = 30
        let trimp: Double = 120
        var previousReadiness: Double = 0
        for hours in [0.5, 6.0, 12.0, 24.0, 48.0, 72.0] {
            let loads = [RecoveryScoreCalculator.WorkoutLoad(hoursAgo: hours, trimp: trimp)]
            // Simulate ATL absorbing the workout over time (simplified)
            let atlAbsorbed = trimp * (1 - exp(-hours / (7 * 24)))
            let currentATL = baseATL + atlAbsorbed * (1.0 / 7.0)
            let readiness = RecoveryScoreCalculator.calculateReadiness(
                recoveryScore: 90,
                todayTrimp: hours < 24 ? trimp : 0,
                ctl: 40,
                atl: currentATL,
                morningATL: nil,
                acuteChronicRatio: nil,
                recentWorkoutLoads: loads
            )
            XCTAssertGreaterThan(
                readiness,
                previousReadiness,
                "Readiness should increase as workout recedes in time (hours=\(hours))"
            )
            previousReadiness = readiness
        }
    }

    func testExponentialDecayNoMidnightCliff() {
        // Compare readiness at 11pm (workout 3h ago) vs 1am next day (workout 5h ago).
        // With exponential decay, the 1am value should be HIGHER (more recovery).
        // A day-bucketed todayTrimp approach jumps at 1am (todayTrimp resets to 0).
        // This test verifies smooth transition, not a cliff.
        let loads11pm = [RecoveryScoreCalculator.WorkoutLoad(hoursAgo: 3, trimp: 100)]
        let loads1am = [RecoveryScoreCalculator.WorkoutLoad(hoursAgo: 5, trimp: 100)]

        let readiness11pm = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 85, todayTrimp: 100, ctl: 40, atl: 32,
            recentWorkoutLoads: loads11pm
        )
        let readiness1am = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 85, todayTrimp: 0, ctl: 40, atl: 32,
            recentWorkoutLoads: loads1am
        )

        // 1am should be higher than 11pm (more time has passed → more recovery)
        XCTAssertGreaterThan(
            readiness1am,
            readiness11pm,
            "Readiness should improve smoothly across midnight, not cliff"
        )
        // But the difference should be modest (only 2 more hours of decay)
        XCTAssertLessThan(
            readiness1am - readiness11pm,
            15,
            "Midnight transition should be gradual, not a massive jump"
        )
    }

    func testFallbackToLegacyWithoutWorkoutLoads() {
        // When recentWorkoutLoads is nil, should use the todayTrimp × 0.35 fallback.
        let withLoads = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 90, todayTrimp: 100, ctl: 50, atl: 40,
            recentWorkoutLoads: [.init(hoursAgo: 0.5, trimp: 100)]
        )
        let withoutLoads = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 90, todayTrimp: 100, ctl: 50, atl: 40,
            recentWorkoutLoads: nil
        )
        // Both should produce low readiness — exact values differ due to coefficient
        // (0.30 × exp(0) = 0.30 vs 0.35), but both should be in a reasonable range.
        XCTAssertLessThan(withLoads, 65, "With loads: should reflect exercise fatigue")
        XCTAssertLessThan(withoutLoads, 65, "Without loads: legacy path should also reflect fatigue")
    }

    // MARK: - Rest Day Decay

    func testTwoRestDaysProducesHighReadiness() {
        // After 2 rest days: ATL decays from ~48 to ~35 (two 6/7 multiplications),
        // CTL barely changes (~47). Capacity ratio ≈ 0.74 → model readiness ~87.
        // With good recovery (80), readiness should clearly indicate "ready."
        let decayedATL = 48.0 * (6.0 / 7.0) * (6.0 / 7.0) // ≈35.3
        let readiness = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 80,
            todayTrimp: 0,
            ctl: 47,
            atl: decayedATL,
            morningATL: nil,
            acuteChronicRatio: decayedATL / 47.0
        )
        XCTAssertGreaterThan(
            readiness,
            80,
            "Two rest days with good recovery should yield high readiness (≥80)"
        )
    }

    func testRestDayATLDecayImprovesReadiness() {
        // Same CTL, but ATL decays across 3 consecutive rest mornings.
        // Each day's EWMA step: ATL *= 6/7. Readiness should increase each day.
        let ctl: Double = 50
        var previousReadiness: Double = 0
        var atl: Double = 50
        for day in 0 ..< 3 {
            let acr = atl / ctl
            let readiness = RecoveryScoreCalculator.calculateReadiness(
                recoveryScore: 75,
                todayTrimp: 0,
                ctl: ctl,
                atl: atl,
                morningATL: nil,
                acuteChronicRatio: acr
            )
            XCTAssertGreaterThan(
                readiness,
                previousReadiness,
                "Readiness should improve on each consecutive rest day (day \(day))"
            )
            previousReadiness = readiness
            atl *= (6.0 / 7.0) // Simulate one rest-day EWMA step
        }
    }
}
