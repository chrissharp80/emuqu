@testable import Emuqu
import XCTest

/// Tests for route climb detection.
///
/// These runs become the "climb ahead" cues
/// the voice coach gives mid-run, so a split or missed climb means the user is
/// warned about the wrong hill — or half of one.
@MainActor
final class RouteClimbDetectionTests: XCTestCase {
    // MARK: - The bug this fixed

    func testFlatShelfDoesNotSplitAClimb() {
        // A shelf partway up a hill is still the same hill. Treating a flat
        // step as "not rising" closed the run, and the 30 m qualifying
        // threshold then discarded the shorter half.
        var alt: [Double] = []
        for i in 0 ..< 21 {
            if (9 ... 11).contains(i) { alt.append(alt[alt.count - 1]) } else {
                alt.append((alt.last ?? 0) + 3.5)
            }
        }
        let runs = Route.risingRuns(in: alt)
        XCTAssertEqual(runs.count, 1, "a shelf mid-climb must not split the climb in two")
        XCTAssertEqual(runs.first?.startIdx, 0)
        XCTAssertEqual(runs.first?.endIdx, alt.count - 1)
    }

    func testUnbrokenClimbIsOneRun() {
        let alt = (0 ..< 10).map { Double($0) * 5 }
        let runs = Route.risingRuns(in: alt)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.startIdx, 0)
        XCTAssertEqual(runs.first?.endIdx, 9)
    }

    // MARK: - A real descent still ends a climb

    func testDescentClosesTheRun() {
        let alt: [Double] = [0, 10, 20, 30, 20, 10, 0]
        let runs = Route.risingRuns(in: alt)
        XCTAssertEqual(runs.count, 1, "the descent is not part of the climb")
        XCTAssertEqual(runs.first?.endIdx, 3, "the run ends at the summit")
    }

    func testTwoHillsAreTwoRuns() {
        let alt: [Double] = [0, 10, 20, 10, 0, 10, 20]
        XCTAssertEqual(Route.risingRuns(in: alt).count, 2)
    }

    // MARK: - Degenerate terrain

    func testEntirelyFlatHasNoRuns() {
        XCTAssertTrue(Route.risingRuns(in: [10, 10, 10, 10]).isEmpty)
    }

    func testMonotonicDescentHasNoRuns() {
        XCTAssertTrue(Route.risingRuns(in: [30, 20, 10, 0]).isEmpty)
    }

    func testSingleSampleHasNoRuns() {
        XCTAssertTrue(Route.risingRuns(in: [10]).isEmpty)
    }

    func testEmptyInputHasNoRuns() {
        XCTAssertTrue(Route.risingRuns(in: []).isEmpty)
    }

    func testClimbRunningToTheEndIsClosed() {
        // Still ascending at the last sample — the run must still be emitted.
        let alt: [Double] = [0, 5, 10, 15]
        XCTAssertEqual(Route.risingRuns(in: alt).first?.endIdx, 3)
    }

    // MARK: - Smoothing

    func testSmoothingAveragesOverTheWindow() {
        let spiky: [Double] = [0, 0, 100, 0, 0, 0, 0]
        let smoothed = Route.smooth(spiky, window: 3)
        XCTAssertLessThan(smoothed[2], 100, "the spike must be pulled down by its neighbours")
        XCTAssertGreaterThan(smoothed[1], 0, "and its neighbours pulled up")
    }

    func testSmoothingPreservesLength() {
        let values = (0 ..< 30).map { Double($0) }
        XCTAssertEqual(Route.smooth(values, window: 5).count, 30)
    }

    func testSmoothingKeepsEndpoints() {
        // The window cannot centre on the first or last samples, so they pass
        // through — losing them would shift the whole profile.
        let values = (0 ..< 30).map { Double($0) }
        let smoothed = Route.smooth(values, window: 5)
        XCTAssertEqual(smoothed.first, values.first)
        XCTAssertEqual(smoothed.last, values.last)
    }

    func testWindowLargerThanInputIsReturnedUnchanged() {
        let values: [Double] = [1, 2, 3]
        XCTAssertEqual(Route.smooth(values, window: 99), values)
    }

    func testWindowOfOneIsANoOp() {
        let values: [Double] = [1, 5, 2, 8]
        XCTAssertEqual(Route.smooth(values, window: 1), values)
    }
}
