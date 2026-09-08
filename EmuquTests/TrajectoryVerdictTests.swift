@testable import Emuqu
import XCTest

/// Boundary coverage for `TrajectoryVerdict.compute` — the user-facing
/// 8-branch training-status classifier. The direction logic sits on
/// threshold boundaries, so a boundary regression could silently
/// mislabel a rising CTL as "Maintaining" or a recovery dip as
/// "Detraining". These table-drive each threshold edge.
final class TrajectoryVerdictTests: XCTestCase {

    /// Build Inputs with neutral defaults; override only what a case probes.
    private func inputs(
        currentCTL: Double = 40,
        ctlOneWeekAgo: Double? = 40,
        sampleCount: Int = 30,
        comebackActive: Bool = false,
        overreachActive: Bool = false,
        peakingDetected: Bool = false,
        rampRate: Double = 0,
        currentTSB: Double? = nil
    ) -> TrajectoryVerdict.Inputs {
        TrajectoryVerdict.Inputs(
            currentCTL: currentCTL,
            ctlOneWeekAgo: ctlOneWeekAgo,
            sampleCount: sampleCount,
            comebackActive: comebackActive,
            overreachActive: overreachActive,
            peakingDetected: peakingDetected,
            rampRate: rampRate,
            currentTSB: currentTSB
        )
    }

    // MARK: - Mode toggles win over automatic interpretation

    func testComebackWinsEvenWithRapidRamp() {
        let v = TrajectoryVerdict.compute(inputs(comebackActive: true, rampRate: 12))
        XCTAssertEqual(v, .comeback)
    }

    func testOverreachWinsOverAutomatic() {
        XCTAssertEqual(TrajectoryVerdict.compute(inputs(overreachActive: true, rampRate: 12)), .overreach)
    }

    func testPeakingWinsOverAutomatic() {
        XCTAssertEqual(TrajectoryVerdict.compute(inputs(peakingDetected: true, rampRate: -5)), .peaking)
    }

    func testComebackTakesPriorityOverOverreachAndPeaking() {
        let v = TrajectoryVerdict.compute(inputs(comebackActive: true, overreachActive: true, peakingDetected: true))
        XCTAssertEqual(v, .comeback)
    }

    // MARK: - Insufficient-data gate (sampleCount > 7 AND ctlOneWeekAgo != nil)

    func testSampleCountAtGateReturnsBuildingBaseline() {
        // sampleCount == 7 is NOT > 7 → building baseline.
        XCTAssertEqual(TrajectoryVerdict.compute(inputs(sampleCount: 7, rampRate: 5)), .buildingBaseline)
    }

    func testSampleCountJustAboveGateProceeds() {
        // sampleCount == 8 with a week-ago CTL → real interpretation (rising).
        XCTAssertEqual(TrajectoryVerdict.compute(inputs(sampleCount: 8, rampRate: 5)), .building)
    }

    func testNilWeekAgoCTLReturnsBuildingBaseline() {
        XCTAssertEqual(TrajectoryVerdict.compute(inputs(ctlOneWeekAgo: nil, sampleCount: 30, rampRate: 5)), .buildingBaseline)
    }

    // MARK: - Rising branch (delta > 1.5), rapid split at rampRate > 8

    func testDeltaJustAboveRisingThresholdBuilds() {
        XCTAssertEqual(TrajectoryVerdict.compute(inputs(rampRate: 1.6)), .building)
    }

    func testDeltaAtRisingThresholdMaintains() {
        // delta == 1.5 is NOT > 1.5 → maintaining.
        XCTAssertEqual(TrajectoryVerdict.compute(inputs(rampRate: 1.5)), .maintaining)
    }

    func testRampRateAtRapidBoundaryStillBuilds() {
        // rampRate == 8 is NOT > 8 → building, not rapidIncrease.
        XCTAssertEqual(TrajectoryVerdict.compute(inputs(rampRate: 8.0)), .building)
    }

    func testRampRateJustAboveRapidBoundaryIsRapidIncrease() {
        XCTAssertEqual(TrajectoryVerdict.compute(inputs(rampRate: 8.1)), .rapidIncrease)
    }

    // MARK: - Falling branch (delta below the detraining deadband), gated on TSB
    //
    // The deadband is -1.5 (TrajectoryVerdict.compute / RampBand). A ramp of
    // -1.6 is clearly below it, so these tests assert the "genuinely falling" verdict
    // regardless of the flag's state.

