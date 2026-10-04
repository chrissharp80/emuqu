import CoreLocation
@testable import Emuqu
import XCTest

/// Tests for per-kilometre (or per-mile) split computation — the table a
/// runner reads after every session. Splits carry distance, duration, pace,
/// average HR and elevation gain, and none of it was pinned by a test.
final class WorkoutSplitTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_785_600_000)

    /// A straight eastward track at a constant speed, one fix per second.
    /// Latitude 0 so a degree of longitude is very close to 111,320 m and the
    /// synthetic distances land within a fraction of a percent of nominal.
    private func track(
        seconds: Int,
        metresPerSecond: Double = 3.0,
        altitudeAt: ((Int) -> Double)? = nil
    ) -> [CLLocation] {
        let metresPerDegreeLon = 111_320.0
        return (0 ... seconds).map { t in
            CLLocation(
                coordinate: CLLocationCoordinate2D(
                    latitude: 0,
                    longitude: Double(t) * metresPerSecond / metresPerDegreeLon
                ),
                altitude: altitudeAt?(t) ?? 0,
                horizontalAccuracy: 5, verticalAccuracy: 5,
                timestamp: start.addingTimeInterval(Double(t))
            )
        }
    }

    private func rr(seconds: Int, bpm: Double) -> [RRPoint] {
        (0 ... seconds).map { RRPoint(t_ms: Int64($0) * 1000, rr_ms: Int((60_000.0 / bpm).rounded())) }
    }

    // MARK: - Emission

    /// A track shorter than one split emits nothing — a partial kilometre is
    /// not a kilometre split, and showing it as one would misreport pace.
    func testATrackShorterThanOneSplitEmitsNothing() {
        XCTAssertTrue(WorkoutAnalyzer.computeSplits(
            track: track(seconds: 300), rrPoints: [], startDate: start
        ).isEmpty)
    }

    /// 3 m/s for 1200 s is 3600 m — three whole kilometres and a 600 m tail
    /// that does not become a fourth split.
    func testOnlyCompletedSplitsAreEmitted() {
        let splits = WorkoutAnalyzer.computeSplits(
            track: track(seconds: 1200), rrPoints: [], startDate: start
        )
        XCTAssertEqual(splits.count, 3)
    }

    // MARK: - Pauses

    /// 3 m/s for 1300 s with 200 s of it walked while paused: the paused
    /// 600 m is not workout distance, so 3300 m make three splits at the pace
    /// actually run, not four, none stretched by the pause.
    func testAPausedStretchCountsNeitherDistanceNorTime() {
        let pauses = WorkoutAnalyzer.TrackPauses(paused: Set(501 ... 700), gaps: [701])
        let splits = WorkoutAnalyzer.computeSplits(
            track: track(seconds: 1300), rrPoints: [], startDate: start, pauses: pauses
        )
        XCTAssertEqual(splits.count, 3)
        for split in splits {
            XCTAssertEqual(split.durationSeconds, 1000.0 / 3.0, accuracy: 3, "split \(split.index)")
        }
        XCTAssertEqual(
            WorkoutAnalyzer.computeDistance(track: track(seconds: 1300), pauses: pauses), 3300, accuracy: 10
        )
    }

    func testSplitsAreNumberedFromOne() {
        let splits = WorkoutAnalyzer.computeSplits(
            track: track(seconds: 1200), rrPoints: [], startDate: start
        )
        XCTAssertEqual(splits.map(\.index), [1, 2, 3])
    }

    func testAnEmptyOrSingleFixTrackEmitsNothing() {
        XCTAssertTrue(WorkoutAnalyzer.computeSplits(track: [], rrPoints: [], startDate: start).isEmpty)
        XCTAssertTrue(WorkoutAnalyzer.computeSplits(
            track: Array(track(seconds: 0)), rrPoints: [], startDate: start
        ).isEmpty)
    }

    // MARK: - Distance and duration

    /// Each split covers about the requested distance. It overshoots slightly
    /// because a split closes on the first fix that crosses the threshold.
    func testEachSplitCoversAboutTheRequestedDistance() {
        for split in WorkoutAnalyzer.computeSplits(
            track: track(seconds: 1200), rrPoints: [], startDate: start
        ) {
            XCTAssertEqual(split.distanceMeters, 1_000, accuracy: 10)
        }
    }

    /// Splits partition the session: the second starts where the first ended,
    /// so their durations sum to the covered time rather than overlapping.
    func testSplitDurationsPartitionTheSession() {
        let splits = WorkoutAnalyzer.computeSplits(
            track: track(seconds: 1200), rrPoints: [], startDate: start
        )
        let total = splits.reduce(0) { $0 + $1.durationSeconds }
        // Three kilometres at 3 m/s is ~1000 s of the 1200 s recorded.
        XCTAssertEqual(total, 1_000, accuracy: 10)
    }

    /// The split distance is a parameter because the app shows miles for
    /// imperial users; asking for miles must give miles.
    func testAMileSplitProducesMileLongSplits() {
        let splits = WorkoutAnalyzer.computeSplits(
            track: track(seconds: 1200), rrPoints: [], startDate: start,
            splitDistanceMeters: 1_609.344
        )
        XCTAssertEqual(splits.count, 2)  // 3600 m is two miles and a tail
        XCTAssertEqual(splits[0].distanceMeters, 1_609.344, accuracy: 10)
    }

    // MARK: - Pace

    /// Pace is seconds per kilometre. 3 m/s is 1000/3 ≈ 333 s/km — 5:33/km.
    func testPaceIsSecondsPerKilometre() throws {
        let splits = WorkoutAnalyzer.computeSplits(
            track: track(seconds: 1200), rrPoints: [], startDate: start
        )
        let pace = try XCTUnwrap(splits.first?.averagePaceSecPerKm)
        XCTAssertEqual(pace, 1_000.0 / 3.0, accuracy: 5)
    }

    /// Faster running is a SMALLER pace number. An inverted comparison here
    /// would label every negative split as a slowdown.
    func testFasterRunningYieldsALowerPaceNumber() throws {
        func pace(metresPerSecond: Double) throws -> Double {
            try XCTUnwrap(WorkoutAnalyzer.computeSplits(
                track: track(seconds: 1200, metresPerSecond: metresPerSecond),
                rrPoints: [], startDate: start
            ).first?.averagePaceSecPerKm)
        }
        XCTAssertLessThan(try pace(metresPerSecond: 4.0), try pace(metresPerSecond: 3.0))
    }

    // MARK: - Heart rate

    func testSplitAverageHeartRateComesFromTheBeatsInsideItsWindow() throws {
        let splits = WorkoutAnalyzer.computeSplits(
            track: track(seconds: 1200), rrPoints: rr(seconds: 1200, bpm: 150), startDate: start
        )
        XCTAssertEqual(try XCTUnwrap(splits.first?.averageHR), 150, accuracy: 1)
    }

    /// No strap data means no HR column, not a zero — a zero would render as
    /// a real reading in the splits table.
    func testSplitsWithoutHeartRateDataReportNoAverage() {
        let splits = WorkoutAnalyzer.computeSplits(
            track: track(seconds: 1200), rrPoints: [], startDate: start
        )
        XCTAssertTrue(splits.allSatisfy { $0.averageHR == nil })
    }

    /// Heart rate that climbs across the session must show as climbing across
    /// the splits, or the drift a runner is looking for is invisible.
    func testRisingHeartRateShowsAsRisingSplitAverages() throws {
        let rising = (0 ... 1200).map { s in
            RRPoint(t_ms: Int64(s) * 1000, rr_ms: Int((60_000.0 / (130.0 + Double(s) / 40.0)).rounded()))
        }
        let splits = WorkoutAnalyzer.computeSplits(
            track: track(seconds: 1200), rrPoints: rising, startDate: start
        )
        let averages = try splits.map { try XCTUnwrap($0.averageHR) }
        XCTAssertEqual(averages, averages.sorted())
        XCTAssertGreaterThan(try XCTUnwrap(averages.last) - XCTUnwrap(averages.first), 5)
    }

    // MARK: - Elevation

    /// Flat ground is zero gain, not nil and not noise.
    func testAFlatSplitReportsNoElevationGain() throws {
        let splits = WorkoutAnalyzer.computeSplits(
            track: track(seconds: 1200), rrPoints: [], startDate: start
        )
        XCTAssertEqual(try XCTUnwrap(splits.first?.elevationGainMeters), 0, accuracy: 1)
    }

    /// Only the climbing is counted. A split that rises and falls back to its
    /// starting height still did the climbing, so gain is the sum of the ups,
    /// never the net.
    func testElevationGainCountsTheClimbsNotTheNetChange() throws {
        // Up 1 m/s for the first half of each 600 s, back down for the rest.
        let rollingTrack = track(seconds: 1200, altitudeAt: { t in
            let phase = t % 600
            return phase < 300 ? Double(phase) : Double(600 - phase)
        })
        let splits = WorkoutAnalyzer.computeSplits(
            track: rollingTrack, rrPoints: [], startDate: start
        )
        let gain = try XCTUnwrap(splits.first?.elevationGainMeters)
        XCTAssertGreaterThan(gain, 100, "the climbs must be counted even though the split ends level")
    }

    // MARK: - Alpha1 enrichment

    /// Splits leave `computeSplits` without α1; the post-pass fills it. A
    /// session with no α1 samples must come back unchanged rather than with
    /// fabricated values.
    func testAlphaEnrichmentWithNoSamplesLeavesSplitsUnchanged() {
        let splits = WorkoutAnalyzer.computeSplits(
            track: track(seconds: 1200), rrPoints: [], startDate: start
        )
        let enriched = WorkoutAnalyzer.enrichSplitsWithAlpha1(
            splits: splits, samples: [], startDate: start, track: track(seconds: 1200)
        )
        XCTAssertEqual(enriched.count, splits.count)
        XCTAssertTrue(enriched.allSatisfy { $0.averageAlpha1 == nil })
    }

    func testAlphaEnrichmentOfNoSplitsIsEmpty() {
        XCTAssertTrue(WorkoutAnalyzer.enrichSplitsWithAlpha1(
            splits: [], samples: [], startDate: start, track: []
        ).isEmpty)
    }
}
