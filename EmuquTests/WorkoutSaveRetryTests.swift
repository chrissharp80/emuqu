@testable import Emuqu
import UIKit
import XCTest

/// A finished workout whose archive write fails is reported as not saved yet,
/// kept, and saved by a retry, which runs the post-save steps (signal, backup
/// retirement, iCloud upload, Health export) once and only after the write.
@MainActor
final class WorkoutSaveRetryTests: XCTestCase {
    private struct DiskFull: Error {}

    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WorkoutSaveRetryTests-\(UUID().uuidString)", isDirectory: true)
    private lazy var collector = RRCollector(
        polarManager: PolarManager(), healthKit: HealthKitManager.forTests(),
        archive: SessionArchive(directory: directory),
        settingsManager: AppDependencies.current.app.settingsManager,
        services: CollectorServices(.current)
    )

    override func setUp() async throws {
        try await super.setUp()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private func makeRecorder() -> WorkoutRecorder {
        WorkoutRecorder(core: collector.recordingCore, conversation: VoiceConversationController.shared, services: WorkoutServices(.current))
    }

    private func finishedWorkout() -> HRVSession {
        var session = HRVSession(sessionType: .workout)
        session.workoutMetadata = WorkoutMetadata(sport: .run)
        session.state = .complete
        session.endDate = Date()
        return session
    }

    /// Counts each run of the post-save steps.
    private final class StepCounter {
        var runs: [UUID] = []
    }

    private func failWritesAndCountSteps(on recorder: WorkoutRecorder) -> StepCounter {
        let counter = StepCounter()
        recorder.session.saveSeam.write = { _ in throw DiskFull() }
        recorder.session.saveSeam.didRunPostSaveSteps = { counter.runs.append($0.id) }
        return counter
    }

    func testAFailedWriteIsNotSavedYetAndKeepsTheWorkout() {
        let recorder = makeRecorder()
        let counter = failWritesAndCountSteps(on: recorder)
        let workout = finishedWorkout()

        XCTAssertEqual(recorder.session.archive(session: workout), .notSavedYet)
        XCTAssertTrue(recorder.lifecycle.isUnsaved(workout.id))
        XCTAssertFalse(collector.archive.store.exists(workout.id))
        XCTAssertEqual(counter.runs, [], "no post-save step runs before the save")
    }

    func testASuccessfulWriteIsSavedAndRunsTheStepsOnce() {
        let recorder = makeRecorder()
        let counter = failWritesAndCountSteps(on: recorder)
        recorder.session.saveSeam.write = nil
        let workout = finishedWorkout()

        XCTAssertEqual(recorder.session.archive(session: workout), .saved)
        XCTAssertTrue(collector.archive.store.exists(workout.id))
        XCTAssertFalse(recorder.lifecycle.isUnsaved(workout.id))
        XCTAssertEqual(counter.runs, [workout.id])
    }

    /// Repeated retries (Try Again tapped twice, an unlock and the activation
    /// after it) save the workout once and run its steps once.
    func testRetriesSaveOnceAndRunThePostSaveStepsOnce() {
        let recorder = makeRecorder()
        let counter = failWritesAndCountSteps(on: recorder)
        let workout = finishedWorkout()
        _ = recorder.session.archive(session: workout)

        recorder.session.retryUnsavedWorkouts()
        XCTAssertTrue(recorder.lifecycle.isUnsaved(workout.id), "still failing: kept")
        XCTAssertEqual(counter.runs, [])

        recorder.session.saveSeam.write = nil
        recorder.session.retryUnsavedWorkouts()
        recorder.session.retryUnsavedWorkouts()

        XCTAssertTrue(collector.archive.store.exists(workout.id))
        XCTAssertFalse(recorder.lifecycle.isUnsaved(workout.id))
        XCTAssertEqual(counter.runs, [workout.id])
    }

    /// The unlock notification retries the save without the user doing anything.
    func testUnlockRetriesTheSave() async throws {
        let recorder = makeRecorder()
        let counter = failWritesAndCountSteps(on: recorder)
        let workout = finishedWorkout()
        _ = recorder.session.archive(session: workout)
        recorder.session.saveSeam.write = nil

        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        let deadline = Date().addingTimeInterval(5)
        while counter.runs.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(counter.runs, [workout.id])
        XCTAssertTrue(collector.archive.store.exists(workout.id))
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(counter.runs, [workout.id], "a later trigger finds nothing left to save")
    }

    /// A workout another path already put in the archive is let go, and its
    /// steps are not run a second time here.
    func testARetryOfAWorkoutAlreadyInTheArchiveDoesNotSaveItAgain() throws {
        let recorder = makeRecorder()
        let counter = failWritesAndCountSteps(on: recorder)
        let workout = finishedWorkout()
        _ = recorder.session.archive(session: workout)
        try collector.archive.archive(workout)

        recorder.session.saveSeam.write = nil
        recorder.session.retryUnsavedWorkouts()

        XCTAssertFalse(recorder.lifecycle.isUnsaved(workout.id))
        XCTAssertEqual(counter.runs, [])
    }

    /// A workout waiting for its retry is not offered as a lost session or as
    /// an interrupted workout, so launch-time and manual recovery cannot save
    /// it a second time from its backup.
    func testAnUnsavedWorkoutIsLeftOutOfRecovery() {
        let recorder = makeRecorder()
        _ = failWritesAndCountSteps(on: recorder)
        let box = AppDependencies.current.app.recorderBox
        let previous = box.recorder
        box.recorder = recorder
        addTeardownBlock { @MainActor in box.recorder = previous }
        let workout = finishedWorkout()
        _ = recorder.session.archive(session: workout)

        XCTAssertTrue(collector.recovery.liveRecordingIds().contains(workout.id))
    }

    /// End to end through Stop: the failed write reaches the recorder's
    /// outcome and the summary's banner, and the summary's Try Again saves
    /// the workout and clears both.
    func testStopCarriesTheOutcomeToTheSummaryAndTryAgainSavesIt() async {
        let recorder = makeRecorder()
        let counter = failWritesAndCountSteps(on: recorder)
        let workout = startedWorkout(on: recorder)

        await recorder.stop()

        XCTAssertEqual(recorder.lifecycle.phase, .finished)
        XCTAssertEqual(recorder.lifecycle.saveOutcome, .notSavedYet)
        let finished = try? XCTUnwrap(recorder.lifecycle.finishedSession)
        XCTAssertEqual(finished?.id, workout.id)
        let summary = FitnessPostSummaryView(
            session: finished ?? workout, onDone: {},
            saveRetry: FitnessPostSummaryView.SaveRetry(
                lifecycle: recorder.lifecycle,
                retry: { recorder.session.retryUnsavedWorkouts() },
                save: { recorder.session.saveNotArchived() }
            )
        )
        XCTAssertTrue(summary.isNotSavedYet)
        XCTAssertEqual(counter.runs, [])

        recorder.session.saveSeam.write = nil
        summary.saveRetry?.retry()

        XCTAssertFalse(summary.isNotSavedYet)
        XCTAssertEqual(recorder.lifecycle.saveOutcome, .saved)
        XCTAssertTrue(collector.archive.store.exists(workout.id))
        XCTAssertEqual(counter.runs, [workout.id])
    }

    /// A workout recording with no heart-rate source and enough samples to
    /// count as a real one, not an accidental start.
    private func startedWorkout(on recorder: WorkoutRecorder) -> HRVSession {
        var session = HRVSession(sessionType: .workout)
        session.workoutMetadata = WorkoutMetadata(sport: .run)
        recorder.lifecycle.activeHRSource = .none
        recorder.lifecycle.currentSession = session
        recorder.lifecycle.sessionStartDate = Date().addingTimeInterval(-600)
        recorder.lifecycle.elapsedSeconds = 600
        recorder.capture.workoutSamples = (0..<60).map { WorkoutSample(offsetSec: $0 * 10, heartRate: 120) }
        recorder.lifecycle.phase = .recording
        return session
    }
}
