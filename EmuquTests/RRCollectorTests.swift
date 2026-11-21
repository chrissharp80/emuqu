@testable import Emuqu
import XCTest

/// Tests for RRCollector - Session orchestration and lifecycle.
///
/// These tests verify:
/// - Persisted recording state management
/// - CollectorError descriptions
///
/// Note: Tests that require streaming with a connected device (stopOvernightStreaming,
/// acceptSession, rejectSession) or direct mutation of private(set) properties are
/// integration tests that need a real or mock Polar device connection.
@MainActor
final class RRCollectorTests: XCTestCase {
    /// `lazy`, not an inline initialiser: `setUp` clears persisted state first,
    /// and a stored property would be constructed before that runs — handing the
    /// collector the very state the test just asked to be rid of. Deferring to
    /// first use inside the test body keeps the original ordering.
    lazy var collector = RRCollector()

    private func clearPersistedState() {
        PersistedRecordingState.clear()
        UserDefaults.standard.removeObject(forKey: "RRCollector.activeRecordingStartTime")
        UserDefaults.standard.removeObject(forKey: "RRCollector.activeRecordingSessionId")
        UserDefaults.standard.removeObject(forKey: "RRCollector.activeRecordingSessionType")
    }

    override func setUp() async throws {
        try await super.setUp()
        clearPersistedState()
        pinEnglishLanguage()
    }

    override func tearDown() async throws {
        // Clean up any sessions created during tests
        if let session = collector.currentSession {
            try? collector.archive.delete(session.id)
        }
        clearPersistedState()
        try await super.tearDown()
    }

    // MARK: - Persisted State Tests

    /// Test persisted recording state round-trip
    func testPersistedRecordingStateSaved() {
        let sessionId = UUID()
        let startTime = Date()
        let sessionType = SessionType.overnight

        // Simulate starting a session
        UserDefaults.standard.set(startTime, forKey: "RRCollector.activeRecordingStartTime")
        UserDefaults.standard.set(sessionId.uuidString, forKey: "RRCollector.activeRecordingSessionId")
        UserDefaults.standard.set(sessionType.rawValue, forKey: "RRCollector.activeRecordingSessionType")

        // Retrieve persisted state
        let retrieved = collector.getPersistedRecordingState()

        XCTAssertNotNil(retrieved, "Should retrieve persisted state")
        XCTAssertEqual(retrieved?.sessionId, sessionId)
        XCTAssertEqual(retrieved?.sessionType, sessionType)
    }

    /// Test persisted state detection and clearing
    func testPersistedStateCleared() {
        let sessionId = UUID()
        let startTime = Date()

        // Set persisted state
        UserDefaults.standard.set(startTime, forKey: "RRCollector.activeRecordingStartTime")
        UserDefaults.standard.set(sessionId.uuidString, forKey: "RRCollector.activeRecordingSessionId")
        UserDefaults.standard.set("overnight", forKey: "RRCollector.activeRecordingSessionType")

        // Verify it exists
        XCTAssertTrue(collector.hasPersistedRecordingState)

        // Clear it
        clearPersistedState()

        // Verify it's cleared
        XCTAssertFalse(collector.hasPersistedRecordingState)
    }

    /// Test recovery from persisted state after app restart
    func testRecoveryFromPersistedState() throws {
        let sessionId = UUID()
        let startTime = Date().addingTimeInterval(-3600) // 1 hour ago
        let sessionType = SessionType.overnight

        // Simulate persisted state from previous session
        UserDefaults.standard.set(startTime, forKey: "RRCollector.activeRecordingStartTime")
        UserDefaults.standard.set(sessionId.uuidString, forKey: "RRCollector.activeRecordingSessionId")
        UserDefaults.standard.set(sessionType.rawValue, forKey: "RRCollector.activeRecordingSessionType")

        // Create a fresh collector (simulating app restart)
        let freshCollector = RRCollector()

        // Should detect persisted state
        XCTAssertTrue(freshCollector.hasPersistedRecordingState)

        let recovered = freshCollector.getPersistedRecordingState()
        XCTAssertNotNil(recovered)
        XCTAssertEqual(recovered?.sessionId, sessionId)
        XCTAssertEqual(recovered?.sessionType, sessionType)

        // Start time should match
        let timeDiff = try abs(XCTUnwrap(recovered?.startTime.timeIntervalSince(startTime)))
        XCTAssertLessThan(timeDiff, 1.0, "Start time should match persisted value")
    }
}

// MARK: - CollectorError Tests

