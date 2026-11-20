@testable import Emuqu
import XCTest

/// Discard for a recording in progress (Record tab → Discard Recording). It
/// must leave nothing of the discarded recording behind (no archived session,
/// no crash-recovery backup, no recording marker for the next launch) and must
/// not touch anything else: a resumed segment's paused night stays. Discard
/// shares one rule with Stop and Pause, tested here too: only one of them
/// ends a night, and the night stays live until its ending is over.
@MainActor
final class RecordingDiscardTests: XCTestCase {
    private lazy var directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecordingDiscardTests-\(UUID().uuidString)", isDirectory: true)
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

    private func makeCollector() -> RRCollector {
        RRCollector.withoutCloudAcceptance(polarManager: PolarManager(), archive: archive)
    }

    private func beats(_ count: Int) -> [RRPoint] {
        (0 ..< count).map { RRPoint(t_ms: Int64($0) * 1000, rr_ms: $0 % 2 == 0 ? 990 : 1010) }
    }

    /// Puts the collector in the state an overnight recording runs in, with
    /// the marker and backup a real one writes.
    private func startRecording(_ session: HRVSession, on collector: RRCollector) throws {
        collector.currentSession = session
        collector.isOvernightStreaming = true
        collector.isStreamingMode = true
        collector.isCollecting = true
        collector.recordingPhase = .overnightStreaming
        collector.persistRecordingState(sessionId: session.id, startTime: session.startDate, sessionType: .overnight)
        _ = try collector.rawBackup.backup(points: beats(300), sessionId: session.id)
    }

    private func pausedNight(linkedTo parent: UUID? = nil) throws -> HRVSession {
        let id = UUID()
        let start = Date().addingTimeInterval(-3 * 3600)
        var night = HRVSession(
            id: id, startDate: start, endDate: start.addingTimeInterval(3600), state: .paused,
            sessionType: .overnight,
            rrSeries: RRSeries(points: beats(200), sessionId: id, startDate: start),
            analysisResult: nil, artifactFlags: nil
        )
        night.linkedSessionIds = parent.map { [$0] }
        _ = try archive.archive(night, skipSameNightMerge: true)
        return night
    }

    private func isArchived(_ id: UUID) -> Bool {
        archive.entries.contains { $0.sessionId == id }
    }

    func testDiscardEndsTheRecordingAndKeepsNothing() async throws {
        let collector = makeCollector()
        let session = HRVSession(sessionType: .overnight)
        try startRecording(session, on: collector)

        let outcome = await collector.control.discardOvernightRecording()

        XCTAssertEqual(outcome, CollectorSessionControl.DiscardOutcome(strapCopyKept: false))
        XCTAssertFalse(collector.isOvernightStreaming)
        XCTAssertFalse(collector.isCollecting)
        XCTAssertNil(collector.currentSession)
        XCTAssertEqual(collector.recordingPhase, .idle)
        XCTAssertNil(PersistedRecordingState.load(), "the next launch must not offer the discarded night")
        XCTAssertNil(collector.rawBackup.backedUpBeatCount(session.id), "no crash-recovery backup may remain")
        XCTAssertFalse(isArchived(session.id))
        XCTAssertFalse(collector.streamingLifecycle.isEndingOvernight, "the discard released the night's ending")
    }

    func testDiscardWithNothingRecordingDoesNothing() async {
        let collector = makeCollector()
        let outcome = await collector.control.discardOvernightRecording()
        XCTAssertNil(outcome)
    }

    func testDiscardingAResumedSegmentReturnsToItsPausedNight() async throws {
        let collector = makeCollector()
        let parent = try pausedNight()
        var segment = HRVSession(sessionType: .overnight)
        segment.linkedSessionIds = [parent.id]
        try startRecording(segment, on: collector)

        _ = await collector.control.discardOvernightRecording()

        XCTAssertTrue(collector.isPaused)
        XCTAssertEqual(collector.pausedSession?.id, parent.id)
        XCTAssertEqual(collector.recordingPhase, .paused(sessionId: parent.id))
        XCTAssertTrue(isArchived(parent.id), "the paused night the segment continued stays")
        XCTAssertNil(collector.rawBackup.backedUpBeatCount(segment.id))
    }

