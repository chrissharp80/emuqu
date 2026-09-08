@testable import Emuqu
import XCTest

/// Tests for the optical-interval quality gate.
///
/// This gate decides which pulses from a Verity Sense become heartbeats. It ran
/// in two places — the live stream and a recording pulled off the sensor's own
/// memory — reading its physiological range from two different constants, with
/// the offline copy at 0% coverage. Both said 300–2000 ms; nothing enforced
/// that they agree. One gate now, and these tests are what hold it.
final class StrapPPIFilterTests: XCTestCase {
    private func sample(_ ppInMs: Int, error: Int = 0, blocker: Int = 0) -> StrapPPISample {
        StrapPPISample(ppInMs: ppInMs, ppErrorEstimate: error, blockerBit: blocker)
    }

    // MARK: - The three gates

    /// A clean interval inside the physiological range is a heartbeat.
    func testACleanPlausibleIntervalIsAccepted() {
        XCTAssertEqual(StrapPPIFilter.acceptedInterval(sample(850)), 850)
    }

    /// The blocker bit is the sensor telling us it does not trust its own
    /// reading — motion, or poor skin contact. Trusting it anyway puts
    /// fabricated beats into the night.
    func testABlockedIntervalIsRejectedHoweverPlausible() {
        XCTAssertNil(StrapPPIFilter.acceptedInterval(sample(850, blocker: 1)))
        XCTAssertNil(StrapPPIFilter.acceptedInterval(sample(850, blocker: 2)))
    }

    /// The error estimate is in milliseconds, and RMSSD is computed from
    /// differences of these intervals — a ±30 ms error is larger than the
    /// signal being measured.
    func testAnIntervalAboveTheErrorCapIsRejected() {
        XCTAssertEqual(StrapPPIFilter.acceptedInterval(sample(850, error: StrapPPIFilter.maxErrorEstimateMs)), 850)
        XCTAssertNil(StrapPPIFilter.acceptedInterval(sample(850, error: StrapPPIFilter.maxErrorEstimateMs + 1)))
    }

    /// 300–2000 ms is 200–30 bpm. Outside that it is not a heartbeat.
    func testIntervalsOutsideThePhysiologicalRangeAreRejected() {
        XCTAssertNil(StrapPPIFilter.acceptedInterval(sample(299)))
        XCTAssertEqual(StrapPPIFilter.acceptedInterval(sample(300)), 300)
        XCTAssertEqual(StrapPPIFilter.acceptedInterval(sample(2_000)), 2_000)
        XCTAssertNil(StrapPPIFilter.acceptedInterval(sample(2_001)))
        XCTAssertNil(StrapPPIFilter.acceptedInterval(sample(0)))
        XCTAssertNil(StrapPPIFilter.acceptedInterval(sample(-5)))
    }

    /// The defect this type was created to make impossible: the live stream and
    /// the downloaded recording must filter identically, or the same night
    /// scores differently depending on how it was retrieved.
    func testTheGateReadsTheSharedPhysiologicalRange() {
        XCTAssertEqual(StrapPPIFilter.acceptedRange, HRVConstants.RRValidity.polarStreamRange)
        XCTAssertEqual(StrapPPIFilter.acceptedRange.lowerBound, HRVThresholds.minimumRRIntervalMs)
        XCTAssertEqual(StrapPPIFilter.acceptedRange.upperBound, HRVThresholds.maximumRRIntervalMs)
    }

    // MARK: - Building the series

    func testAcceptedIntervalsBecomeBeatsInOrder() {
        let points = StrapPPIFilter.rrPoints(from: [sample(800), sample(820), sample(810)])
        XCTAssertEqual(points.map(\.rr_ms), [800, 820, 810])
    }

    /// Each beat is stamped at the elapsed time of the beats before it.
    func testTheTimelineAccumulatesAcrossAcceptedBeats() {
        let points = StrapPPIFilter.rrPoints(from: [sample(800), sample(820), sample(810)])
        XCTAssertEqual(points.map(\.t_ms), [0, 800, 1_620])
    }

    /// Characterising the existing behaviour, not endorsing it: a rejected
    /// interval contributes no elapsed time, so `t_ms` counts accumulated good
    /// beats rather than wall clock. This is why window selection translates
    /// through `wallClockMs` instead of trusting `t_ms` across gaps.
    func testARejectedIntervalContributesNoElapsedTime() {
        let points = StrapPPIFilter.rrPoints(from: [
            sample(800),
            sample(900, blocker: 1),   // dropped
            sample(810)
        ])
        XCTAssertEqual(points.map(\.rr_ms), [800, 810])
        XCTAssertEqual(points.map(\.t_ms), [0, 800],
                       "the dropped beat's 900 ms does not advance the timeline")
    }

    /// A stretch of motion artefact yields nothing rather than a fabricated
    /// stretch of beats.
    func testARecordingOfNothingButArtefactYieldsNoBeats() {
        let points = StrapPPIFilter.rrPoints(from: [
            sample(850, blocker: 1),
            sample(850, error: 99),
            sample(120),
            sample(5_000)
        ])
        XCTAssertTrue(points.isEmpty)
    }

    func testAnEmptyRecordingYieldsNoBeats() {
        XCTAssertTrue(StrapPPIFilter.rrPoints(from: []).isEmpty)
    }

    /// Every beat that survives the filter is inside the physiological range —
    /// stated as a property so it holds for inputs nobody wrote down.
    func testEveryEmittedBeatIsPhysiologicallyPlausible() {
        let noisy = (0 ..< 400).map { i in
            sample(100 + i * 7, error: i % 40, blocker: i % 11 == 0 ? 1 : 0)
        }
        let points = StrapPPIFilter.rrPoints(from: noisy)
        XCTAssertFalse(points.isEmpty, "fixture must produce some accepted beats")
        for point in points {
            XCTAssertTrue(StrapPPIFilter.acceptedRange.contains(point.rr_ms),
                          "emitted an implausible beat: \(point.rr_ms) ms")
        }
    }

    /// Timestamps never go backwards, whatever the input — a non-monotonic
    /// series breaks every window scan downstream.
    func testTimestampsAreMonotonic() {
        let noisy = (0 ..< 200).map { i in
            sample(250 + i * 13, error: i % 25, blocker: i % 7 == 0 ? 1 : 0)
        }
        let points = StrapPPIFilter.rrPoints(from: noisy)
        for (earlier, later) in zip(points, points.dropFirst()) {
            XCTAssertLessThan(earlier.t_ms, later.t_ms)
        }
    }
}
