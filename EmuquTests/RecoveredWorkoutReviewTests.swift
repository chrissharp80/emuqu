@testable import Emuqu
import XCTest

/// The review/trim card for a recovered workout. Its Save closes the card only
/// once the trimmed workout is in the archive; a recovered workout that cannot
/// be read keeps the card up rather than being taken for one with too few
/// beats to trim.
@MainActor
final class RecoveredWorkoutReviewTests: XCTestCase {
    private lazy var directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecoveredWorkoutReviewTests-\(UUID().uuidString)", isDirectory: true)
    private lazy var archive = SessionArchive(directory: directory)

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

    private func recoveredWorkout() -> HRVSession {
        let id = UUID()
        let start = Date().addingTimeInterval(-2 * 3600)
        let points = (0 ..< 600).map { RRPoint(t_ms: Int64($0) * 500, rr_ms: 500) }
        return HRVSession(
            id: id, startDate: start, endDate: start.addingTimeInterval(300), state: .complete,
            sessionType: .workout,
            rrSeries: RRSeries(points: points, sessionId: id, startDate: start),
            analysisResult: nil, artifactFlags: nil
        )
    }

    private func review(of session: HRVSession) -> MorningCoordination.RecoveredWorkoutReview {
        MorningCoordination.RecoveredWorkoutReview(
            sessionId: session.id, sport: "Workout", durationSec: 300, distanceMeters: 0, avgHR: 120
        )
    }

    func testSaveKeepsTheCardWhenTheRecoveredWorkoutCannotBeRead() async throws {
        let collector = RRCollector.withoutCloudAcceptance(polarManager: PolarManager(), archive: archive)
        let workout = recoveredWorkout()
        let entry = try archive.archive(workout, skipSameNightMerge: true)
        try FileManager.default.removeItem(at: archive.state.resolveFileURL(for: entry))
        let card = review(of: workout)
        collector.morningCoordination.recoveredWorkoutReview = card

        let closed = await collector.recovery.retrimRecoveredWorkout(sessionId: workout.id, endSec: 200)

        XCTAssertFalse(closed, "a Save that stored nothing reports it, so the card can say so")
        XCTAssertEqual(
            collector.morningCoordination.recoveredWorkoutReview, card,
            "an unreadable workout is not one with too few beats: the card stays so Save can be tried again"
        )
        XCTAssertTrue(archive.store.exists(workout.id), "nothing was rewritten or removed")
    }

    /// A recovered workout whose strap died at 20 minutes while the phone
    /// recorded the run to 60: the review shows 60 minutes, and its Save
    /// keeps them. Ending at the last kept beat cut the 40 minutes after it.
    func testSavingARecoveredWorkoutKeepsTheLengthItShowed() async throws {
        let collector = RRCollector.withoutCloudAcceptance(polarManager: PolarManager(), archive: archive)
        let id = UUID()
        let start = Date().addingTimeInterval(-2 * 3600)
        let points = (0 ..< 1_200).map { RRPoint(t_ms: Int64($0) * 1_000, rr_ms: 1_000, wallClockMs: Int64($0) * 1_000, hr: 60) }
        var workout = HRVSession(
            id: id, startDate: start, endDate: start.addingTimeInterval(3_600), state: .complete,
            sessionType: .workout, rrSeries: RRSeries(points: points, sessionId: id, startDate: start),
            analysisResult: nil, artifactFlags: nil
        )
        workout.workoutMetadata = WorkoutMetadata(sport: .run)
        try archive.archive(workout, skipSameNightMerge: true)

        let closed = await collector.recovery.retrimRecoveredWorkout(sessionId: id, endSec: 3_600)

        XCTAssertTrue(closed)
        let saved = try XCTUnwrap(archive.retrieve(id))
        XCTAssertEqual(try XCTUnwrap(saved.endDate).timeIntervalSince(start), 3_600, accuracy: 1)
    }

    /// The trim card shows the wall clock, so a trim keeps the beats up to
    /// that time on the wall clock: a beat after a strap dropout carries a
    /// summed `t_ms` behind it and is still past the trim.
    func testATrimCutsTheBeatsOnTheWallClock() async throws {
        let collector = RRCollector.withoutCloudAcceptance(polarManager: PolarManager(), archive: archive)
        let id = UUID()
        let start = Date().addingTimeInterval(-2 * 3600)
        let before = (0 ..< 600).map { RRPoint(t_ms: Int64($0) * 1_000, rr_ms: 1_000, wallClockMs: Int64($0) * 1_000, hr: 60) }
        let after = (0 ..< 600).map { RRPoint(t_ms: Int64(600 + $0) * 1_000, rr_ms: 1_000, wallClockMs: Int64(1_200 + $0) * 1_000, hr: 60) }
        var workout = HRVSession(
            id: id, startDate: start, endDate: start.addingTimeInterval(1_800), state: .complete,
            sessionType: .workout, rrSeries: RRSeries(points: before + after, sessionId: id, startDate: start),
            analysisResult: nil, artifactFlags: nil
        )
        workout.workoutMetadata = WorkoutMetadata(sport: .run)
        try archive.archive(workout, skipSameNightMerge: true)

        _ = await collector.recovery.retrimRecoveredWorkout(sessionId: id, endSec: 900)

        let saved = try XCTUnwrap(archive.retrieve(id))
        XCTAssertEqual(saved.rrSeries?.points.count, 600, "the beats after the dropout are past the 15-minute trim")
        XCTAssertEqual(try XCTUnwrap(saved.endDate).timeIntervalSince(start), 900, accuracy: 1)
    }

    /// A crash backup's pauses come back with the workout: its pauses are
    /// saved, and its time leaves them out.
    func testARecoveredWorkoutKeepsItsPauses() async throws {
        let collector = RRCollector.withoutCloudAcceptance(polarManager: PolarManager(), archive: archive)
        let backup = collector.recovery.services.workoutTrackBackup
        let id = UUID()
        defer { backup.discard(id) }
        let start = Date().addingTimeInterval(-2 * 3600)
        // 30 min: 10 moving, a 10-minute pause, 10 moving. One sample a second while moving.
        let samples = (1 ... 1_200).map { WorkoutSample(offsetSec: $0, heartRate: 130) }
        backup.appendIncremental(
            sessionId: id, sport: .run, startDate: start, track: [], samples: samples, healthKitHROffsets: [], barometricSamples: []
        )
        var timeline = PauseTimeline()
        timeline.pause(atElapsed: 600, now: start.addingTimeInterval(600))
        timeline.resume(now: start.addingTimeInterval(1_200))
        backup.appendPauses(sessionId: id, events: timeline.events)

        let outcome = await WorkoutRecoveryService.recover(
            sessionId: id, reason: .appCrashed, archive: archive, rawBackup: collector.recovery.rawBackup,
            cloudSyncManager: collector.recovery.cloudSyncManager, workoutTrackBackup: backup,
            savedRouteStore: collector.recovery.services.savedRouteStore, settingsManager: collector.recovery.settingsManager
        )

        let session = try XCTUnwrap(outcome?.session)
        XCTAssertEqual(try XCTUnwrap(session.endDate).timeIntervalSince(start), 1_800, accuracy: 1)
        XCTAssertEqual(session.workoutMetadata?.pauseSpans, [WorkoutPauseSpan(atElapsed: 600, seconds: 600)])
        XCTAssertEqual(session.workoutMetadata?.samples?.count, 1_200, "every moving second is kept")
    }
}
