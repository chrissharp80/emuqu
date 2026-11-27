import CoreLocation
@testable import Emuqu
import XCTest

/// Workout and session length rules read the quantity they are written in:
/// α1 fits a window that spans its two minutes offline as live, decoupling
/// is gated on moving time, a trailing rest is timed, a night segment is
/// measured on the real clock, HRR readings carry the time they were taken,
/// and every VLF gate reads one span for the same samples.
@MainActor
final class WorkoutSpanSufficiencyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_785_600_000)

    // MARK: - α1 full window

    func testAnAlpha1WindowNeedsSixtyFourBeatsAndItsTwoMinutes() {
        let slack = LiveDFAAnalyzer.windowSpanSlackSec
        let cases: [(beats: Int, span: Double, full: Bool)] = [
            (64, 120 - slack, true), (63, 120, false), (64, 120 - slack - 0.1, false), (400, 24, false)
        ]
        for c in cases {
            XCTAssertEqual(LiveDFAAnalyzer.isFullWindow(beats: c.beats, spanSec: c.span, minBeats: 64, windowSec: 120), c.full, "\(c)")
        }
    }

    /// Streamed beats at 160 bpm with a 90-second dropout after the first
    /// minute: a window whose first part fell in the dropout holds well over
    /// 64 beats but not two minutes of them, so it is not fitted.
    func testTheReanalyzerSkipsAWindowThatADropoutLeftShort() {
        var t: Int64 = 0
        let points: [RRPoint] = (0 ..< 1400).map { i in
            let rr = 375 + (i % 3 == 0 ? 12 : -6)
            let wall = t + (t >= 60_000 ? 90_000 : 0)
            defer { t += Int64(rr) }
            return RRPoint(t_ms: t, rr_ms: rr, wallClockMs: wall)
        }
        var session = HRVSession(
            id: UUID(), startDate: start, endDate: start.addingTimeInterval(600), state: .complete,
            rrSeries: RRSeries(points: points, sessionId: UUID(), startDate: start), analysisResult: nil, artifactFlags: nil
        )
        session.sessionType = .workout
        let readings = WorkoutAlpha1Reanalyzer.reanalyze(session: session)
        XCTAssertFalse(readings.isEmpty)
        XCTAssertTrue(readings.allSatisfy { $0.offsetSec >= 268 }, "\(readings.map(\.offsetSec))")
    }

    // MARK: - Decoupling on moving time

    private func track(seconds: Int, stepSeconds: Int = 10, metresPerSecond: Double = 3.0) -> [CLLocation] {
        stride(from: 0, through: seconds, by: stepSeconds).map { t in
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 45.0, longitude: Double(t) * metresPerSecond / 78_000),
                altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: start.addingTimeInterval(Double(t))
            )
        }
    }

    private func rr(seconds: Int) -> [RRPoint] {
        (0 ... seconds).map { s in RRPoint(t_ms: Int64(s) * 1000, rr_ms: s < seconds / 2 ? 430 : 400) }
    }

    func testDecouplingNeedsFiveMinutesOfMovingTimeNotOfElapsedTime() {
        let moving = WorkoutAnalyzer.computeDecoupling(track: track(seconds: 600), rrPoints: rr(seconds: 600), startDate: start)
        XCTAssertNotNil(moving.decouplingPercent)
        var pauses = WorkoutAnalyzer.TrackPauses()
        pauses.paused = Set(7 ... 42)
        let paused = WorkoutAnalyzer.computeDecoupling(
            track: track(seconds: 600), rrPoints: rr(seconds: 600), startDate: start, pauses: pauses
        )
        XCTAssertNil(paused.decouplingPercent, "four minutes of movement in a ten-minute session")
    }

    // MARK: - Trailing rest

    private func workout(activeBeats: Int, restBeats: Int) -> [RRPoint] {
        var t: Int64 = 0
        return (0 ..< activeBeats + restBeats).map { i in
            let rr = i < activeBeats ? 400 : 600
            defer { t += Int64(rr) }
            return RRPoint(t_ms: t, rr_ms: rr)
        }
    }

    func testATrailingRestIsTrimmedOnlyWhenItLastsAMinute() {
        let short = workout(activeBeats: 600, restBeats: 80)  // 48 s of rest
        XCTAssertEqual(WorkoutRecoveryService.trimTrailingRest(short).count, short.count)
        let long = workout(activeBeats: 600, restBeats: 120)  // 72 s of rest
        XCTAssertEqual(WorkoutRecoveryService.trimTrailingRest(long).count, 640)
    }

    // MARK: - Night segment length

    func testANightSegmentIsMeasuredOnTheRealClock() {
        var t: Int64 = 0
        let dropped: [RRPoint] = (0 ..< 1200).map { i in
            defer { t += 1000 }
            return RRPoint(t_ms: t, rr_ms: 1000, wallClockMs: t + (i >= 600 ? 15 * 60_000 : 0))
        }
        XCTAssertTrue(MorningProcessingService.isMergeableLength(dropped), "35 min of real time, 20 min of beats")
        let short = (0 ..< 1200).map { RRPoint(t_ms: Int64($0) * 1000, rr_ms: 1000) }
        XCTAssertFalse(MorningProcessingService.isMergeableLength(short))
    }

    // MARK: - HRR offsets

    func testAnHRRReadingCarriesTheTimeItWasTaken() {
        XCTAssertEqual(HRRCaptureService.measuredOffsetSec(since: start, now: start.addingTimeInterval(72.4)), 72)
        // Read back by the one tolerance the capture stores a reading by.
        let pastTolerance = 60 + HRRSample.targetToleranceSec + 1
        let late = HRRSample(offsetSec: pastTolerance, hr: 120, drop: 30, peakHR: 150, provenance: .strap)
        XCTAssertNil([late].bestAtOneMinute, "a reading \(pastTolerance) s after Stop is not a 1-minute recovery")
        let withinTolerance = HRRSample(offsetSec: 72, hr: 120, drop: 30, peakHR: 150, provenance: .strap)
        XCTAssertEqual([withinTolerance].bestAtOneMinute?.offsetSec, 72, "the reading keeps the time it was taken")
    }

    // MARK: - Spectral span

    func testEveryVLFGateReadsTheSpanTheSamplesWereBuiltFrom() {
        let fs = 4.0
        let tenMinutes = Int(600 * fs) + 1
        XCTAssertEqual(FrequencyDomainAnalyzer.spanMinutes(sampleCount: tenMinutes, fs: fs), 10, accuracy: 1e-12)
        XCTAssertEqual(FrequencyDomainAnalyzer.spanMinutes(sampleCount: 1, fs: fs), 0)
    }
}
