import CoreLocation
@testable import Emuqu
import XCTest

/// Tests for aerobic decoupling (Pa:Hr) — the first-half vs second-half
/// efficiency drift a runner uses to judge whether an aerobic session held
/// together. It reads out as a percentage in the workout summary and had no
/// test; a sign error or a mis-split would invert the coaching advice.
final class WorkoutDecouplingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_785_600_000)

    /// A straight-line track at a constant speed, one fix per `stepSeconds`.
    /// Longitude degrees are ~78 km at this latitude, so the metres per step
    /// come out of the coordinate delta rather than being asserted directly.
    private func track(seconds: Int, stepSeconds: Int = 10, metresPerSecond: Double = 3.0) -> [CLLocation] {
        let metresPerDegreeLon = 78_000.0
        var out: [CLLocation] = []
        var t = 0
        while t <= seconds {
            let metres = Double(t) * metresPerSecond
            out.append(CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 45.0, longitude: metres / metresPerDegreeLon),
                altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                timestamp: start.addingTimeInterval(Double(t))
            ))
            t += stepSeconds
        }
        return out
    }

    /// RR points at `firstHalfBPM` for the first half of `seconds` and
    /// `secondHalfBPM` after — one point per second, which is dense enough for
    /// every half-window to find samples.
    private func rr(seconds: Int, firstHalfBPM: Double, secondHalfBPM: Double) -> [RRPoint] {
        (0 ... seconds).map { s in
            let bpm = Double(s) < Double(seconds) / 2 ? firstHalfBPM : secondHalfBPM
            return RRPoint(t_ms: Int64(s) * 1000, rr_ms: Int((60_000.0 / bpm).rounded()))
        }
    }

    // MARK: - The withholding gates

    /// Observed in the field: a 2-minute walk around the house produced
    /// "-274.4%". Below five minutes the half-session ratio is noise.
    func testAShortSessionWithholdsTheMetric() {
        let result = WorkoutAnalyzer.computeDecoupling(
            track: track(seconds: 240),
            rrPoints: rr(seconds: 240, firstHalfBPM: 140, secondHalfBPM: 150),
            startDate: start
        )
        XCTAssertNil(result.decouplingPercent)
    }

    /// Five minutes of standing still is long enough in time but covers no
    /// ground, so the pace term is meaningless.
    func testASessionUnderFiveHundredMetresWithholdsTheMetric() {
        let result = WorkoutAnalyzer.computeDecoupling(
            track: track(seconds: 600, metresPerSecond: 0.5),  // 300 m
            rrPoints: rr(seconds: 600, firstHalfBPM: 140, secondHalfBPM: 150),
            startDate: start
        )
        XCTAssertNil(result.decouplingPercent)
    }

    func testTooFewFixesWithholdsTheMetric() {
        let sparse = Array(track(seconds: 1200, stepSeconds: 600))  // 3 fixes
        let result = WorkoutAnalyzer.computeDecoupling(
            track: sparse,
            rrPoints: rr(seconds: 1200, firstHalfBPM: 140, secondHalfBPM: 150),
            startDate: start
        )
        XCTAssertNil(result.decouplingPercent)
    }

    func testNoHeartRateWithholdsTheMetric() {
        let result = WorkoutAnalyzer.computeDecoupling(
            track: track(seconds: 1800), rrPoints: [], startDate: start
        )
        XCTAssertNil(result.decouplingPercent)
        XCTAssertNil(result.overallEfficiencyFactor)
    }

    // MARK: - Sign and magnitude

    /// The convention that matters: POSITIVE means the second half cost more
    /// heart rate for the same pace — the session drifted, which is the
    /// unwanted direction. Getting this backwards would tell a runner their
    /// worst sessions were their best.
    func testRisingHeartRateAtConstantPaceReadsAsPositiveDecoupling() throws {
        let result = WorkoutAnalyzer.computeDecoupling(
            track: track(seconds: 1800),
            rrPoints: rr(seconds: 1800, firstHalfBPM: 140, secondHalfBPM: 154),
            startDate: start
        )
        XCTAssertGreaterThan(try XCTUnwrap(result.decouplingPercent), 0)
    }

    /// Cardiac drift of 10% at constant pace is 10% decoupling: efficiency is
    /// pace/HR, so HR rising by a tenth drops efficiency by a matching share.
    func testTenPercentHeartRateDriftReadsAsAboutTenPercent() throws {
        let result = WorkoutAnalyzer.computeDecoupling(
            track: track(seconds: 1800),
            rrPoints: rr(seconds: 1800, firstHalfBPM: 140, secondHalfBPM: 154),
            startDate: start
        )
        let percent = try XCTUnwrap(result.decouplingPercent)
        XCTAssertEqual(percent, 9.1, accuracy: 1.5)
    }

    /// A negative reading is legitimate and means the second half was MORE
    /// efficient — a warm-up that settled, or a negative split.
    func testFallingHeartRateReadsAsNegativeDecoupling() throws {
        let result = WorkoutAnalyzer.computeDecoupling(
            track: track(seconds: 1800),
            rrPoints: rr(seconds: 1800, firstHalfBPM: 155, secondHalfBPM: 140),
            startDate: start
        )
        XCTAssertLessThan(try XCTUnwrap(result.decouplingPercent), 0)
    }

    /// A steady session at one pace and one heart rate has not decoupled.
    func testAPerfectlySteadySessionReadsAsAboutZero() throws {
        let result = WorkoutAnalyzer.computeDecoupling(
            track: track(seconds: 1800),
            rrPoints: rr(seconds: 1800, firstHalfBPM: 145, secondHalfBPM: 145),
            startDate: start
        )
        XCTAssertEqual(try XCTUnwrap(result.decouplingPercent), 0, accuracy: 0.5)
    }

    // MARK: - Efficiency factor

    /// EF is pace over heart rate across the whole session — metres per second
    /// per beat per minute. 3 m/s at 145 bpm is ~0.0207.
    func testEfficiencyFactorIsPaceOverHeartRateForTheWholeSession() throws {
        let result = WorkoutAnalyzer.computeDecoupling(
            track: track(seconds: 1800, metresPerSecond: 3.0),
            rrPoints: rr(seconds: 1800, firstHalfBPM: 145, secondHalfBPM: 145),
            startDate: start
        )
        XCTAssertEqual(try XCTUnwrap(result.overallEfficiencyFactor), 3.0 / 145.0, accuracy: 0.002)
    }

    /// Faster at the same heart rate is a higher EF — the direction every
    /// aerobic-base block is trying to move.
    func testAFasterSessionAtTheSameHeartRateHasAHigherEfficiencyFactor() throws {
        func ef(metresPerSecond: Double) throws -> Double {
            try XCTUnwrap(WorkoutAnalyzer.computeDecoupling(
                track: track(seconds: 1800, metresPerSecond: metresPerSecond),
                rrPoints: rr(seconds: 1800, firstHalfBPM: 145, secondHalfBPM: 145),
                startDate: start
            ).overallEfficiencyFactor)
        }
        XCTAssertGreaterThan(try ef(metresPerSecond: 4.0), try ef(metresPerSecond: 3.0))
    }

    // MARK: - Heart-rate sample conversion

    /// RR to BPM is 60000/RR. A 1000 ms interval is 60 bpm.
    func testRRIntervalsConvertToBeatsPerMinute() {
        let samples = WorkoutAnalyzer.hrSamplesWithWallClock(
            rrPoints: [RRPoint(t_ms: 0, rr_ms: 1000), RRPoint(t_ms: 1000, rr_ms: 600)],
            startDate: start
        )
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[0].hr, 60, accuracy: 0.001)
        XCTAssertEqual(samples[1].hr, 100, accuracy: 0.001)
    }

    /// A zero or negative interval would divide to infinity; it is dropped,
    /// not converted.
    func testNonPositiveIntervalsAreDropped() {
        let samples = WorkoutAnalyzer.hrSamplesWithWallClock(
            rrPoints: [RRPoint(t_ms: 0, rr_ms: 0), RRPoint(t_ms: 1000, rr_ms: -5),
                       RRPoint(t_ms: 2000, rr_ms: 1000)],
            startDate: start
        )
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].hr, 60, accuracy: 0.001)
    }

    /// Timestamps are the session start plus the point's offset, because the
    /// halves are matched to HR by wall clock.
    func testSampleTimestampsAreAnchoredToTheSessionStart() {
        let samples = WorkoutAnalyzer.hrSamplesWithWallClock(
            rrPoints: [RRPoint(t_ms: 90_000, rr_ms: 1000)], startDate: start
        )
        XCTAssertEqual(samples[0].timestamp, start.addingTimeInterval(90))
    }

    /// A Bluetooth dropout stalls `t_ms` but not the wall clock; beats after
    /// the gap are moved later by the time the gap lost.
    func testDropoutGapIsAddedBackFromWallClock() {
        let samples = WorkoutAnalyzer.hrSamplesWithWallClock(
            rrPoints: [
                RRPoint(t_ms: 0, rr_ms: 1000, wallClockMs: 0),
                RRPoint(t_ms: 1000, rr_ms: 1000, wallClockMs: 1000),
                // 4 minutes of beats lost: wall clock jumped, t_ms did not.
                RRPoint(t_ms: 2000, rr_ms: 1000, wallClockMs: 242_000)
            ],
            startDate: start
        )
        XCTAssertEqual(samples[1].timestamp, start.addingTimeInterval(1))
        XCTAssertEqual(samples[2].timestamp, start.addingTimeInterval(242))
    }
}
