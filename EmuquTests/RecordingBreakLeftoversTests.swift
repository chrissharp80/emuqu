import CoreLocation
@testable import Emuqu
import SwiftUI
import XCTest

/// A recording break (a Bluetooth dropout, two merged recordings, a sample
/// the Watch never sent, a join between recorded GPS segments) stays a
/// boundary through every chart, export, import, producer and route guide:
/// no line, pair, climb or step is taken across it, and the times that show
/// it survive the round trip out of the app and back.
@MainActor
final class RecordingBreakLeftoversTests: XCTestCase {
    /// 120 beats of 800 ms. Beat 60 follows a streamed dropout: `t_ms` runs
    /// on (the beat timeline never shows it), the wall clock jumps 30 s.
    private func streamedNight() -> RRSeries {
        let points = (0 ..< 120).map { i -> RRPoint in
            let wall = Int64(i * 800) + (i >= 60 ? 30_000 : 0)
            return RRPoint(t_ms: Int64(i * 800), rr_ms: 800, wallClockMs: wall)
        }
        return RRSeries(points: points, sessionId: UUID(), startDate: Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// 120 beats of 800 ms recorded by the sensor itself, two recordings
    /// merged with a 10-minute gap before beat 60.
    private func mergedNight() -> RRSeries {
        let points = (0 ..< 120).map { i in RRPoint(t_ms: Int64(i * 800) + (i >= 60 ? 600_000 : 0), rr_ms: 800) }
        return RRSeries(points: points, sessionId: UUID(), startDate: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func moves(in path: Path) -> Int {
        var count = 0
        path.forEach { if case .move = $0 { count += 1 } }
        return count
    }

    // MARK: - Beat-index charts

    /// The tachogram, the heart-rate trace and the PDF tachogram split at a
    /// break inside the window, for a streamed dropout and a merged gap.
    func testBeatIndexTracesSplitAtABreakInsideTheWindow() throws {
        for series in [streamedNight(), mergedNight()] {
            let tachogram = try XCTUnwrap(tachogramTrace(series: series, window: 40 ..< 80))
            XCTAssertEqual(tachogram.runs, Array(repeating: 0, count: 20) + Array(repeating: 1, count: 20))
            let heartRate = try XCTUnwrap(heartRateTrace(series: series, flags: nil, window: 40 ..< 80))
            XCTAssertEqual(Set(heartRate.runs), [0, 1])
            XCTAssertEqual(heartRate.runs.firstIndex(of: 1), 20)
            let report = reportTachogramBeats(series: series, flags: [], window: 40 ..< 80)
            XCTAssertEqual(report.map(\.run).firstIndex(of: 1), 20)
        }
    }

    /// A dropped artifact beat alone is not a break; a break between two kept
    /// beats is one even when an artifact sits right beside it.
    func testTheHeartRateTraceSplitsAtABreakNotAtADroppedArtifact() throws {
        let series = streamedNight()
        var flags = Array(repeating: ArtifactFlags(isArtifact: false, type: nil, confidence: 0), count: 120)
        flags[50] = ArtifactFlags(isArtifact: true, type: .technical, confidence: 0.9)
        flags[60] = ArtifactFlags(isArtifact: true, type: .technical, confidence: 0.9)
        let trace = try XCTUnwrap(heartRateTrace(series: series, flags: flags, window: 40 ..< 80))
        XCTAssertEqual(trace.points.count, 38)
        XCTAssertEqual(trace.runs.filter { $0 == 0 }.count, 19, "beats 40-59 less the artifact at 50")
        XCTAssertEqual(trace.runs.filter { $0 == 1 }.count, 19, "beats 61-79, after the break")
    }

    /// A trace of two runs is two lines and two fills, never one across.
    func testTracePathsLiftThePenBetweenRuns() {
        let points = (0 ..< 6).map { CGPoint(x: CGFloat($0), y: 1) }
        let paths = tracePaths(points: points, runs: [0, 0, 0, 1, 1, 1], height: 10)
        XCTAssertEqual(moves(in: paths.line), 2)
        XCTAssertEqual(moves(in: paths.fill), 2)
        XCTAssertEqual(SeriesRuns.split(Array(0 ..< 5), runs: [0, 0, 1, 1, 2]), [[0, 1], [2, 3], [4]])
    }

    /// The overnight chart's samples are sparse (one per ~10 s window); a
    /// break between two of them starts a new run, wherever it falls.
    func testSparseSamplesSplitWhereABreakFallsBetweenThem() {
        let series = streamedNight()
        let runs = OvernightHRChartCanvas.polarHRRuns(plotHR: [0, 20, 40, 70, 90, 500].map { ($0, 60) }, points: series.points)
        XCTAssertEqual(runs.map { $0.map(\.ms) }, [[0, 16_000, 32_000], [56_000, 72_000]])
        XCTAssertEqual(TimeDomainAnalyzer.recordingRuns(of: [0, 20, 40, 70, 90], in: series.points), [0, 0, 0, 1, 1])
        XCTAssertEqual(TimeDomainAnalyzer.recordingRuns(of: [0, 20, 40, 59], in: series.points), [0, 0, 0, 0])
        XCTAssertEqual(TimeDomainAnalyzer.recordingRuns(of: [60, 70], in: series.points), [0, 0], "a break before the first sample is not inside")
    }

    // MARK: - RR export and import

    /// A reading's RR export read back by the importer keeps both clocks, so
    /// the dropout and the merged gap are still breaks.
    func testAOneRecordingExportImportsWithItsBreaks() throws {
        let importer = RRDataImporter()
        for series in [streamedNight(), mergedNight()] {
            let csv = "# Emuqu RR Export\n" + RRDataImporter.recordingCSVColumnNote + "#\n" + RRDataImporter.recordingCSV(points: series.points)
            let result = try importer.importContent(csv, fileName: "Emuqu_RR.csv")
            let session = importer.createSession(from: result, startingAt: series.startDate)
            let points = try XCTUnwrap(session.rrSeries?.points)
            XCTAssertEqual(points, series.points)
            XCTAssertTrue(TimeDomainAnalyzer.isRecordingBreak(between: points[59], and: points[60]))
            XCTAssertEqual(session.endDate, series.startDate.addingTimeInterval(Double(series.points[119].endMs) / 1000))
        }
    }

    /// A CSV that states no timestamps, or ones that cannot be one
    /// recording's, still has its beats laid end to end.
    func testACSVWithoutUsableTimestampsIsLaidEndToEnd() throws {
        let importer = RRDataImporter()
        let falling = "timestamp_ms,rr_ms\n" + (0 ..< 70).map { "\(10_000 - $0),800" }.joined(separator: "\n")
        let plain = "rr_ms\n" + Array(repeating: "800", count: 70).joined(separator: "\n")
        for csv in [falling, plain] {
            let result = try importer.importContent(csv, fileName: "rr.csv")
            XCTAssertNil(result.timeline)
            let points = try XCTUnwrap(importer.createSession(from: result, startingAt: Date()).rrSeries?.points)
            XCTAssertEqual(points.map(\.t_ms).prefix(3), [0, 800, 1_600])
        }
    }

    /// The archive's multi-session export carries each streamed beat's wall
    /// clock, and the import puts it back.
    func testAMultiSessionExportImportsWithItsWallClock() throws {
        let series = streamedNight()
        var session = HRVSession(startDate: series.startDate, sessionType: .overnight)
        session.rrSeries = series
        let csv = RRDataImporter.emuquRRExportHeader + "\n" + ExportDataView.rrCSVRows(for: session, series: series, timeZone: .gmt)
        let importer = RRDataImporter()
        let parsed = try importer.parseFlowHRVMultiSession(csv, fileName: "export.csv")
        let data = try XCTUnwrap(parsed.sessions.first)
        let points = try XCTUnwrap(importer.createSessionFromFlowHRVData(data, originalFileName: "export.csv").rrSeries?.points)
        XCTAssertEqual(points, series.points)
        XCTAssertTrue(TimeDomainAnalyzer.isRecordingBreak(between: points[59], and: points[60]))
    }

    /// A beat the sensor recorded itself writes an empty wall-clock cell,
    /// and imports with none.
    func testABeatWithoutAWallClockRoundTripsWithout() throws {
        let series = mergedNight()
        var session = HRVSession(startDate: series.startDate, sessionType: .nap)
        session.rrSeries = series
        let rows = ExportDataView.rrCSVRows(for: session, series: series, timeZone: .gmt)
        XCTAssertTrue(rows.hasPrefix("2023-11-14T22:13:20Z,0,800,nap,\n"))
        let parsed = try RRDataImporter().parseFlowHRVMultiSession(RRDataImporter.emuquRRExportHeader + "\n" + rows, fileName: "e.csv")
        XCTAssertEqual(parsed.sessions.first?.wallClocks.compactMap { $0 }, [])
    }

    // MARK: - Watch-routed beats

    /// Two samples the Watch received 10 s apart keep the 10 s between them,
    /// each beat ending where the Watch's clock puts it, so beats queued from
    /// both are not laid end to end.
    func testWatchStrapBeatsKeepTheTimeBetweenSamples() {
        let first = WatchStrapBeat.beats(rrMillis: [800, 900], sentAt: 1_000)
        let second = WatchStrapBeat.beats(rrMillis: [850, 10_000, 750], sentAt: 1_010)
        XCTAssertEqual(first.map(\.endEpochMs), [999_100, 1_000_000])
        XCTAssertEqual(second.map(\.rrMillis), [850, 750], "the implausible interval is dropped")
        XCTAssertEqual(second.map(\.endEpochMs), [1_009_250, 1_010_000])
        let gapMs = (second[0].endEpochMs - second[0].rrMillis) - first[1].endEpochMs
        XCTAssertEqual(gapMs, 8_400)
        let placed = WatchStrapBeat.placed(first + second, after: 0)
        XCTAssertEqual(placed.map(\.startEpochMs), [998_300, 999_100, 1_008_400, 1_009_250])
        XCTAssertEqual(placed.map(\.rrMs), [800, 900, 850, 750])
    }

    /// Two samples whose times overlap by a few ms never put a beat before
    /// the end of the one ahead of it.
    func testAWatchBeatNeverStartsBeforeTheOneAheadOfItEnds() {
        let beats = [WatchStrapBeat(rrMillis: 800, endEpochMs: 10_000), WatchStrapBeat(rrMillis: 800, endEpochMs: 10_780)]
        XCTAssertEqual(WatchStrapBeat.placed(beats, after: 0).map(\.startEpochMs), [9_200, 10_000])
        XCTAssertEqual(WatchStrapBeat.placed(beats, after: 9_500).map(\.startEpochMs), [9_500, 10_300])
    }

    // MARK: - Segmented routes

    /// `count` fixes 10 m apart heading north from `latitude` along
    /// `longitude`, at `altitude`.
    private func flat(from latitude: Double, altitude: Double, longitude: Double = 0, count: Int = 11) -> [CLLocation] {
        (0 ..< count).map { index in
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: latitude + Double(index) * 0.000_09, longitude: longitude),
                altitude: altitude, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date(timeIntervalSince1970: Double(index))
            )
        }
    }

    /// Two flat stretches, the second recorded 80 m higher: the altitude
    /// step at the join was never climbed, so no climb is found across it.
    func testNoClimbIsFoundAcrossAJoin() {
        let low = flat(from: 0, altitude: 100)
        let high = flat(from: 0.001, altitude: 180)
        let track = low + high
        XCTAssertFalse(Route.fromGPX(name: "joined", track: track).climbs.isEmpty, "read as one line it climbs")
        let segmented = Route.fromGPX(name: "segmented", track: track, segmentStarts: [low.count])
        XCTAssertTrue(segmented.climbs.isEmpty)
        XCTAssertEqual(segmented.totalAscentMeters, 0, accuracy: 0.001)
    }

    /// Guidance follows each recorded segment on its own, in either
    /// direction, and nothing joins the two.
    func testSavedRouteGuidanceIsCutAtEachJoin() {
        let coords = (flat(from: 0, altitude: 0) + flat(from: 0.01, altitude: 0, count: 6)).map(\.coordinate)
        let forward = SavedRouteStepBuilder.recordedSegments(of: coords, forwardStarts: [11], direction: .forward)
        XCTAssertEqual(forward.map(\.count), [11, 6])
        XCTAssertEqual(forward[1].first?.latitude, coords[11].latitude)
        let reversed = Array(coords.reversed())
        let backward = SavedRouteStepBuilder.recordedSegments(of: reversed, forwardStarts: [11], direction: .reverse)
        XCTAssertEqual(backward.map(\.count), [6, 11])
        XCTAssertEqual(backward[1].first?.latitude, coords[10].latitude)
    }

    /// The live turn search finds the first join inside a window.
    func testARouteNamesTheJoinInsideARange() {
        let route = Route.fromGPX(name: "r", track: flat(from: 0, altitude: 0) + flat(from: 0.01, altitude: 0), segmentStarts: [11])
        XCTAssertEqual(route.segmentStart(in: 5 ... 15), 11)
        XCTAssertNil(route.segmentStart(in: 12 ... 20))
    }

    /// Two straight stretches north, the second recorded 100 m east: read as
    /// one line the jog between them is a turn; as two segments there is
    /// none, since that jog was never walked.
    func testTheLiveTurnSearchTakesNoBearingAcrossAJoin() {
        let track = flat(from: 0, altitude: 0) + flat(from: 0.000_99, altitude: 0, longitude: 0.000_9)
        let joined = Route.fromGPX(name: "joined", track: track)
        let segmented = Route.fromGPX(name: "segmented", track: track, segmentStarts: [11])
        XCTAssertFalse(WorkoutAIContextBuilder.computeUpcomingTurns(route: joined, fromDistanceAlongMeters: 0).isEmpty)
        XCTAssertTrue(WorkoutAIContextBuilder.computeUpcomingTurns(route: segmented, fromDistanceAlongMeters: 0).isEmpty)
    }
}
