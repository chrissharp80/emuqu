@testable import Emuqu
import XCTest

/// Tests for RecoveryScoreCalculator.calculateReadiness — the capacity-ratio
/// model that computes training readiness from fitness-fatigue dynamics
/// (CTL/ATL/ACWR), modulated by recovery score (Plews et al. 2013, Buchheit 2014).
final class ReadinessCalculationTests: XCTestCase {
    // MARK: - Capacity Ratio Model (core behavior)

    func testFitAthleteAbsorbsHikeEasily() {
        // CTL=60, ATL=30 (moderate fatigue), 6-mile hike (~120 TRIMP).
        // Capacity ratio ≈ (30 + 120*0.35) / 60 = 72/60 = 1.20 → readiness ~57
        // A fit athlete with moderate fatigue absorbs a hike — stays moderate.
        let readiness = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 90,
            todayTrimp: 120,
            ctl: 60,
            atl: 30,
            morningATL: nil,
            acuteChronicRatio: nil
        )
        XCTAssertGreaterThan(
            readiness,
            45,
            "Fit athlete (CTL=60) doing a hike should retain moderate readiness"
        )
    }

    func testUnfitAthleteCrushedBySameHike() {
        // CTL=20, ATL=18 (near capacity already), 6-mile hike (~120 TRIMP).
        // Capacity ratio = (18 + 120*0.35) / 20 = 60/20 = 3.0 → model readiness 10 (floor)
        // Recovery uplift: 10 + (90-10)*0.30 = 34. Still quite low.
        let readiness = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 90,
            todayTrimp: 120,
            ctl: 20,
            atl: 18,
            morningATL: nil,
            acuteChronicRatio: nil
        )
        XCTAssertLessThan(
            readiness,
            40,
            "Unfit athlete (CTL=20, ATL=18) doing a hike should have low readiness"
        )
    }

    func testFitVsUnfitDramaticDifference() {
        // Same workout, same recovery score — vastly different readiness.
        let fitReadiness = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 90,
            todayTrimp: 120,
            ctl: 60,
            atl: 30,
            morningATL: nil,
            acuteChronicRatio: nil
        )
        let unfitReadiness = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 90,
            todayTrimp: 120,
            ctl: 20,
            atl: 18,
            morningATL: nil,
            acuteChronicRatio: nil
        )
        XCTAssertGreaterThan(
            fitReadiness - unfitReadiness,
            20,
            "Fit and unfit athletes should have dramatically different readiness for same workout"
        )
    }

    func testRestDayHighReadiness() {
        // No fatigue, no strain → readiness should be very high.
        let readiness = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 90,
            todayTrimp: 0,
            ctl: 60,
            atl: 0,
            morningATL: nil,
            acuteChronicRatio: nil
        )
        XCTAssertGreaterThanOrEqual(
            readiness,
            85,
            "Rest day with no fatigue should yield high readiness"
        )
    }

    func testMatchedLoadModerateReadiness() {
        // ATL ≈ CTL (ratio ≈ 1.0), no today's strain → model readiness 70.
        // Recovery uplift: 70 + (90-70)*0.30 = 76. Moderate range.
        let readiness = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 90,
            todayTrimp: 0,
            ctl: 60,
            atl: 60,
            morningATL: nil,
            acuteChronicRatio: nil
        )
        XCTAssertEqual(
            readiness,
            76,
            accuracy: 5.0,
            "Matched load (ATL=CTL) should give moderate readiness"
        )
    }

    // MARK: - No Training History (CTL < 5)

    func testNoTrainingHistoryRestDayIsHigh() {
        // CTL=0, no load → model says 100, but fallback blends to recovery (90).
        let readiness = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 90,
            todayTrimp: 0,
            ctl: 0,
            atl: 0,
            morningATL: nil,
            acuteChronicRatio: nil
        )
        XCTAssertGreaterThanOrEqual(
            readiness,
            85,
            "No training history + no load → high readiness (clamped toward recovery)"
        )
    }

    func testNoTrainingHistoryHeavyWorkoutCrashes() {
        // CTL=0, big workout → model says ~10 (overloaded).
        // Recovery uplift: 10 + (90-10)*0.30 = 34. Still low readiness.
        let readiness = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 90,
            todayTrimp: 200,
            ctl: 0,
            atl: 0,
            morningATL: nil,
            acuteChronicRatio: nil
        )
        XCTAssertLessThan(
            readiness,
            40,
            "Untrained athlete doing big workout should have low readiness"
        )
    }

    // MARK: - Confidence-Weighted Fallback (sparse data)

    func testSparseDataFallbackToRecovery() {
        // CTL=0 (no training data): model says 100 but we have NO confidence
        // in the model. Readiness should fall back to recovery score.
        let readiness = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 75,
            todayTrimp: 0,
            ctl: 0,
            atl: 0,
            morningATL: nil,
            acuteChronicRatio: nil
        )
        XCTAssertEqual(
            readiness,
            75,
            accuracy: 1.0,
            "With zero CTL, readiness should equal recovery score"
        )
    }

    func testSparseDataFallbackDoesNotOverrideOverload() {
        // CTL=3 (sparse data), heavy workout → model says readiness is very low.
        // Fallback should NOT override this because the training signal is real.
        let readiness = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 85,
            todayTrimp: 150,
            ctl: 3,
            atl: 10,
            morningATL: nil,
            acuteChronicRatio: nil
        )
        XCTAssertLessThan(
            readiness,
            40,
            "Overload signal should be trusted even with sparse training data"
        )
    }

    func testLowCTLRecoveryDominates() {
        // CTL=5: model says 100 (no load), but recovery 70 acts as soft ceiling.
        // modelTrust = (5/40)*0.4 = 0.05, readiness = 70 + 30*0.05 ≈ 71.5.
        // Recovery dominates when training history is sparse.
        let readiness = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 70,
            todayTrimp: 0,
            ctl: 5,
            atl: 0,
            morningATL: nil,
            acuteChronicRatio: nil
        )
        XCTAssertEqual(
            readiness,
            71.5,
            accuracy: 3.0,
            "CTL=5: recovery should dominate readiness (low model trust)"
        )
    }

    func testHighCTLRecoveryStillInfluences() {
        // CTL=60 (strong model): model says 100, recovery says 60.
        // modelTrust = min(60/40,1)*0.4 = 0.4, readiness = 60 + 40*0.4 = 76.
        // Even with high CTL, poor recovery pulls readiness down.
        let readinessGoodRecovery = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 90,
            todayTrimp: 0,
            ctl: 60,
            atl: 0,
            morningATL: nil,
            acuteChronicRatio: nil
        )
        let readinessPoorRecovery = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 40,
            todayTrimp: 0,
            ctl: 60,
            atl: 0,
            morningATL: nil,
            acuteChronicRatio: nil
        )
        XCTAssertGreaterThan(
            readinessGoodRecovery,
            readinessPoorRecovery,
            "Poor recovery should pull readiness down even with high CTL"
        )
        XCTAssertGreaterThan(
            readinessPoorRecovery,
            40,
            "Model should still provide some uplift above recovery at high CTL"
        )
    }

    // MARK: - Today's Strain

    func testStrainReducesReadiness() {
        let base = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 90,
            todayTrimp: 0,
            ctl: 50,
            atl: 40,
            morningATL: nil,
            acuteChronicRatio: nil
        )
        let afterStrain = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 90,
            todayTrimp: 200,
            ctl: 50,
            atl: 40,
            morningATL: nil,
            acuteChronicRatio: nil
        )
        XCTAssertLessThan(afterStrain, base, "Exercise strain should reduce readiness")
    }

    func testHigherFitnessReducesStrainImpact() {
        let unfitReadiness = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 90,
            todayTrimp: 200,
            ctl: 20,
            atl: 15,
            morningATL: nil,
            acuteChronicRatio: nil
        )
        let fitReadiness = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: 90,
            todayTrimp: 200,
            ctl: 100,
            atl: 80,
            morningATL: nil,
            acuteChronicRatio: nil
        )
        XCTAssertGreaterThan(
            fitReadiness,
            unfitReadiness,
            "Higher CTL should dampen strain impact"
        )
    }

    /// `min(100, x)` passes a NaN or infinity through as 100, so a broken
    /// input would read as fully ready. A non-finite result degrades to the
    /// midpoint instead.
    func testNonFiniteResultDegradesToTheMidpointNotFullyReady() {
        let readiness = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: .infinity,
            todayTrimp: 0,
            ctl: 40,
            atl: 30
        )
        XCTAssertEqual(readiness, 50)
    }
}