extension RRCollectorTests {
    /// Test error descriptions
    func testErrorDescriptions() {
        let errors: [RRCollector.CollectorError] = [
            .notConnected,
            .alreadyRecording,
            .sessionExists,
            .insufficientData,
            .noSessionToAccept,
            .noSessionToRecover,
            .dataAlreadyExists,
            .duplicateImport,
            .importNotAnalyzed,
            .strapStillHoldsNight(missingMinutes: 45)
        ]

        // All errors should have descriptive messages
        for error in errors {
            XCTAssertFalse(error.localizedDescription.isEmpty, "Error should have description")
        }

        // Check specific message
        XCTAssertEqual(
            RRCollector.CollectorError.insufficientData.localizedDescription,
            "Not enough RR data collected (need at least 120 beats)"
        )
    }
}

// MARK: - Save results the screens act on

/// The collector reports whether a re-score's re-archive or a segment unlink
/// was stored, so the screens that call them keep the user's input on a
/// failure instead of acting as if it was saved. Built over a temporary
/// archive, baseline file and a mock HealthKit, never the app's own stores.
@MainActor
final class RRCollectorSaveResultTests: XCTestCase {
    private lazy var directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("RRCollectorSaveResultTests-\(UUID().uuidString)", isDirectory: true)
    private lazy var archive = SessionArchive(
        directory: directory,
        sleepScheduleProvider: { SleepSchedule(bedtimeHour: 22, bedtimeMinute: 0, sleepHours: 8.0) },
        sessionMergeModeProvider: { .off }
    )
    private lazy var collector = makeCollector()

    private let nightStart = Date(timeIntervalSince1970: 4_102_444_800) // 2100-01-01T00:00:00Z

