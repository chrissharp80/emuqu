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
        collector.sessionState.currentSession = session
        collector.streamingLifecycle.isOvernightStreaming = true
        collector.streamingLifecycle.isStreamingMode = true
        collector.sessionState.isCollecting = true
        collector.sessionState.recordingPhase = .overnightStreaming
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
        XCTAssertFalse(collector.streamingLifecycle.isOvernightStreaming)
        XCTAssertFalse(collector.sessionState.isCollecting)
        XCTAssertNil(collector.sessionState.currentSession)
        XCTAssertEqual(collector.sessionState.recordingPhase, .idle)
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

        XCTAssertTrue(collector.streamingLifecycle.isPaused)
        XCTAssertEqual(collector.streamingLifecycle.pausedSession?.id, parent.id)
        XCTAssertEqual(collector.sessionState.recordingPhase, .paused(sessionId: parent.id))
        XCTAssertTrue(isArchived(parent.id), "the paused night the segment continued stays")
        XCTAssertNil(collector.rawBackup.backedUpBeatCount(segment.id))
    }

    func testDiscardingAPausedNightRemovesItAndTheSegmentsItWasBuiltFrom() async throws {
        let collector = makeCollector()
        let first = try pausedNight()
        let second = try pausedNight(linkedTo: first.id)
        collector.streamingLifecycle.pausedSession = second
        collector.sessionState.currentSession = second
        collector.streamingLifecycle.isPaused = true
        collector.sessionState.recordingPhase = .paused(sessionId: second.id)

        await collector.control.discardPausedRecording()

        XCTAssertFalse(isArchived(first.id))
        XCTAssertFalse(isArchived(second.id))
        XCTAssertFalse(collector.streamingLifecycle.isPaused)
        XCTAssertNil(collector.streamingLifecycle.pausedSession)
        XCTAssertEqual(collector.sessionState.recordingPhase, .idle)
    }

    func testDiscardingAPausedNightLeavesAFinishedNightItWasLinkedTo() async throws {
        let collector = makeCollector()
        var finished = try pausedNight()
        finished.state = .complete
        _ = try archive.archive(finished, skipSameNightMerge: true)
        let paused = try pausedNight(linkedTo: finished.id)
        collector.streamingLifecycle.pausedSession = paused
        collector.streamingLifecycle.isPaused = true

        await collector.control.discardPausedRecording()

        XCTAssertTrue(isArchived(finished.id), "a finished night is never discarded from a pause")
        XCTAssertFalse(isArchived(paused.id))
    }

    func testAPausedNightTheArchiveCannotDeleteStaysPaused() async throws {
        let collector = makeCollector()
        let paused = try pausedNight()
        collector.streamingLifecycle.pausedSession = paused
        collector.sessionState.currentSession = paused
        collector.streamingLifecycle.isPaused = true
        collector.sessionState.recordingPhase = .paused(sessionId: paused.id)
        try blockDeletedIndexWrites()

        await collector.control.discardPausedRecording()

        XCTAssertTrue(isArchived(paused.id), "the archive refused the delete")
        XCTAssertTrue(collector.streamingLifecycle.isPaused, "a night still in the archive stays paused, so Discard can be tapped again")
        XCTAssertEqual(collector.streamingLifecycle.pausedSession?.id, paused.id)
        XCTAssertEqual(collector.sessionState.recordingPhase, .paused(sessionId: paused.id))
        XCTAssertNotNil(collector.sessionState.lastError, "the failed discard is shown")
    }

    // MARK: - One ending per night

    func testOnlyOneCallerCanClaimANightsEnding() throws {
        let lifecycle = StreamingLifecycle()
        XCTAssertNil(lifecycle.claimOvernightEnding(), "no night is streaming")
        lifecycle.isOvernightStreaming = true
        let first = try XCTUnwrap(lifecycle.claimOvernightEnding())
        XCTAssertNil(lifecycle.claimOvernightEnding(), "a second caller may not end the same night")
        lifecycle.releaseOvernightEnding(first)
        XCTAssertFalse(lifecycle.isEndingOvernight)
        XCTAssertNotNil(lifecycle.claimOvernightEnding(), "a released ending can be claimed again")
    }

    /// A claim left behind longer than any ending takes is dropped for a new
    /// night, and then holds nothing: releasing it late leaves the new
    /// night's ending claimed.
    func testAStaleClaimDroppedForANewNightCannotReleaseTheNextOne() throws {
        let lifecycle = StreamingLifecycle()
        lifecycle.isOvernightStreaming = true
        let claimed = Date()
        let stale = try XCTUnwrap(lifecycle.claimOvernightEnding(now: claimed))

        let later = claimed.addingTimeInterval(StreamingLifecycle.staleEndingClaimAge + 60)
        XCTAssertEqual(
            lifecycle.clearEndingForNewNight(now: later),
            .droppedStale(ageSeconds: StreamingLifecycle.staleEndingClaimAge + 60)
        )
        let current = try XCTUnwrap(lifecycle.claimOvernightEnding(now: later))
        lifecycle.releaseOvernightEnding(stale)

        XCTAssertEqual(lifecycle.overnightEndingClaim, current)
    }

    /// An ending still in progress keeps its claim: a night starting meanwhile
    /// is refused instead of taking the recorder from under it.
    func testAnEndingInProgressRefusesANewNightAndKeepsItsClaim() throws {
        let lifecycle = StreamingLifecycle()
        lifecycle.isOvernightStreaming = true
        let claimed = Date()
        let claim = try XCTUnwrap(lifecycle.claimOvernightEnding(now: claimed))

        XCTAssertEqual(lifecycle.clearEndingForNewNight(now: claimed.addingTimeInterval(120)), .endingInProgress)
        XCTAssertEqual(lifecycle.overnightEndingClaim, claim)
        lifecycle.releaseOvernightEnding(claim)
        XCTAssertEqual(lifecycle.clearEndingForNewNight(now: claimed.addingTimeInterval(120)), .clear)
    }

    /// Start, resume, a quick reading and a strap-only recording are all
    /// refused while a night is being ended, before anything is changed.
    func testNothingStartsWhileANightIsBeingEnded() async throws {
        let collector = makeCollector()
        let session = HRVSession(sessionType: .overnight)
        try startRecording(session, on: collector)
        let claim = try XCTUnwrap(collector.streamingLifecycle.claimOvernightEnding())
        collector.streamingLifecycle.isOvernightStreaming = false

        XCTAssertThrowsError(try collector.overnightStreaming.startOvernightStreaming()) { error in
            XCTAssertEqual(error as? RRCollector.CollectorError, .alreadyRecording)
        }
        XCTAssertThrowsError(try collector.resumeOvernightStreaming(linkedSessionId: UUID())) { error in
            XCTAssertEqual(error as? RRCollector.CollectorError, .alreadyRecording)
        }
        XCTAssertThrowsError(try collector.startStreamingSession()) { error in
            XCTAssertEqual(error as? RRCollector.CollectorError, .alreadyRecording)
        }
        do {
            try await collector.deviceRecording.startSession()
            XCTFail("a strap-only recording must not start while a night is being ended")
        } catch {
            XCTAssertEqual(error as? RRCollector.CollectorError, .alreadyRecording)
        }

        XCTAssertEqual(collector.streamingLifecycle.overnightEndingClaim, claim, "the ending keeps its claim")
        XCTAssertEqual(collector.sessionState.currentSession?.id, session.id)
        XCTAssertEqual(collector.sessionState.recordingPhase, .overnightStreaming)
    }

    /// A quick reading or a strap-only recording started while a night is
    /// paused would take over the paused night's session and phase.
    func testAQuickReadingOrStrapRecordingDoesNotStartWhileANightIsPaused() async throws {
        let collector = makeCollector()
        isolateFromHostPausedNight(collector)
        let paused = try pausedNight()
        collector.streamingLifecycle.pausedSession = paused
        collector.sessionState.currentSession = paused
        collector.streamingLifecycle.isPaused = true
        collector.sessionState.recordingPhase = .paused(sessionId: paused.id)

        XCTAssertThrowsError(try collector.startStreamingSession()) { error in
            XCTAssertEqual(error as? RRCollector.CollectorError, .alreadyRecording)
        }
        do {
            try await collector.deviceRecording.startSession()
            XCTFail("a strap-only recording must not start while a night is paused")
        } catch {
            XCTAssertEqual(error as? RRCollector.CollectorError, .alreadyRecording)
        }

        XCTAssertEqual(collector.sessionState.currentSession?.id, paused.id)
        XCTAssertEqual(collector.sessionState.recordingPhase, .paused(sessionId: paused.id))
    }

    /// Stop, Pause and Discard each claim the night's ending before they
    /// first suspend. A night another of them is already ending is left as it
    /// was by all three, and by the strap-only Stop and Discard the Record
    /// screen routes to once the stream is down.
    func testANightAlreadyBeingEndedIsLeftToTheCallerEndingIt() async throws {
        let collector = makeCollector()
        let session = HRVSession(sessionType: .overnight)
        try startRecording(session, on: collector)
        XCTAssertNotNil(collector.streamingLifecycle.claimOvernightEnding())

        let stopped = await collector.overnightStreaming.stopOvernightStreaming()
        let paused = await collector.pauseOvernightStreaming()
        let discarded = await collector.control.discardOvernightRecording()
        let strapDiscarded = await collector.control.discardDeviceRecording()
        let strapStopped = try await collector.deviceRecording.stopSession()

        XCTAssertNil(stopped)
        XCTAssertNil(paused)
        XCTAssertNil(discarded)
        XCTAssertFalse(strapDiscarded)
        XCTAssertNil(collector.sessionState.lastError, "the strap-only discard never asked the strap")
        XCTAssertNil(strapStopped)
        XCTAssertTrue(collector.streamingLifecycle.isOvernightStreaming)
        XCTAssertTrue(collector.sessionState.isCollecting)
        XCTAssertEqual(collector.sessionState.currentSession?.id, session.id)
        XCTAssertEqual(collector.sessionState.recordingPhase, .overnightStreaming)
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
        let claim = try XCTUnwrap(collector.streamingLifecycle.claimOvernightEnding())
        collector.streamingLifecycle.isOvernightStreaming = false
        collector.sessionState.isCollecting = false

        XCTAssertTrue(collector.recovery.liveRecordingIds().contains(session.id))
        XCTAssertTrue(collector.recovery.strapRecordingBelongsToLiveSession)

        collector.streamingLifecycle.releaseOvernightEnding(claim)

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
        XCTAssertNotNil(collector.streamingLifecycle.claimOvernightEnding())
        collector.streamingLifecycle.isOvernightStreaming = false
        collector.sessionState.currentSession?.state = .failed
        collector.persistPausedSessionState(sessionId: session.id)

        collector.resetSession()

        XCTAssertEqual(collector.sessionState.currentSession?.id, session.id)
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
        collector.streamingLifecycle.pausedSession = paused
        collector.streamingLifecycle.isPaused = true
        collector.persistPausedSessionState(sessionId: paused.id)

        collector.resetSession()

        XCTAssertNil(collector.control.getPersistedPausedSessionId())
        XCTAssertNil(collector.streamingLifecycle.pausedSession)
    }

    // MARK: - Continue Recording

    /// Paused, resumed and finished: the paused part stays paused in the
    /// archive, but it is not offered to continue, which would start a second
    /// night that leaves out the resumed part.
    func testAPausedNightThatWasResumedIsNotOfferedToContinue() throws {
        let pausedAt = Date().addingTimeInterval(-2 * 3600)
        let start = pausedAt.addingTimeInterval(-4 * 3600)
        let parentId = UUID()
        let segmentId = UUID()
        var parent = HRVSession(
            id: parentId, startDate: start, endDate: pausedAt, state: .paused, sessionType: .overnight,
            rrSeries: RRSeries(points: beats(200), sessionId: parentId, startDate: start),
            analysisResult: nil, artifactFlags: nil
        )
        parent.pausedDate = pausedAt
        parent.linkedSessionIds = [segmentId]
        var segment = HRVSession(
            id: segmentId, startDate: start, endDate: Date().addingTimeInterval(-600), state: .complete,
            sessionType: .overnight,
            rrSeries: RRSeries(points: beats(400), sessionId: segmentId, startDate: start),
            analysisResult: nil, artifactFlags: nil
        )
        segment.linkedSessionIds = [parentId]
        _ = try archive.archive(parent, skipSameNightMerge: true)
        _ = try archive.archive(segment, skipSameNightMerge: true)

        let offered = CollectorSessionControl.findRecentPausedSessionOffMain(archive: archive, maxGap: 4.5 * 3600)

        XCTAssertNotEqual(offered?.id, parentId)
    }

    /// A paused night nobody resumed is still offered.
    func testAPausedNightNotYetResumedIsOfferedToContinue() throws {
        let paused = try pausedNight()
        try archive.update(paused.id, requestingReupload: false) { $0.pausedDate = Date().addingTimeInterval(-600) }

        let offered = CollectorSessionControl.findRecentPausedSessionOffMain(archive: archive, maxGap: 4.5 * 3600)

        XCTAssertEqual(offered?.id, paused.id)
    }

    // MARK: - Done on a paused night

    /// A sleep refresh rewrote the paused night in the archive after the
    /// pause. Done finalizes the archive's copy, not the one held since the
    /// pause, so the refreshed score stays.
    func testDoneOnAPausedNightKeepsARewriteMadeSinceThePause() throws {
        let collector = makeCollector()
        isolateFromHostPausedNight(collector)
        let paused = try pausedNight()
        collector.streamingLifecycle.pausedSession = paused
        collector.sessionState.currentSession = paused
        collector.streamingLifecycle.isPaused = true
        collector.sessionState.recordingPhase = .paused(sessionId: paused.id)
        try archive.update(paused.id, requestingReupload: false) { $0.recoveryScore = 7.4 }

        collector.finalizeFromPause()

        let finished = try XCTUnwrap(try archive.retrieve(paused.id))
        XCTAssertEqual(finished.state, .complete)
        XCTAssertEqual(finished.recoveryScore, 7.4, "the score from before the refresh was written back")
        XCTAssertEqual(collector.sessionState.currentSession?.recoveryScore, 7.4)
        XCTAssertFalse(collector.streamingLifecycle.isPaused)
        XCTAssertNil(collector.streamingLifecycle.pausedSession)
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
