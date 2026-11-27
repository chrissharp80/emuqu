@testable import Emuqu
import XCTest

/// Work that suspends and then writes the recording session's state (a stop's
/// analysis, a review's acceptance, a discard, a crash recovery) holds the
/// recorder while it runs, so no recording starts under it, and when it
/// resumes it writes only while its own session is still the one on the
/// recorder.
@MainActor
final class RecorderClaimTests: XCTestCase {
    private lazy var directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecorderClaimTests-\(UUID().uuidString)", isDirectory: true)
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

    private func night() -> HRVSession {
        HRVSession(
            id: UUID(), startDate: Date().addingTimeInterval(-8 * 3600), endDate: Date(), state: .complete,
            sessionType: .overnight, rrSeries: nil, analysisResult: nil, artifactFlags: nil
        )
    }

    private func startError(_ start: () async throws -> Void) async -> RRCollector.CollectorError? {
        do {
            try await start()
            return nil
        } catch {
            return error as? RRCollector.CollectorError
        }
    }

    // MARK: - The claim

    func testAClaimBlocksStartsUntilItIsReleased() {
        let state = SessionState()
        XCTAssertFalse(state.blocksStart())
        let first = state.claimRecorder()
        let second = state.claimRecorder()
        XCTAssertTrue(state.blocksStart())
        state.releaseRecorder(first)
        XCTAssertTrue(state.blocksStart(), "the other caller still holds its claim")
        state.releaseRecorder(second)
        XCTAssertFalse(state.blocksStart())
    }

    func testAClaimLeftBehindStopsBlockingOnceStale() {
        let state = SessionState()
        let now = Date()
        _ = state.claimRecorder(now: now.addingTimeInterval(-SessionState.staleRecorderClaimAge - 1))
        XCTAssertFalse(state.blocksStart(now: now))
        _ = state.claimRecorder(now: now.addingTimeInterval(-60))
        XCTAssertTrue(state.blocksStart(now: now))
    }

    /// Every start refuses while the recorder is claimed, before anything
    /// else; with no claim the same start goes on to its next check (no
    /// strap is connected here).
    func testEveryStartIsRefusedWhileTheRecorderIsClaimed() async {
        let starts: [(String, (RRCollector) async throws -> Void)] = [
            ("quick reading", { try $0.quickReading.startStreamingSession(durationSeconds: 120) }),
            ("overnight stream", { try $0.overnightStreaming.startOvernightStreaming(sessionType: .overnight, useDeviceInternalBackup: false) }),
            ("overnight both", { try $0.overnightStreaming.startOvernightStreaming(sessionType: .overnight, useDeviceInternalBackup: true) }),
            ("resume", { try $0.control.resumeOvernightStreaming(linkedSessionId: UUID()) }),
            ("strap recording", { try await $0.deviceRecording.startSession(sessionType: .overnight) })
        ]
        for (name, start) in starts {
            let collector = makeCollector()
            let free = await startError { try await start(collector) }
            XCTAssertEqual(free, .notConnected, name)
            let claim = collector.sessionState.claimRecorder()
            let claimed = await startError { try await start(collector) }
            XCTAssertEqual(claimed, .alreadyRecording, name)
            collector.sessionState.releaseRecorder(claim)
        }
    }

    // MARK: - Writes after resuming

    /// The one rule work applies when it resumes: the recorder is taken only
    /// when a session other than the one found before is on it now.
    func testTheRecorderIsTakenOnlyByAnotherSession() {
        let state = SessionState()
        let own = night()
        let other = night()
        let cases: [(before: UUID?, now: HRVSession?, taken: Bool)] = [
            (own.id, own, false),
            (own.id, nil, false),
            (nil, nil, false),
            (own.id, other, true),
            (nil, other, true)
        ]
        for c in cases {
            state.currentSession = c.now
            XCTAssertEqual(state.recorderTaken(since: c.before), c.taken, "before \(String(describing: c.before)), now \(String(describing: c.now?.id))")
        }
    }

    func testAReviewEndingLateLeavesTheSessionThatTookTheRecorder() {
        let collector = makeCollector()
        let reviewed = night()
        let next = night()
        collector.sessionState.currentSession = next
        collector.sessionState.recordingPhase = .overnightStreaming

        collector.morning.clearAcceptanceState(of: reviewed.id)

        XCTAssertEqual(collector.sessionState.currentSession?.id, next.id)
        XCTAssertEqual(collector.sessionState.recordingPhase, .overnightStreaming)
    }

    func testAReviewEndingClearsItsOwnSession() {
        let collector = makeCollector()
        let reviewed = night()
        collector.sessionState.currentSession = reviewed
        collector.sessionState.needsAcceptance = true
        collector.sessionState.recordingPhase = .awaitingAcceptance

        collector.morning.clearAcceptanceState(of: reviewed.id)

        XCTAssertNil(collector.sessionState.currentSession)
        XCTAssertFalse(collector.sessionState.needsAcceptance)
        XCTAssertEqual(collector.sessionState.recordingPhase, .idle)
    }

    /// Discarding a review clears its own recording marker only: a workout
    /// started meanwhile keeps the marker that lets the next launch recover it.
    func testRejectingAReviewKeepsAnotherRecordingsMarker() async {
        let collector = makeCollector()
        let workoutId = UUID()
        collector.recordingStore.persist(sessionId: workoutId, startTime: Date(), sessionType: .workout)
        collector.sessionState.currentSession = night()

        await collector.morning.rejectSession()

        XCTAssertEqual(collector.recordingStore.load()?.sessionId, workoutId)
    }

    func testRejectingAReviewClearsItsOwnMarker() async {
        let collector = makeCollector()
        let reviewed = night()
        collector.recordingStore.persist(sessionId: reviewed.id, startTime: reviewed.startDate, sessionType: .overnight)
        collector.sessionState.currentSession = reviewed

        await collector.morning.rejectSession()

        XCTAssertNil(collector.recordingStore.load())
    }
}
