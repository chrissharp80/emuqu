import CoreLocation
@testable import Emuqu
import XCTest

/// A recording break is a boundary, not a step. A GPX `<trkseg>`, a second
/// `<trk>` or `<rte>`, a second Apple Health route, a pause the source
/// stopped recording through, a Bluetooth dropout or two merged recordings
/// all mean nothing was recorded between the two sides, so no distance,
/// time, climb, successive difference or drawn line is taken across one.
/// These tests pin that rule at every site that reads such a series.
@MainActor
final class TrackSegmentsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// 11 fixes 100 m apart heading north from `latitude`, one a second
    /// from `at` seconds after `start`: a 1 km segment.
    private func kilometre(from latitude: Double, at offset: TimeInterval) -> [CLLocation] {
        (0 ... 10).map { index in
            let lat: CLLocationDegrees = latitude + Double(index) * 0.000_9
            let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: 0)
            let altitude: CLLocationDistance = 100 + Double(index)
            let accuracy: CLLocationAccuracy = 5
            return CLLocation(
                coordinate: coordinate, altitude: altitude, horizontalAccuracy: accuracy,
                verticalAccuracy: accuracy, timestamp: start.addingTimeInterval(offset + Double(index) * 30)
            )
        }
    }

    /// Two 1 km segments 10 km apart, the second starting an hour after the
    /// first ends.
    private func twoSegments() -> SegmentedTrack {
        TrackSegments.joined([kilometre(from: 0, at: 0), kilometre(from: 0.1, at: 3_600)])
    }

    private func gpxPoint(_ fix: CLLocation) -> String {
        let iso = ISO8601DateFormatter()
        return "<trkpt lat=\"\(fix.coordinate.latitude)\" lon=\"\(fix.coordinate.longitude)\"><ele>\(fix.altitude)</ele><time>\(iso.string(from: fix.timestamp))</time></trkpt>"
    }

    private func gpx(_ body: String) -> Data {
        Data("<?xml version=\"1.0\"?><gpx version=\"1.1\" creator=\"test\">\(body)</gpx>".utf8)
    }

    /// The same two segments as GPX, written each of the ways a file splits
    /// a track: `<trkseg>`s in one `<trk>`, and two `<trk>`s.
    private func gpxFiles() -> [(name: String, data: Data)] {
        let track = twoSegments()
        let parts = TrackSegments.split(track.fixes, starts: track.starts).map { $0.map(gpxPoint).joined() }
        return [
            ("trkseg", gpx("<trk><trkseg>\(parts[0])</trkseg><trkseg>\(parts[1])</trkseg></trk>")),
            ("trk", gpx("<trk><trkseg>\(parts[0])</trkseg></trk><trk><trkseg>\(parts[1])</trkseg></trk>"))
        ]
    }

    private func importedSession() throws -> HRVSession {
        let parsed = try GPXImporter.parseWorkout(data: gpxFiles()[0].data)
        return try GPXImporter.buildSession(from: parsed)
    }

    private func decodedTrack(of session: HRVSession) throws -> [CLLocation] {
        let polyline = try XCTUnwrap(session.workoutMetadata?.gpsPolyline)
        return GPXExporter.decode(polyline: polyline, startDate: session.startDate, duration: session.duration)
    }

    // MARK: - The shared rule

    func testSegmentsSumWithoutTheGapBetweenThem() {
        let track = twoSegments()
        XCTAssertEqual(track.starts, [11])
        XCTAssertEqual(TrackSegments.lengthMeters(track.fixes, starts: track.starts), 2_000, accuracy: 20)
        XCTAssertGreaterThan(TrackSegments.lengthMeters(track.fixes, starts: []), 11_000, "flattened, the 10 km gap counts")
        let along = TrackSegments.cumulativeMeters(track.fixes, starts: track.starts)
        XCTAssertEqual(along[11], along[10], accuracy: 0.001, "no distance is added across the join")
    }

    func testStartsOutsideTheTrackAreDropped() {
        XCTAssertEqual(TrackSegments.starts([0, 5, 5, 12, -1, 3], count: 10), [3, 5])
        XCTAssertEqual(TrackSegments.ranges(count: 4, starts: [2]), [0 ..< 2, 2 ..< 4])
        XCTAssertEqual(TrackSegments.split([1, 2, 3, 4], starts: [2]), [[1, 2], [3, 4]])
    }

    func testTimeOrderingKeepsEachFixInItsSegment() {
        let track = twoSegments()
        let shuffled = Array(track.fixes[11...]) + Array(track.fixes[..<11])
        let ordered = TrackSegments.timeOrdered(shuffled, starts: [11])
        XCTAssertEqual(ordered.starts, [11])
        XCTAssertEqual(ordered.fixes.first?.timestamp, start)
    }

    func testAPauseTheSourceStoppedThroughStartsASegment() {
        let fixes = kilometre(from: 0, at: 0)
        let pause = fixes[4].timestamp.addingTimeInterval(5) ... fixes[6].timestamp.addingTimeInterval(-5)
        let broken = TrackSegments.breakingAtPauses(SegmentedTrack(fixes: fixes), pauses: [pause])
        XCTAssertEqual(broken.starts, [5, 6], "the steps into and out of the pause carry nothing")
    }

    // MARK: - GPX import

    func testEveryGPXSplitImportsAsSegments() throws {
        for file in gpxFiles() {
            let parsed = try GPXImporter.parseWorkout(data: file.data)
            XCTAssertEqual(parsed.segmentStarts, [11], file.name)
            let session = try GPXImporter.buildSession(from: parsed)
            let metadata = try XCTUnwrap(session.workoutMetadata)
            XCTAssertEqual(metadata.distanceMeters ?? 0, 2_000, accuracy: 20, "\(file.name): two 1 km segments are 2 km")
            XCTAssertEqual(metadata.gpsSegmentStarts, [11], file.name)
        }
    }

    func testARouteFileSplitsAtEachRoute() throws {
        let track = twoSegments()
        let parts = TrackSegments.split(track.fixes, starts: track.starts).map { segment in
            segment.map { "<rtept lat=\"\($0.coordinate.latitude)\" lon=\"0\"></rtept>" }.joined()
        }
        let parsed = try GPXImporter.parse(data: gpx("<rte>\(parts[0])</rte><rte>\(parts[1])</rte>"))
        XCTAssertEqual(parsed.segmentStarts, [11])
        let route = Route.fromGPX(name: "Two pieces", track: parsed.track, segmentStarts: parsed.segmentStarts)
        XCTAssertEqual(route.totalDistanceMeters, 2_000, accuracy: 20)
        XCTAssertEqual(route.segmentStarts, [11])
    }

    func testTheGapIsAPauseOfTheImportedWorkout() throws {
        let session = try importedSession()
        let metadata = try XCTUnwrap(session.workoutMetadata)
        let pause = try XCTUnwrap(metadata.pauseSpans?.first)
        XCTAssertEqual(pause.atElapsed, 300)
        XCTAssertEqual(pause.seconds, 3_600 - 300, accuracy: 1)
        let samples = try XCTUnwrap(metadata.samples)
        XCTAssertEqual(samples.last?.offsetSec, 600, "the samples run on active time: two 5 min segments")
        XCTAssertNotNil(metadata.gpsFixTimes, "the fixes keep the times they were taken")
    }

    // MARK: - Analysis, recovery and stored totals

    func testTheAnalyzerTakesNothingAcrossABreak() {
        let track = twoSegments()
        var pauses = WorkoutAnalyzer.TrackPauses()
        pauses.breaks = Set(track.starts)
        let metadata = WorkoutAnalyzer.analyze(
            sport: .run, rrPoints: [], startDate: start, track: track.fixes, splitDistanceMeters: 1_500, pauses: pauses
        )
        XCTAssertEqual(metadata.distanceMeters ?? 0, 2_000, accuracy: 20)
        XCTAssertEqual(metadata.gpsSegmentStarts, [11])
        let splits = metadata.splits ?? []
        XCTAssertEqual(splits.count, 1, "1.5 km runs across the join and adds nothing for it")
        XCTAssertEqual(splits.first?.durationSeconds ?? 0, 450, accuracy: 1, "the hour between segments is not moving time")
        XCTAssertEqual(splits.first?.distanceMeters ?? 0, 1_500, accuracy: 20)
    }

    func testASavedRouteFromASegmentedWorkoutKeepsItsSegments() throws {
        let saved = try XCTUnwrap(SavedRoute.from(session: try importedSession(), name: "Two pieces"))
        XCTAssertEqual(saved.totalDistanceMeters, 2_000, accuracy: 20)
        XCTAssertEqual(saved.segmentStarts, [11])
        XCTAssertEqual(saved.toRoute().totalDistanceMeters, 2_000, accuracy: 20)
    }

    // MARK: - Exports

    func testExportsWriteEachSegmentAndNoDistanceAcrossTheJoin() throws {
        let session = try importedSession()
        let track = try decodedTrack(of: session)
        let gpx = GPXExporter.export(session: session, track: track)
        XCTAssertEqual(gpx.components(separatedBy: "<trkseg>").count - 1, 2)
        let reimported = try GPXImporter.parseWorkout(data: Data(gpx.utf8))
        XCTAssertEqual(reimported.segmentStarts, [11], "a round trip keeps the segments")
        let tcx = TCXExporter.export(session: session, track: track)
        XCTAssertEqual(tcx.components(separatedBy: "<Track>").count - 1, 2)
        let along = TrackSampleAlignment.cumulativeDistances(track, starts: session.workoutMetadata?.gpsSegmentStarts ?? [])
        XCTAssertEqual(along.last ?? 0, 2_000, accuracy: 20)
    }

    // MARK: - Readers of the stored track

    func testReadersOfTheStoredTrackStopAtTheJoin() throws {
        let session = try importedSession()
        let track = try decodedTrack(of: session)
        let segments = PlaceHistory.tracks(from: session)
        XCTAssertEqual(segments.map(\.points.count), [11, 11])
        let elevation = WorkoutStatsCards.elevationSeries(track, starts: [11])
        XCTAssertEqual(Set(elevation.map(\.segment)), [0, 1])
        XCTAssertEqual(elevation.last?.distance ?? 0, 2, accuracy: 0.02)
        let paceAtJoin = try XCTUnwrap(WorkoutGeometry.localPace(in: twoSegments().fixes, at: 10, starts: [11]))
        XCTAssertEqual(paceAtJoin, 300, accuracy: 10, "the pace stays inside its segment: 30 s per 100 m")
    }

    // MARK: - Beat series across a recording break

    /// 200 beats of 1 s, a two-hour hole, then 200 more: two merged
    /// recordings.
    private func mergedBeats() -> [RRPoint] {
        let first = (0 ..< 200).map { RRPoint(t_ms: Int64($0) * 1_000, rr_ms: 1_000) }
        let second = (0 ..< 200).map { RRPoint(t_ms: 7_400_000 + Int64($0) * 1_000, rr_ms: 600) }
        return first + second
    }

    func testNoBeatPairSpansARecordingBreak() {
        let points = mergedBeats()
        let series = RRSeries(points: points, sessionId: UUID(), startDate: start)
        let pairs = poincareBeatPairs(series: series, flags: nil, window: 0 ..< points.count)
        XCTAssertFalse(pairs.contains { $0 == (1_000, 600) }, "the beats either side of the hole are not a pair")
        XCTAssertEqual(pairs.count, points.count - 2)
        let windowed = BeatConsistency.inWindow(
            rr: points, cleanMask: Array(repeating: true, count: points.count), startMs: 0, endMs: .max
        )
        XCTAssertEqual(windowed.followsPrevious[200], false, "the first beat after the hole follows nothing")
    }

    func testSpectraReadOneUnbrokenStretch() {
        let points = mergedBeats() + (0 ..< 100).map { RRPoint(t_ms: 7_600_000 + Int64($0) * 600, rr_ms: 600) }
        XCTAssertEqual(TimeDomainAnalyzer.longestUnbrokenRange(in: points, range: 0 ..< points.count), 200 ..< 500)
        XCTAssertEqual(TimeDomainAnalyzer.longestUnbrokenRange(in: points, range: 0 ..< 150), 0 ..< 150)
    }

    func testChartsStartANewRunAfterAHole() {
        XCTAssertEqual(SeriesRuns.runs(of: [0, 1, 2, 10, 11], maxGap: 5), [0, 0, 0, 1, 1])
        let series = RRSeries(points: mergedBeats(), sessionId: UUID(), startDate: start)
        let plotted = HRVDetailV2View.sampledRRPoints(series)
        XCTAssertEqual(Set(plotted.map(\.run)), [0, 1])
        XCTAssertEqual(plotted.first { $0.id >= 200 }?.run, 1)
    }
}