    func testDiscardingAPausedNightRemovesItAndTheSegmentsItWasBuiltFrom() async throws {
        let collector = makeCollector()
        let first = try pausedNight()
        let second = try pausedNight(linkedTo: first.id)
        collector.pausedSession = second
        collector.currentSession = second
        collector.isPaused = true
        collector.recordingPhase = .paused(sessionId: second.id)

        await collector.control.discardPausedRecording()

        XCTAssertFalse(isArchived(first.id))
        XCTAssertFalse(isArchived(second.id))
        XCTAssertFalse(collector.isPaused)
        XCTAssertNil(collector.pausedSession)
        XCTAssertEqual(collector.recordingPhase, .idle)
    }

    func testDiscardingAPausedNightLeavesAFinishedNightItWasLinkedTo() async throws {
        let collector = makeCollector()
        var finished = try pausedNight()
        finished.state = .complete
        _ = try archive.archive(finished, skipSameNightMerge: true)
        let paused = try pausedNight(linkedTo: finished.id)
        collector.pausedSession = paused
        collector.isPaused = true

        await collector.control.discardPausedRecording()

        XCTAssertTrue(isArchived(finished.id), "a finished night is never discarded from a pause")
        XCTAssertFalse(isArchived(paused.id))
    }

    func testAPausedNightTheArchiveCannotDeleteStaysPaused() async throws {
        let collector = makeCollector()
        let paused = try pausedNight()
        collector.pausedSession = paused
        collector.currentSession = paused
        collector.isPaused = true
        collector.recordingPhase = .paused(sessionId: paused.id)
        try blockDeletedIndexWrites()

        await collector.control.discardPausedRecording()

        XCTAssertTrue(isArchived(paused.id), "the archive refused the delete")
        XCTAssertTrue(collector.isPaused, "a night still in the archive stays paused, so Discard can be tapped again")
        XCTAssertEqual(collector.pausedSession?.id, paused.id)
        XCTAssertEqual(collector.recordingPhase, .paused(sessionId: paused.id))
        XCTAssertNotNil(collector.lastError, "the failed discard is shown")
    }

    // MARK: - One ending per night

    func testOnlyOneCallerCanClaimANightsEnding() {
        let lifecycle = StreamingLifecycle()
        XCTAssertFalse(lifecycle.claimOvernightEnding(), "no night is streaming")
        lifecycle.isOvernightStreaming = true
        XCTAssertTrue(lifecycle.claimOvernightEnding())
        XCTAssertFalse(lifecycle.claimOvernightEnding(), "a second caller may not end the same night")
        lifecycle.releaseOvernightEnding()
        XCTAssertFalse(lifecycle.isEndingOvernight)
        XCTAssertTrue(lifecycle.claimOvernightEnding(), "a released ending can be claimed again")
    }

    /// Stop, Pause and Discard each claim the night's ending before they
    /// first suspend. A night another of them is already ending is left as it
    /// was by all three, and by the strap-only Stop and Discard the Record
    /// screen routes to once the stream is down.
    func testANightAlreadyBeingEndedIsLeftToTheCallerEndingIt() async throws {
        let collector = makeCollector()
        let session = HRVSession(sessionType: .overnight)
        try startRecording(session, on: collector)
        XCTAssertTrue(collector.streamingLifecycle.claimOvernightEnding())

        let stopped = await collector.stopOvernightStreaming()
        let paused = await collector.pauseOvernightStreaming()
        let discarded = await collector.control.discardOvernightRecording()
        let strapDiscarded = await collector.control.discardDeviceRecording()
        let strapStopped = try await collector.stopSession()

        XCTAssertNil(stopped)
        XCTAssertNil(paused)
        XCTAssertNil(discarded)
        XCTAssertFalse(strapDiscarded)
        XCTAssertNil(strapStopped)
        XCTAssertTrue(collector.isOvernightStreaming)
        XCTAssertTrue(collector.isCollecting)
        XCTAssertEqual(collector.currentSession?.id, session.id)
        XCTAssertEqual(collector.recordingPhase, .overnightStreaming)
        XCTAssertEqual(PersistedRecordingState.load()?.sessionId, session.id)
        XCTAssertEqual(collector.rawBackup.backedUpBeatCount(session.id), 300)
    }

