@testable import Emuqu
import XCTest

/// A finished or non-strap workout touches only the strap stream it started:
/// another session buffering on the same manager keeps its beats.
@MainActor
final class WorkoutStrapOwnershipTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WorkoutStrapOwnershipTests-\(UUID().uuidString)", isDirectory: true)
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

    private func beats(_ count: Int) -> [RRPoint] {
        (0 ..< count).map { RRPoint(t_ms: Int64($0) * 1000, rr_ms: 1000) }
    }

    /// The stream as another session would hold it: live, started at `start`.
    private func streamBuffering(since start: Date, points: [RRPoint] = []) -> StrapStreamSession {
        let stream = collector.recordingCore.strapStream
        stream.isStreaming = true
        stream.streamingStartTime = start
        stream._streamedRRPoints = points
        return stream
    }

    /// Dismissing an old workout's summary (from the Watch, after an overnight
    /// started streaming) leaves the overnight's stream running.
    func testDismissingAnOldSummaryLeavesAnotherSessionsStreamRunning() {
        let recorder = makeRecorder()
        recorder.lifecycle.ownedStrapStreamStart = Date().addingTimeInterval(-3600)
        recorder.lifecycle.phase = .finished
        let stream = streamBuffering(since: Date())

        recorder.acknowledgeFinished()

        XCTAssertEqual(recorder.lifecycle.phase, .idle)
        XCTAssertTrue(stream.isStreaming, "the overnight started after the workout must keep streaming")
    }

    /// The workout's own stream, still open after the HRR window, is stopped.
    func testDismissingTheSummaryStopsTheWorkoutsOwnStream() {
        let recorder = makeRecorder()
        let start = Date().addingTimeInterval(-600)
        recorder.lifecycle.ownedStrapStreamStart = start
        recorder.lifecycle.phase = .finished
        let stream = streamBuffering(since: start)

        recorder.acknowledgeFinished()

        XCTAssertFalse(stream.isStreaming)
    }

    /// A Watch workout never started a stream: the beats a stopped strap
    /// stream kept from an earlier recording are not counted or read as this
    /// workout's heart rate.
    func testAWatchWorkoutDoesNotTakeAStoppedStrapStreamsBeats() {
        let recorder = makeRecorder()
        var session = HRVSession(sessionType: .workout)
        session.workoutMetadata = WorkoutMetadata(sport: .run)
        recorder.lifecycle.currentSession = session
        recorder.lifecycle.activeHRSource = .watch
        let stream = collector.recordingCore.strapStream
        stream._streamedRRPoints = beats(200)

        recorder.ticker.incrementalBackupTick()

        XCTAssertEqual(recorder.workoutHR.beatCount, 0)
        XCTAssertEqual(recorder.workoutHR.peakHR, 0)
    }

    /// The same buffer on a strap workout is the workout's own.
    func testAStrapWorkoutReadsItsStream() {
        XCTAssertEqual(WorkoutRRMerge.liveStrapBuffer(source: .strap, streaming: beats(3)).count, 3)
        XCTAssertTrue(WorkoutRRMerge.liveStrapBuffer(source: .watch, streaming: beats(3)).isEmpty)
        XCTAssertTrue(WorkoutRRMerge.liveStrapBuffer(source: .none, streaming: beats(3)).isEmpty)
    }
}
