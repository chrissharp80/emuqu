@testable import Emuqu
import XCTest

/// Discard for a recording in progress (Record tab → Discard Recording). It
/// must leave nothing of the discarded recording behind (no archived session,
/// no crash-recovery backup, no recording marker for the next launch) and must
/// not touch anything else: a resumed segment's paused night stays.
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

        let outcome = await collector.discardOvernightRecording()

        XCTAssertEqual(outcome, CollectorSessionControl.DiscardOutcome(strapCopyKept: false))
        XCTAssertFalse(collector.isOvernightStreaming)
        XCTAssertFalse(collector.isCollecting)
        XCTAssertNil(collector.currentSession)
        XCTAssertEqual(collector.recordingPhase, .idle)
        XCTAssertNil(PersistedRecordingState.load(), "the next launch must not offer the discarded night")
        XCTAssertNil(collector.rawBackup.backedUpBeatCount(session.id), "no crash-recovery backup may remain")
        XCTAssertFalse(isArchived(session.id))
    }

    func testDiscardWithNothingRecordingDoesNothing() async {
        let collector = makeCollector()
        let outcome = await collector.discardOvernightRecording()
        XCTAssertNil(outcome)
    }

    func testDiscardingAResumedSegmentReturnsToItsPausedNight() async throws {
        let collector = makeCollector()
        let parent = try pausedNight()
        var segment = HRVSession(sessionType: .overnight)
        segment.linkedSessionIds = [parent.id]
        try startRecording(segment, on: collector)

        _ = await collector.discardOvernightRecording()

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

        await collector.discardPausedRecording()

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

        await collector.discardPausedRecording()

        XCTAssertTrue(isArchived(finished.id), "a finished night is never discarded from a pause")
        XCTAssertFalse(isArchived(paused.id))
    }
}
