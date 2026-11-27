@testable import Emuqu
import XCTest

/// A finished workout is dropped as an accidental start only under a minute
/// of wall-clock active time with no heart rate, movement or samples
/// (`WorkoutAccidentalStart`). One that is dropped says so on its summary,
/// keeps its backups until the user leaves it unsaved, and is saved when the
/// user taps Save. A long workout whose ticker was suspended with the phone
/// locked holds a few samples and is saved like any other.
@MainActor
final class WorkoutAccidentalStartTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WorkoutAccidentalStartTests-\(UUID().uuidString)", isDirectory: true)
    private lazy var collector = RRCollector(
        polarManager: PolarManager(), healthKit: HealthKitManager.forTests(),
        archive: SessionArchive(directory: directory),
        settingsManager: AppDependencies.current.app.settingsManager,
        services: CollectorServices(.current)
    )

    override func setUp() async throws {
        try await super.setUp()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        isolateFromHostRecordingState()
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private struct Row {
        let name: String
        let beats: Int
        let meters: Double?
        let samples: Int
        let activeSeconds: TimeInterval
        let accidental: Bool
    }

    /// The rule across its inputs: time decides first, and any one sign of a
    /// real recording keeps a short workout.
    func testOnlyAShortWorkoutWithNothingRecordedIsAccidental() {
        let rows = [
            Row(name: "a 40-minute workout with a suspended ticker", beats: 0, meters: nil, samples: 8, activeSeconds: 2_400, accidental: false),
            Row(name: "exactly a minute", beats: 0, meters: nil, samples: 0, activeSeconds: 60, accidental: false),
            Row(name: "a 20-second tap", beats: 0, meters: nil, samples: 20, activeSeconds: 20, accidental: true),
            Row(name: "20 seconds of heart rate", beats: 60, meters: nil, samples: 20, activeSeconds: 20, accidental: false),
            Row(name: "20 seconds of movement", beats: 0, meters: 51, samples: 20, activeSeconds: 20, accidental: false),
            Row(name: "30 samples", beats: 0, meters: nil, samples: 30, activeSeconds: 40, accidental: false)
        ]
        for row in rows {
            let accidental = WorkoutAccidentalStart.isAccidental(
                beats: row.beats, distanceMeters: row.meters, sampleCount: row.samples, activeSeconds: row.activeSeconds
            )
            XCTAssertEqual(accidental, row.accidental, row.name)
        }
    }

    private func makeRecorder() -> WorkoutRecorder {
        WorkoutRecorder(core: collector.recordingCore, conversation: VoiceConversationController.shared, services: WorkoutServices(.current))
    }

    /// An indoor workout with no heart-rate source that ran `seconds` on the
    /// wall clock and took `samples` per-second samples before the phone
    /// locked, with a crash backup on disk.
    private func startedWorkout(on recorder: WorkoutRecorder, seconds: TimeInterval, samples: Int) -> HRVSession {
        var session = HRVSession(sessionType: .workout)
        session.workoutMetadata = WorkoutMetadata(sport: .crossFit)
        let start = Date().addingTimeInterval(-seconds)
        recorder.lifecycle.activeHRSource = .none
        recorder.lifecycle.currentSession = session
        recorder.lifecycle.sessionStartDate = start
        recorder.lifecycle.elapsedSeconds = samples
        recorder.capture.workoutSamples = (0..<samples).map { WorkoutSample(offsetSec: $0) }
        recorder.lifecycle.phase = .recording
        let backup = recorder.session.services.workoutTrackBackup
        backup.appendIncremental(
            sessionId: session.id, sport: .crossFit, startDate: start, track: [],
            samples: recorder.capture.workoutSamples, healthKitHROffsets: [], barometricSamples: []
        )
        addTeardownBlock { @MainActor in backup.discard(session.id) }
        return session
    }

    private func summary(of recorder: WorkoutRecorder, _ session: HRVSession) -> FitnessPostSummaryView {
        FitnessPostSummaryView(
            session: recorder.lifecycle.finishedSession ?? session, onDone: {},
            saveRetry: FitnessPostSummaryView.SaveRetry(
                lifecycle: recorder.lifecycle,
                retry: { recorder.session.retryUnsavedWorkouts() },
                save: { recorder.session.saveNotArchived() }
            )
        )
    }

    /// 40 minutes with the ticker suspended after 8 samples: saved.
    func testALongWorkoutWithFewSamplesIsSaved() async {
        let recorder = makeRecorder()
        let workout = startedWorkout(on: recorder, seconds: 2_400, samples: 8)

        await recorder.stop()

        XCTAssertEqual(recorder.lifecycle.saveOutcome, .saved)
        XCTAssertTrue(collector.archive.store.exists(workout.id))
        XCTAssertFalse(summary(of: recorder, workout).isNotArchived)
    }

    /// A workout saved with its active time shows it, though its samples
    /// stop at the lock; one saved before that existed reads as it did.
    func testTheDurationShownIsTheStoredActiveTimeWhenThereIsOne() {
        var metadata = WorkoutMetadata(sport: .crossFit)
        metadata.samples = (1 ... 8).map { WorkoutSample(offsetSec: $0) }
        XCTAssertEqual(WorkoutActiveTime.seconds(metadata: metadata, wallClock: 2_400), 8, "an older workout reads as before")

        metadata.activeSeconds = 2_400
        XCTAssertEqual(WorkoutActiveTime.seconds(metadata: metadata, wallClock: 2_400), 2_400)
        XCTAssertEqual(metadata.movingSeconds(wallClockDuration: 2_400), 2_400)
    }

    /// The 40-minute workout saves its active time.
    func testALongWorkoutStoresItsActiveTime() async {
        let recorder = makeRecorder()
        _ = startedWorkout(on: recorder, seconds: 2_400, samples: 8)

        await recorder.stop()

        XCTAssertEqual(recorder.lifecycle.finishedSession?.workoutMetadata?.activeSeconds ?? 0, 2_400, accuracy: 3)
    }

    /// A 10-second tap: not saved, the summary says so, and the backups stay
    /// until the user decides. Save keeps it.
    func testAnAccidentalStartIsKeptUntilTheUserSavesIt() async {
        let recorder = makeRecorder()
        let workout = startedWorkout(on: recorder, seconds: 10, samples: 5)

        await recorder.stop()

        XCTAssertEqual(recorder.lifecycle.saveOutcome, .notArchived)
        XCTAssertFalse(collector.archive.store.exists(workout.id))
        let sheet = summary(of: recorder, workout)
        XCTAssertTrue(sheet.isNotArchived, "the summary says nothing was saved")
        XCTAssertNotNil(recorder.session.services.workoutTrackBackup.retrieve(workout.id), "no backup is retired for a session the archive does not hold")

        sheet.saveRetry?.save()

        XCTAssertEqual(recorder.lifecycle.saveOutcome, .saved)
        XCTAssertTrue(collector.archive.store.exists(workout.id))
        XCTAssertFalse(sheet.isNotArchived)
    }

    /// Leaving an accidental start's summary without saving lets it go.
    func testLeavingAnAccidentalStartUnsavedRetiresItsBackups() async {
        let recorder = makeRecorder()
        let workout = startedWorkout(on: recorder, seconds: 10, samples: 5)
        await recorder.stop()

        recorder.acknowledgeFinished()

        XCTAssertNil(recorder.session.services.workoutTrackBackup.retrieve(workout.id))
        XCTAssertFalse(collector.archive.store.exists(workout.id))
    }
}