    override func tearDown() async throws {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            // swallow-ok: a test that built no collector and archived nothing leaves no directory.
        }
        try await super.tearDown()
    }

    /// The acceptance service reads sleep and vitals from a mock and syncs
    /// nothing to iCloud; the baseline and the raw backups live in the
    /// test's directory.
    private func makeCollector() -> RRCollector {
        let rawBackup = RawRRBackup(directory: directory.appendingPathComponent(AppConfig.backupDirectoryName, isDirectory: true))
        let tracker = BaselineTracker(baselineFile: directory.appendingPathComponent("HRVBaseline.json"))
        let acceptance = SessionAcceptanceService(
            archive: archive, healthKit: MockHealthKitService(), baselineTracker: tracker, rawBackup: rawBackup,
            onCloudSync: { _ in }, onCloudDelete: { _ in }
        )
        return RRCollector(
            polarManager: PolarManager(), healthKit: HealthKitManager(), archive: archive, rawBackup: rawBackup,
            baselineTracker: tracker, acceptanceService: acceptance
        )
    }

    private func night() -> HRVSession {
        HRVSession(
            id: UUID(), startDate: nightStart, endDate: nightStart.addingTimeInterval(8 * 3600),
            state: .complete, sessionType: .overnight, rrSeries: nil, analysisResult: nil, artifactFlags: nil
        )
    }

    /// An analysis carrying its own training context, so the re-score never
    /// asks HealthKit for the load.
    private func analysis() -> HRVAnalysisResult {
        var result = HRVAnalysisResult(
            windowStart: 0, windowEnd: 400,
            timeDomain: TimeDomainMetrics(
                meanRR: 1035, sdnn: 30, rmssd: 35, pnn50: 12, sdsd: 30, meanHR: 58, sdHR: 3, triangularIndex: nil
            ),
            frequencyDomain: nil,
            nonlinear: NonlinearMetrics(
                sd1: 25, sd2: 40, sd1Sd2Ratio: 0.6, sampleEntropy: 1.5, approxEntropy: 1.3,
                dfaAlpha1: 0.85, dfaAlpha2: nil, dfaAlpha1R2: 0.95
            ),
            ansMetrics: nil, artifactPercentage: 1, cleanBeatCount: 400, analysisDate: nightStart
        )
        result.trainingContext = TrainingContext(
            atl: 0, ctl: 0, tsb: 0, yesterdayTrimp: 0, vo2Max: nil, daysSinceHardWorkout: nil, recentWorkouts: nil
        )
        return result
    }

    // MARK: - Re-score after acceptance

    /// A stored re-score reports true, and the tags carried on the session
    /// (the auto-accept's pre-night tags) reach the archive with it.
    func testScoreUpdateReportsTheStoredReArchiveWithItsTags() async throws {
        var session = night()
        session.analysisResult = analysis()
        try archive.archive(session)
        session.tags = [ReadingTag.alcohol]

        let stored = await collector.updateCompositeRecoveryScore(for: session)

        XCTAssertTrue(stored)
        XCTAssertEqual(try archive.retrieve(session.id)?.tags, [ReadingTag.alcohol])
    }

    /// A session with no analysis is not re-archived: the update reports
    /// false and the tags it carries are not in the archive, so the
    /// auto-accept keeps them selected.
    func testScoreUpdateReportsNothingStoredWithoutAnAnalysis() async throws {
        var session = night()
        try archive.archive(session)
        session.tags = [ReadingTag.alcohol]

        let stored = await collector.updateCompositeRecoveryScore(for: session)

        XCTAssertFalse(stored)
        XCTAssertEqual(try archive.retrieve(session.id)?.tags, [])
    }

    // MARK: - Rescore during review

    /// A night on the review card that this review saved to the archive,
    /// awaiting acceptance, with nothing entered on it yet.
    private func reviewCard() -> HRVSession {
        var card = night()
        card.recoveryScore = 6.1
        collector.currentSession = card
        collector.needsAcceptance = true
        collector.sessionState.reviewArchivedSessionId = card.id
        collector.sessionState.reviewArchivedEntries = SessionState.ReviewEntries(of: card)
        return card
    }

    /// A rescore of the night the review saved reaches the card, which Accept
    /// archives. Entries made on the card are kept; one left alone there
    /// takes the archive's (an edit made in History).
    func testARescoreOfTheReviewedNightReachesTheCardKeepingTheCardsEdits() {
        var card = reviewCard()
        card.tags = [ReadingTag.alcohol]
        card.notes = "late dinner"
        collector.currentSession = card
        var rescored = HRVSession(
            id: card.id, startDate: card.startDate, endDate: card.endDate, state: .complete,
            sessionType: .overnight, rrSeries: nil, analysisResult: nil, artifactFlags: nil
        )
        rescored.recoveryScore = 7.4
        rescored.morningFeeling = 2

        collector.reanalysis.finishRescore(sessionId: card.id, prior: nil, updated: rescored, reason: "sleep")

        XCTAssertEqual(collector.currentSession?.recoveryScore, 7.4)
        XCTAssertEqual(collector.currentSession?.tags, [ReadingTag.alcohol], "edited on the card")
        XCTAssertEqual(collector.currentSession?.notes, "late dinner", "edited on the card")
        XCTAssertEqual(collector.currentSession?.morningFeeling, 2, "left alone on the card, edited in History")
    }

    /// Stop, Retry or Recover into a night already archived leaves the
    /// archive alone until Accept, so the card holds a newer night than the
    /// archive. A rescore of the archived copy must not replace it.
    func testARescoreOfTheOldArchivedCopyLeavesANewerReviewNightAlone() {
        var card = reviewCard()
        collector.sessionState.reviewArchivedSessionId = nil
        card.recoveryScore = 8.2
        collector.currentSession = card
        var oldArchived = card
        oldArchived.recoveryScore = 5.0

        collector.reanalysis.finishRescore(sessionId: card.id, prior: nil, updated: oldArchived, reason: "sleep")

        XCTAssertEqual(collector.currentSession?.recoveryScore, 8.2)
    }

    /// No session awaits acceptance: a rescore leaves the current session.
    func testARescoreWithNothingAwaitingAcceptanceLeavesTheCurrentSession() {
        let card = reviewCard()
        collector.needsAcceptance = false
        var rescored = card
        rescored.recoveryScore = 7.4

        collector.reanalysis.finishRescore(sessionId: card.id, prior: nil, updated: rescored, reason: "sleep")

        XCTAssertEqual(collector.currentSession?.recoveryScore, 6.1)
    }

    func testAnotherSessionsArchivedCopyLeavesTheReviewCardAlone() {
        let card = reviewCard()
        var other = night()
        other.recoveryScore = 7.4

        collector.reanalysis.adoptArchivedCopy(other)

        XCTAssertEqual(collector.currentSession?.id, card.id)
        XCTAssertEqual(collector.currentSession?.recoveryScore, 6.1)
    }

    // MARK: - Segment unlink

    /// No archived parent: nothing is unlinked and the collector says so,
    /// so the report keeps the segment listed.
    func testUnlinkReportsFailureWhenTheParentIsNotArchived() {
        XCTAssertFalse(collector.unlinkSegment(segmentId: UUID(), fromSession: UUID()))
    }

    /// A segment whose own copy cannot be read: its beats cannot be located,
    /// so the link is kept and the collector reports false.
    func testUnlinkReportsFailureAndKeepsTheLinkWhenTheSegmentCannotBeRead() throws {
        var parent = night()
        let segmentId = UUID()
        parent.linkedSessionIds = [segmentId]
        try archive.archive(parent)

        XCTAssertFalse(collector.unlinkSegment(segmentId: segmentId, fromSession: parent.id))
        XCTAssertEqual(try archive.retrieve(parent.id)?.linkedSessionIds, [segmentId])
    }
}