    /// The gather drops the streaming and collecting flags before the
    /// download and the archive. The night still counts as live until its
    /// ending is over, so Lost Sessions does not offer it and recovery leaves
    /// the strap alone.
    func testANightBeingEndedStaysLiveUntilItsEndingIsOver() throws {
        let collector = makeCollector()
        let session = HRVSession(sessionType: .overnight)
        try startRecording(session, on: collector)
        XCTAssertTrue(collector.streamingLifecycle.claimOvernightEnding())
        collector.isOvernightStreaming = false
        collector.isCollecting = false

        XCTAssertTrue(collector.recovery.liveRecordingIds().contains(session.id))
        XCTAssertTrue(collector.recovery.strapRecordingBelongsToLiveSession)

        collector.streamingLifecycle.releaseOvernightEnding()

        XCTAssertFalse(collector.recovery.liveRecordingIds().contains(session.id))
        XCTAssertFalse(collector.recovery.strapRecordingBelongsToLiveSession)
    }

    /// The short pause shows gather's failed placeholder and persists the
    /// paused marker before it publishes the pause. Acknowledging the error
    /// then resets nothing, so the marker survives.
    func testAResetWhileANightIsBeingEndedChangesNothing() throws {
        let collector = makeCollector()
        isolateFromHostPausedNight(collector)
        let session = HRVSession(sessionType: .overnight)
        try startRecording(session, on: collector)
        XCTAssertTrue(collector.streamingLifecycle.claimOvernightEnding())
        collector.isOvernightStreaming = false
        collector.currentSession?.state = .failed
        collector.persistPausedSessionState(sessionId: session.id)

        collector.resetSession()

        XCTAssertEqual(collector.currentSession?.id, session.id)
        XCTAssertEqual(collector.control.getPersistedPausedSessionId(), session.id)
    }

    func testAResetKeepsAPausedMarkerWithNoPausedSessionShown() {
        let collector = makeCollector()
        isolateFromHostPausedNight(collector)
        let pausedId = UUID()
        collector.persistPausedSessionState(sessionId: pausedId)

        collector.resetSession()

        XCTAssertEqual(collector.control.getPersistedPausedSessionId(), pausedId)
    }

    func testAResetOfAPausedNightClearsItsMarker() throws {
        let collector = makeCollector()
        isolateFromHostPausedNight(collector)
        let paused = try pausedNight()
        collector.pausedSession = paused
        collector.isPaused = true
        collector.persistPausedSessionState(sessionId: paused.id)

        collector.resetSession()

        XCTAssertNil(collector.control.getPersistedPausedSessionId())
        XCTAssertNil(collector.pausedSession)
    }

    /// The paused-night marker lives in the standard defaults; the host's is
    /// put back after the test.
    private func isolateFromHostPausedNight(_ collector: RRCollector) {
        let savedId = collector.control.getPersistedPausedSessionId()
        let savedMode = collector.control.persistedPausedCaptureMode()
        collector.clearPausedSessionState()
        addTeardownBlock { @MainActor in
            collector.clearPausedSessionState()
            guard let savedId else { return }
            collector.useDeviceBackupForOvernight = savedMode ?? true
            collector.persistPausedSessionState(sessionId: savedId)
        }
    }

    /// Puts a directory where the archive writes its deleted-session index, so
    /// every delete in this test's archive fails and rolls back.
    private func blockDeletedIndexWrites() throws {
        let deletedIndex = archive.deletedIndexFile
        if FileManager.default.fileExists(atPath: deletedIndex.path) {
            try FileManager.default.removeItem(at: deletedIndex)
        }
        try FileManager.default.createDirectory(at: deletedIndex, withIntermediateDirectories: true)
        try Data("blocked".utf8).write(to: deletedIndex.appendingPathComponent("blocker"))
    }
}
