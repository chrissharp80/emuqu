@testable import Emuqu
import XCTest

/// Tests for sustained elevation gain/loss accumulation.
///
/// This produces the elevation gain shown on
/// every workout and feeds grade-adjusted pace, so it changes the effort a run
/// is credited with.
///
/// The threshold exists to reject DEM noise: a 10 m dataset wobbles by a few
/// metres between samples, and counting that wobble inflates gain badly over a
/// long route. What it must NOT do is reject real climbs.
final class TopoElevationServiceTests: XCTestCase {
    private func gainLoss(_ elevations: [Double], threshold: Double = 10) -> (gain: Double, loss: Double) {
        TopoElevationService.sustainedClimb(in: elevations, threshold: threshold)
    }

    // MARK: - The bug this fixed

    func testQuantisedClimbIsNotDiscarded() {
        // DEM elevations are quantised — OpenTopoData returns discrete metres
        // — so equal consecutive samples are routine mid-climb. Treating a
        // flat step as a direction reversal chopped this 20 m climb into four
        // 5 m fragments and the threshold discarded every one: reported gain
        // was ZERO.
        let climb: [Double] = [0, 0, 5, 5, 10, 10, 15, 15, 20, 20]
        let result = gainLoss(climb)
        XCTAssertEqual(result.gain, 20, accuracy: 0.001, "a quantised 20 m climb is still 20 m")
        XCTAssertEqual(result.loss, 0, accuracy: 0.001)
    }

    func testQuantisedDescentIsNotDiscarded() {
        let descent: [Double] = [20, 20, 15, 15, 10, 10, 5, 5, 0, 0]
        let result = gainLoss(descent)
        XCTAssertEqual(result.loss, 20, accuracy: 0.001)
        XCTAssertEqual(result.gain, 0, accuracy: 0.001)
    }

    func testLongFlatSectionMidClimbDoesNotSplitIt() {
        // Crossing a plateau partway up a hill is one climb, not two.
        let climb: [Double] = [0, 4, 8, 8, 8, 8, 8, 12, 16, 20]
        XCTAssertEqual(gainLoss(climb).gain, 20, accuracy: 0.001)
    }

    // MARK: - The threshold still rejects noise

    func testNoiseBelowThresholdIsRejected() {
        // Sensor wobble: repeated 2-3 m bumps that are not real terrain.
        // Counting these is what the threshold exists to prevent.
        let noise: [Double] = [0, 2, 0, 3, 0, 2, 0, 3, 0]
        let result = gainLoss(noise)
        XCTAssertEqual(result.gain, 0, accuracy: 0.001, "sub-threshold wobble must not count")
        XCTAssertEqual(result.loss, 0, accuracy: 0.001)
    }

    func testRunExactlyAtThresholdCounts() {
        XCTAssertEqual(gainLoss([0, 10]).gain, 10, accuracy: 0.001)
    }

    func testRunJustUnderThresholdDoesNot() {
        XCTAssertEqual(gainLoss([0, 9.99]).gain, 0, accuracy: 0.001)
    }

    // MARK: - Ordinary terrain

    func testClimbThenDescentCountsBoth() {
        let hill: [Double] = [0, 10, 20, 30, 20, 10, 0]
        let result = gainLoss(hill)
        XCTAssertEqual(result.gain, 30, accuracy: 0.001)
        XCTAssertEqual(result.loss, 30, accuracy: 0.001)
    }

    func testRollingTerrainAccumulatesEachSustainedRun() {
        let rolling: [Double] = [0, 15, 0, 15, 0]
        let result = gainLoss(rolling)
        XCTAssertEqual(result.gain, 30, accuracy: 0.001)
        XCTAssertEqual(result.loss, 30, accuracy: 0.001)
    }

    func testEntirelyFlatTerrainHasNoGain() {
        let result = gainLoss([10, 10, 10, 10, 10])
        XCTAssertEqual(result.gain, 0, accuracy: 0.001)
        XCTAssertEqual(result.loss, 0, accuracy: 0.001)
    }

    // MARK: - Degenerate input

    func testSingleSampleIsSafe() {
        let result = gainLoss([5])
        XCTAssertEqual(result.gain, 0, accuracy: 0.001)
        XCTAssertEqual(result.loss, 0, accuracy: 0.001)
    }

    func testEmptyInputIsSafe() {
        let result = gainLoss([])
        XCTAssertEqual(result.gain, 0, accuracy: 0.001)
        XCTAssertEqual(result.loss, 0, accuracy: 0.001)
    }

    // MARK: - Downsampling

    func testDownsampleKeepsFirstAndLast() {
        // The endpoints anchor the route; losing either shifts total gain.
        let idx = TopoElevationService.downsampleIndices(count: 1_000, target: 100)
        XCTAssertEqual(idx.first, 0)
        XCTAssertEqual(idx.last, 999)
        XCTAssertEqual(idx.count, 100)
    }

    func testDownsampleIsMonotonic() {
        let idx = TopoElevationService.downsampleIndices(count: 500, target: 60)
        XCTAssertEqual(idx, idx.sorted(), "indices must not go backwards along the route")
    }

    func testDownsampleShorterThanTargetIsUnchanged() {
        XCTAssertEqual(TopoElevationService.downsampleIndices(count: 5, target: 100), Array(0 ..< 5))
    }
}
