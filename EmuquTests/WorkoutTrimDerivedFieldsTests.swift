import CoreLocation
@testable import Emuqu
import XCTest

/// A trim rebuilds a workout from what it keeps: distance, route, splits,
/// elevation and samples come from the kept part of the stored track and
/// samples, never from the untrimmed workout. A saved workout's backups are
/// gone, so the rebuild works from the archived copy's own streams
/// (`WorkoutRecoveryService.sourceStreams`). Indoor distance comes from the
/// kept samples, which carry the distance a foot pod, pedometer or erg
/// counted.
@MainActor
final class WorkoutTrimDerivedFieldsTests: XCTestCase {
    private lazy var directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WorkoutTrimDerivedFieldsTests-\(UUID().uuidString)", isDirectory: true)
    private lazy var archive = SessionArchive(directory: directory)
    private lazy var collector = RRCollector.withoutCloudAcceptance(polarManager: PolarManager(), archive: archive)
    private let start = Date().addingTimeInterval(-3 * 3600)

    override func setUp() async throws {
        try await super.setUp()
        isolateFromHostRecordingState()
    }

    override func tearDown() async throws {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            // swallow-ok: a test that archived nothing leaves no directory to remove.
        }
        try await super.tearDown()
    }

    /// A fix every 10 s heading north: 3 m/s for the first 30 minutes (a
    /// run), 4.2 m/s for the next 30 (the drive home, End forgotten).
    private func runThenDrive() -> [CLLocation] {
        var latitude = 51.0
        return (0 ... 360).map { index in
            if index > 0 { latitude += (index <= 180 ? 30.0 : 42.0) / 111_320.0 }
            return CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: 0), altitude: 100,
                horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: start.addingTimeInterval(Double(index) * 10)
            )
        }
    }

    private func savedWorkout(sport: Sport, seconds: TimeInterval, track: [CLLocation], metersPerSecond: (Int) -> Double) -> HRVSession {
        var session = HRVSession(
            id: UUID(), startDate: start, endDate: start.addingTimeInterval(seconds), state: .complete,
            sessionType: .workout, rrSeries: nil, analysisResult: nil, artifactFlags: nil
        )
        var metadata = WorkoutMetadata(sport: sport)
        metadata.gpsPolyline = WorkoutAnalyzer.encodePolyline(track: track)
        metadata.gpsFixTimes = WorkoutAnalyzer.encodeFixTimes(track: track)
        var meters = 0.0
        metadata.samples = (1 ... Int(seconds)).map { second in
            meters += metersPerSecond(second)
            return WorkoutSample(offsetSec: second, distanceMeters: meters)
        }
        metadata.distanceMeters = meters
        metadata.elevationGainMeters = 400
        metadata.elevationLossMeters = 400
        metadata.splits = (1 ... 13).map { Split(index: $0, distanceMeters: 1_000, durationSeconds: 240, averageHR: nil, averagePaceSecPerKm: 240, elevationGainMeters: 30) }
        session.workoutMetadata = metadata
        return session
    }

    /// The forgotten End: a run then a drive, 13 km, trimmed to the run's 30
    /// minutes. It keeps the run's distance, route, splits and climb.
    func testTrimmingASavedRunRecomputesItsRouteFieldsFromTheKeptTrack() async throws {
        let workout = savedWorkout(sport: .run, seconds: 3_600, track: runThenDrive()) { $0 <= 1_800 ? 3 : 4.2 }
        try archive.archive(workout, skipSameNightMerge: true)

        let closed = await collector.recovery.retrimRecoveredWorkout(sessionId: workout.id, endSec: 1_800)

        XCTAssertTrue(closed)
        let saved = try XCTUnwrap(archive.retrieve(workout.id))
        let metadata = try XCTUnwrap(saved.workoutMetadata)
        XCTAssertEqual(try XCTUnwrap(saved.endDate).timeIntervalSince(start), 1_800, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(metadata.distanceMeters), 5_400, accuracy: 150, "the run's distance, not the drive's")
        XCTAssertLessThanOrEqual(metadata.splits?.count ?? 0, 6)
        XCTAssertEqual(metadata.elevationGainMeters ?? -1, 0, accuracy: 0.1, "a flat run, not the untrimmed climb")
        let route = GPXExporter.timedAsRecorded(
            GPXExporter.decode(polyline: try XCTUnwrap(metadata.gpsPolyline), startDate: start), metadata: metadata
        )
        XCTAssertTrue((180 ... 181).contains(route.count), "the run's fixes only, not the drive's 180 after them")
        XCTAssertLessThanOrEqual(try XCTUnwrap(route.last).timestamp.timeIntervalSince(start), 1_800.5)
        XCTAssertLessThanOrEqual(metadata.samples?.last?.offsetSec ?? .max, 1_800)
    }

    /// A treadmill workout with no strap trims like any other, and its
    /// distance is the one the kept samples counted.
    func testTrimmingAnIndoorWorkoutWithNoHeartRateKeepsItsCountedDistance() async throws {
        let workout = savedWorkout(sport: .treadmill, seconds: 2_400, track: []) { _ in 2.5 }
        try archive.archive(workout, skipSameNightMerge: true)

        let closed = await collector.recovery.retrimRecoveredWorkout(sessionId: workout.id, endSec: 1_200)

        XCTAssertTrue(closed)
        let saved = try XCTUnwrap(archive.retrieve(workout.id))
        XCTAssertEqual(try XCTUnwrap(saved.endDate).timeIntervalSince(start), 1_200, accuracy: 1)
        XCTAssertEqual(saved.workoutMetadata?.distanceMeters ?? 0, 3_000, accuracy: 1)
        XCTAssertEqual(saved.workoutMetadata?.samples?.last?.offsetSec, 1_200)
    }

    /// A trim recomputes the power figures over the kept samples: 20 minutes
    /// at 100 W kept of a ride that then held 300 W averages 100 W.
    func testTrimmingARideRecomputesItsPowerFromTheKeptSamples() async throws {
        var workout = savedWorkout(sport: .indoorBike, seconds: 2_400, track: []) { _ in 8 }
        var metadata = try XCTUnwrap(workout.workoutMetadata)
        metadata.samples = metadata.samples?.map {
            WorkoutSample(offsetSec: $0.offsetSec, distanceMeters: $0.distanceMeters, powerWatts: $0.offsetSec <= 1_200 ? 100 : 300)
        }
        metadata.averagePowerWatts = 200
        metadata.peakPowerWatts = 300
        workout.workoutMetadata = metadata
        try archive.archive(workout, skipSameNightMerge: true)

        _ = await collector.recovery.retrimRecoveredWorkout(sessionId: workout.id, endSec: 1_200)

        let saved = try XCTUnwrap(archive.retrieve(workout.id))
        XCTAssertEqual(saved.workoutMetadata?.averagePowerWatts ?? 0, 100, accuracy: 0.5)
        XCTAssertEqual(saved.workoutMetadata?.peakPowerWatts, 100)
    }

    /// A crash-recovered treadmill workout keeps the distance its foot pod
    /// or pedometer counted, which it has no GPS track for.
    func testARecoveredIndoorWorkoutKeepsItsCountedDistance() async throws {
        let backup = collector.recovery.services.workoutTrackBackup
        let id = UUID()
        defer { backup.discard(id) }
        let samples = (1 ... 600).map { WorkoutSample(offsetSec: $0, distanceMeters: Double($0) * 2.5) }
        backup.appendIncremental(
            sessionId: id, sport: .treadmill, startDate: start, track: [], samples: samples, healthKitHROffsets: [], barometricSamples: []
        )

        let outcome = await WorkoutRecoveryService.recover(
            sessionId: id, reason: .appCrashed, archive: archive, rawBackup: collector.recovery.rawBackup,
            cloudSyncManager: collector.recovery.cloudSyncManager, workoutTrackBackup: backup,
            savedRouteStore: collector.recovery.services.savedRouteStore, settingsManager: collector.recovery.settingsManager
        )

        XCTAssertEqual(try XCTUnwrap(outcome?.session.workoutMetadata?.distanceMeters), 1_500, accuracy: 1)
    }

    /// The samples carried from the archived copy are cut on their own
    /// clock, which leaves pauses out: a workout paused for 10 minutes and
    /// trimmed to 30 minutes on the wall clock keeps 20 active minutes.
    func testCarriedSamplesOfAPausedWorkoutAreCutOnTheActiveClock() {
        let pause = [WorkoutPauseSpan(atElapsed: 600, seconds: 600)]
        var archived = HRVSession(
            id: UUID(), startDate: start, endDate: start.addingTimeInterval(2_400), state: .complete,
            sessionType: .workout, rrSeries: nil, analysisResult: nil, artifactFlags: nil
        )
        var oldMeta = WorkoutMetadata(sport: .run)
        oldMeta.samples = (1 ... 1_800).map { WorkoutSample(offsetSec: $0) }
        oldMeta.pauseSpans = pause
        archived.workoutMetadata = oldMeta
        var rebuilt = HRVSession(
            id: archived.id, startDate: start, endDate: start.addingTimeInterval(1_800), state: .complete,
            sessionType: .workout, rrSeries: nil, analysisResult: nil, artifactFlags: nil
        )
        var newMeta = WorkoutMetadata(sport: .run)
        newMeta.pauseSpans = pause
        rebuilt.workoutMetadata = newMeta

        WorkoutRecoveryService.carryForward(from: archived, into: &rebuilt)

        XCTAssertEqual(rebuilt.workoutMetadata?.samples?.last?.offsetSec, 1_200)
    }
}
