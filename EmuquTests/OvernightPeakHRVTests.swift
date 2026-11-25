@testable import Emuqu
import XCTest

/// The one peak-HRV search the Overnight screen and its PDF share
/// (`OvernightPeakHRV`): which sleep window it searches, and the peak it picks.
final class OvernightPeakHRVTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// 1000 ms beats, alternating ±`swing` ms inside `swingRange`, flat elsewhere.
    private func series(beats: Int, swing: Int, swingRange: Range<Int>) -> RRSeries {
        var t: Int64 = 0
        let points = (0 ..< beats).map { i -> RRPoint in
            let rr = swingRange.contains(i) ? 1000 + (i.isMultiple(of: 2) ? swing : -swing) : 1000
            defer { t += Int64(rr) }
            return RRPoint(t_ms: t, rr_ms: rr)
        }
        return RRSeries(points: points, sessionId: UUID(), startDate: start)
    }

    /// HealthKit's envelope first, then the stored sleep period, then the
    /// whole recording: the order the chart used and the PDF did not.
    func testTheSleepWindowPrefersHealthKitThenTheStoredPeriod() {
        let recording = series(beats: 3000, swing: 0, swingRange: 0 ..< 0)
        let end = recording.points.last?.t_ms ?? 0
        let healthKit = (start: start.addingTimeInterval(600), end: start.addingTimeInterval(1800))

        let fromHealthKit = OvernightPeakHRV.sleepWindowMs(series: recording, sessionStart: start, healthKit: healthKit, stored: (1000, 2000))
        let fromStored = OvernightPeakHRV.sleepWindowMs(series: recording, sessionStart: start, healthKit: nil, stored: (1000, 2_000_000))
        let fromRecording = OvernightPeakHRV.sleepWindowMs(series: recording, sessionStart: start, healthKit: nil, stored: (nil, nil))

        XCTAssertEqual(fromHealthKit.start, 600_000)
        XCTAssertEqual(fromHealthKit.end, 1_800_000)
        XCTAssertEqual(fromStored.start, 1000)
        XCTAssertEqual(fromStored.end, 2_000_000)
        XCTAssertEqual(fromRecording.start, 0)
        XCTAssertEqual(fromRecording.end, end)
    }

    /// The peak is the highest window centred in the band, even when a
    /// higher one lies outside it.
    func testThePeakIsTakenInsideTheBand() throws {
        let recording = series(beats: 3000, swing: 20, swingRange: 1300 ..< 1700)
        var withOutsideSwing = recording.points
        for i in 0 ..< 400 { withOutsideSwing[i] = RRPoint(t_ms: withOutsideSwing[i].t_ms, rr_ms: i.isMultiple(of: 2) ? 1040 : 960) }
        let samples = OvernightPeakHRV.rollingRMSSD(points: withOutsideSwing, flags: [])
        let band = OvernightPeakHRV.searchBand(sleepStartMs: 0, sleepEndMs: recording.points.last?.t_ms ?? 0)

        let peak = try XCTUnwrap(OvernightPeakHRV.peak(in: samples, band: band))

        XCTAssertTrue((band.earlyMs ... band.lateMs).contains(peak.timeMs))
        XCTAssertLessThan(peak.rmssd, try XCTUnwrap(samples.map(\.rmssd).max()))
    }

    /// With no window centred in the band, the whole recording is searched.
    func testWithNothingInTheBandTheWholeRecordingIsSearched() throws {
        let recording = series(beats: 1000, swing: 20, swingRange: 0 ..< 1000)
        let samples = OvernightPeakHRV.rollingRMSSD(points: recording.points, flags: [])
        let peak = try XCTUnwrap(OvernightPeakHRV.peak(in: samples, band: (earlyMs: -2, lateMs: -1)))
        XCTAssertEqual(peak.rmssd, try XCTUnwrap(samples.map(\.rmssd).max()))
    }
}
