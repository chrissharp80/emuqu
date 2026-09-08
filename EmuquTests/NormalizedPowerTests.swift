@testable import Emuqu
import XCTest

/// Tests for normalized power.
///
/// NP is the Coggan metric that says how hard a ride
/// actually was: a 30-second rolling mean, raised to the fourth power,
/// averaged, then fourth-rooted. The fourth power is the whole point — it
/// weights surges far above steady effort, so a ride with the same average
/// power scores higher when it was ragged. Getting it wrong misstates the
/// intensity of every ride and everything derived from it.
@MainActor
final class NormalizedPowerTests: XCTestCase {
    private func samples(_ watts: [Int]) -> [WorkoutSample] {
        watts.enumerated().map { i, w in
            WorkoutSample(offsetSec: i, powerWatts: w)
        }
    }

    // MARK: - The window requirement

    func testFewerThanThirtySamplesHasNoNormalizedPower() {
        // One full 30-second window is the minimum the definition allows.
        // Returning a number from 29 samples would be an invented figure.
        XCTAssertNil(WorkoutRecorder.computeNormalizedPower(samples: samples(Array(repeating: 200, count: 29))))
    }

    func testExactlyThirtySamplesProducesAValue() {
        let np = WorkoutRecorder.computeNormalizedPower(samples: samples(Array(repeating: 200, count: 30)))
        XCTAssertEqual(np ?? 0, 200, accuracy: 0.001)
    }

    func testNoSamplesAtAllIsNil() {
        XCTAssertNil(WorkoutRecorder.computeNormalizedPower(samples: []))
    }

    func testSamplesWithoutPowerAreExcluded() {
        // A ride with no power meter must not produce a power figure.
        let noPower = (0 ..< 60).map { WorkoutSample(offsetSec: $0) }
        XCTAssertNil(WorkoutRecorder.computeNormalizedPower(samples: noPower))
    }

    func testMixedSamplesUseOnlyThoseWithPower() {
        // 40 with power, 40 without. The 40 with power clear the 30 threshold.
        var mixed = samples(Array(repeating: 250, count: 40))
        mixed += (0 ..< 40).map { WorkoutSample(offsetSec: 100 + $0) }
        let np = WorkoutRecorder.computeNormalizedPower(samples: mixed)
        XCTAssertEqual(np ?? 0, 250, accuracy: 0.001, "gaps must not drag the figure down")
    }

    // MARK: - Steady effort

    func testConstantPowerEqualsThatPower() {
        let np = WorkoutRecorder.computeNormalizedPower(samples: samples(Array(repeating: 200, count: 60)))
        XCTAssertEqual(np ?? 0, 200, accuracy: 0.001)
    }

    // MARK: - The fourth power is what makes NP useful

    func testSurgesPushNormalizedPowerAboveTheAverage() {
        // 90s at 100 W then 30s at 500 W — average 200 W, but the ride was
        // nothing like a steady 200 W effort. NP must say so.
        let ragged = Array(repeating: 100, count: 90) + Array(repeating: 500, count: 30)
        let np = WorkoutRecorder.computeNormalizedPower(samples: samples(ragged)) ?? 0
        let average = Double(ragged.reduce(0, +)) / Double(ragged.count)
        XCTAssertEqual(average, 200, accuracy: 0.001, "fixture sanity: the average really is 200")
        XCTAssertEqual(np, 273.1329, accuracy: 0.01)
        XCTAssertGreaterThan(np, average, "a ragged ride must score above its own average")
    }

    /// Fast alternation is smoothed away by the 30-second window, which is why
    /// the window exists: NP measures sustained surges, not sample-to-sample
    /// noise. Same average, same NP.
    func testRapidAlternationIsSmoothedByTheWindow() {
        let alternating = (0 ..< 120).map { $0.isMultiple(of: 2) ? 300 : 100 }
        let np = WorkoutRecorder.computeNormalizedPower(samples: samples(alternating)) ?? 0
        XCTAssertEqual(np, 200, accuracy: 0.01, "30s smoothing removes alternation")
    }

    func testLongerSurgesScoreHigherThanShorterOnes() {
        let shortSurge = Array(repeating: 100, count: 110) + Array(repeating: 500, count: 10)
        let longSurge = Array(repeating: 100, count: 80) + Array(repeating: 500, count: 40)
        let shortNP = WorkoutRecorder.computeNormalizedPower(samples: samples(shortSurge)) ?? 0
        let longNP = WorkoutRecorder.computeNormalizedPower(samples: samples(longSurge)) ?? 0
        XCTAssertGreaterThan(longNP, shortNP, "a longer surge is a harder ride")
    }

    // MARK: - Degenerate power

    func testZeroPowerThroughoutIsZeroNotNil() {
        // Coasting is a real reading, distinct from "no power meter".
        let np = WorkoutRecorder.computeNormalizedPower(samples: samples(Array(repeating: 0, count: 60)))
        XCTAssertEqual(np ?? -1, 0, accuracy: 0.001)
    }
}
