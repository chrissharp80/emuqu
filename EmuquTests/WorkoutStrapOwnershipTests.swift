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

    /// A delete from the summary resumes after its trash write; another
    /// workout finished meanwhile owns the summary and keeps it.
    func testADeleteAcknowledgesOnlyTheSummaryOfTheWorkoutItDeleted() {
        let recorder = makeRecorder()
        let deleted = HRVSession(sessionType: .workout)
        let showing = HRVSession(sessionType: .workout)
        recorder.lifecycle.phase = .finished
        recorder.lifecycle.finishedSession = showing

        recorder.acknowledgeFinished(of: deleted.id)
        XCTAssertEqual(recorder.lifecycle.phase, .finished)
        XCTAssertEqual(recorder.lifecycle.finishedSession?.id, showing.id)

        recorder.acknowledgeFinished(of: showing.id)
        XCTAssertEqual(recorder.lifecycle.phase, .idle)
        XCTAssertNil(recorder.lifecycle.finishedSession)
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

    /// The beat after a PPI interval the quality gate rejected is marked as
    /// following a removed beat, also when the rejection ended the batch
    /// before; the beats around it otherwise are not.
    func testABeatAfterARejectedPPIIntervalIsMarked() {
        let stream = streamBuffering(since: Date())
        stream.ppiRemovedSinceLastBeat = false
        let good = StrapPPIReading(ppInMs: 800, ppErrorEstimate: 5, blockerBit: 0, hr: 70)
        let rejected = StrapPPIReading(ppInMs: 800, ppErrorEstimate: 60, blockerBit: 1, hr: 70)
        stream.ingestPpi([good, good, rejected])
        stream.ingestPpi([good, good])
        XCTAssertEqual(stream.streamedRRPoints.map(\.isAfterRemovedBeat), [false, false, true, false])
    }

    /// A Verity Sense keeps sending its heart rate while every PPI interval
    /// is rejected (motion-flagged, high error estimate: common running).
    /// The strap stays live from that reading, the live heart rate and the
    /// per-second sample carry it, and the rejected interval feeds no beat.
    func testAStrapStillSendingHeartRateStaysLiveWhileItsIntervalsAreRejected() {
        let recorder = makeRecorder()
        var session = HRVSession(sessionType: .workout)
        session.workoutMetadata = WorkoutMetadata(sport: .run)
        recorder.lifecycle.currentSession = session
        recorder.lifecycle.activeHRSource = .strap
        recorder.lifecycle.phase = .recording
        recorder.lifecycle.elapsedSeconds = 120
        recorder.signals.lastStrapHRAt = Date().addingTimeInterval(-30)
        recorder.workoutHR.currentHR = 140
        let stream = streamBuffering(since: Date().addingTimeInterval(-120))

        stream.ingestPpi([StrapPPIReading(ppInMs: 400, ppErrorEstimate: 60, blockerBit: 1, hr: 152)])
        recorder.ticker.incrementalBackupTick()

        XCTAssertTrue(stream.streamedRRPoints.isEmpty, "a rejected interval is no beat")
        XCTAssertEqual(recorder.workoutHR.currentHR, 152)
        XCTAssertNil(recorder.lifecycle.strapNotice)
        XCTAssertEqual(recorder.capture.workoutSamples.last?.heartRate, 152)
    }

    /// The reading counts once, from when it arrived, and only when newer
    /// than the strap heart rate the workout already took.
    func testOnlyANewerStrapReadingIsTaken() {
        let now = Date()
        XCTAssertEqual(WorkoutTicker.newStrapReading(hr: 150, at: now, lastStrapHRAt: now.addingTimeInterval(-1))?.hr, 150)
        XCTAssertNil(WorkoutTicker.newStrapReading(hr: 150, at: now, lastStrapHRAt: now))
        XCTAssertNil(WorkoutTicker.newStrapReading(hr: 0, at: now, lastStrapHRAt: nil))
        XCTAssertNil(WorkoutTicker.newStrapReading(hr: 150, at: nil, lastStrapHRAt: nil))
    }
}