    func testFallingWithFreshTSBIsDetraining() {
        // delta -1.6 is below the detraining deadband, TSB -4 is NOT < -5 → detraining.
        XCTAssertEqual(TrajectoryVerdict.compute(inputs(rampRate: -1.6, currentTSB: -4)), .detraining)
    }

    func testFallingWithFatiguedTSBIsMaintaining() {
        // delta -1.6 below deadband, TSB -6 < -5 → user is grinding, not detraining.
        XCTAssertEqual(TrajectoryVerdict.compute(inputs(rampRate: -1.6, currentTSB: -6)), .maintaining)
    }

    func testTSBAtSuppressionBoundaryIsDetraining() {
        // TSB == -5 is NOT < -5 → detraining (boundary is exclusive).
        XCTAssertEqual(TrajectoryVerdict.compute(inputs(rampRate: -1.6, currentTSB: -5)), .detraining)
    }

    func testFallingWithNilTSBIsDetraining() {
        // nil TSB → legacy path (don't gate on fatigue).
        XCTAssertEqual(TrajectoryVerdict.compute(inputs(rampRate: -1.6, currentTSB: nil)), .detraining)
    }

    func testDeltaJustAboveFallingThresholdMaintains() {
        // delta -0.9 is NOT < -1 → maintaining.
        XCTAssertEqual(TrajectoryVerdict.compute(inputs(rampRate: -0.9, currentTSB: -4)), .maintaining)
    }

    // MARK: - Deep-fatigue high strain

    func testDeepNegativeTSBWithFallingCTLIsHighStrain() {
        // delta < -1 and TSB below the deep-fatigue threshold → high strain,
        // not the reassuring "Maintaining".
        let deep = TrajectoryVerdict.deepFatigueOverreachTSB - 5
        XCTAssertEqual(TrajectoryVerdict.compute(inputs(rampRate: -1.5, currentTSB: deep)), .highStrain)
    }

    func testBuildingRampWithDeepFatigueIsHighStrain() {
        // A rising CTL (delta > 1.5) at deep-negative TSB must read high strain,
        // NOT "Building" — deep fatigue outranks the build signal. This is the
        // two-surfaces-disagree bug: dashboard chip said High strain, the Load
        // & Trajectory detail said "Building — fitness rising sustainably" at
        // TSB -15.2.
        let deep = TrajectoryVerdict.deepFatigueOverreachTSB - 1 // -16
        XCTAssertEqual(TrajectoryVerdict.compute(inputs(rampRate: 2.0, currentTSB: deep)), .highStrain)
        // A far-above-rapid ramp at deep fatigue is still high strain, not rapidIncrease.
        XCTAssertEqual(TrajectoryVerdict.compute(inputs(rampRate: 12, currentTSB: deep)), .highStrain)
    }

    func testFlatCTLWithDeepFatigueIsHighStrain() {
        // The reported bug: a FLAT CTL (not falling) at deep-negative TSB used
        // to read "Maintaining". It must now flag high strain regardless of
        // CTL direction.
        let deep = TrajectoryVerdict.deepFatigueOverreachTSB - 3 // e.g. -18
        XCTAssertEqual(TrajectoryVerdict.compute(inputs(rampRate: 0.5, currentTSB: deep)), .highStrain)
    }

    func testTSBAtDeepFatigueBoundaryStaysMaintaining() {
        // Exactly the threshold is NOT below it → still moderate fatigue → maintaining.
        XCTAssertEqual(
            TrajectoryVerdict.compute(inputs(rampRate: -1.5, currentTSB: TrajectoryVerdict.deepFatigueOverreachTSB)),
            .maintaining
        )
    }

    func testModerateFatigueBetweenGatesStaysMaintaining() {
        // Between -5 and the deep threshold → maintaining (grinding, not a hole).
        XCTAssertEqual(TrajectoryVerdict.compute(inputs(rampRate: -1.5, currentTSB: -12)), .maintaining)
    }

    // MARK: - Flat branch

    func testFlatRampMaintains() {
        // rampRate 0 falls back to (currentCTL - weekAgoCTL); equal → 0 → maintaining.
        XCTAssertEqual(TrajectoryVerdict.compute(inputs(currentCTL: 40, ctlOneWeekAgo: 40, rampRate: 0)), .maintaining)
    }

    // MARK: - rampRate == 0 fallback to CTL delta

    func testZeroRampFallsBackToCTLDelta() {
        // rampRate 0 → delta = 50 - 45 = 5 > 1.5; rampRate not > 8 → building.
        XCTAssertEqual(TrajectoryVerdict.compute(inputs(currentCTL: 50, ctlOneWeekAgo: 45, rampRate: 0)), .building)
    }
}
