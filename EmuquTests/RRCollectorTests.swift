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
    /// Over a temporary archive, raw-backup folder and baseline file, never the
    /// host app's own. `lazy` so it is built after `setUp` has set the host's
    /// recording state aside.
    lazy var collector = makeCollector()

    nonisolated private let storageDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("RRCollectorTests-\(UUID().uuidString)", isDirectory: true)

    /// The host's recording state, put back in `tearDown`.
    private var hostRecordingState: HostDefaults?

    private func makeCollector() -> RRCollector {
        RRCollector(
            polarManager: PolarManager(), healthKit: HealthKitManager(),
            archive: SessionArchive(directory: storageDirectory.appendingPathComponent("Archive", isDirectory: true)),
            rawBackup: RawRRBackup(directory: storageDirectory.appendingPathComponent(AppConfig.backupDirectoryName, isDirectory: true)),
            baselineTracker: BaselineTracker(baselineFile: storageDirectory.appendingPathComponent("HRVBaseline.json"))
        )
    }

    override func setUp() async throws {
        try await super.setUp()
        hostRecordingState = HostDefaults.setAside(HostDefaults.recordingState)
        pinEnglishLanguage()
    }

    override func tearDown() async throws {
        hostRecordingState?.restore()
        do {
            try FileManager.default.removeItem(at: storageDirectory)
        } catch {
            // swallow-ok: a test that built no collector wrote nothing here.
        }
        try await super.tearDown()
    }

    // MARK: - Persisted State Tests

    /// What recording start writes (`persistRecordingState`, the one atomic
    /// record) reads back whole, and nothing goes under the legacy keys.
    func testPersistedRecordingStateSaved() throws {
        let sessionId = UUID()
        let startTime = Date(timeIntervalSince1970: 1_790_000_000)

        collector.recordingStore.persist(sessionId: sessionId, startTime: startTime, sessionType: .overnight)

        let retrieved = try XCTUnwrap(collector.recordingStore.load(), "Should retrieve persisted state")
        XCTAssertEqual(retrieved.sessionId, sessionId)
        XCTAssertEqual(retrieved.sessionType, .overnight)
        XCTAssertEqual(retrieved.startTime.timeIntervalSince1970, startTime.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNotNil(UserDefaults.standard.object(forKey: UserDefaultsKeys.persistedRecordingState))
        XCTAssertNil(UserDefaults.standard.object(forKey: UserDefaultsKeys.activeRecordingSessionId),
                     "the current save wrote the legacy keys")
    }

    /// Test persisted state detection and clearing
    func testPersistedStateCleared() {
        collector.recordingStore.persist(sessionId: UUID(), startTime: Date(), sessionType: .overnight)
        XCTAssertTrue(collector.recordingStore.hasRecording)

        collector.recordingStore.clear()

        XCTAssertFalse(collector.recordingStore.hasRecording)
    }

    /// A build from before the atomic record left three separate keys. A
    /// fresh collector (an app restart) still finds the recording, and the
    /// load moves it into the atomic record and removes the legacy keys.
    func testRecoveryFromPersistedState() throws {
        let sessionId = UUID()
        let startTime = Date().addingTimeInterval(-3600) // 1 hour ago
        let sessionType = SessionType.overnight

        // Simulate persisted state from previous session
        UserDefaults.standard.set(startTime, forKey: "RRCollector.activeRecordingStartTime")
        UserDefaults.standard.set(sessionId.uuidString, forKey: "RRCollector.activeRecordingSessionId")
        UserDefaults.standard.set(sessionType.rawValue, forKey: "RRCollector.activeRecordingSessionType")

        // Create a fresh collector (simulating app restart)
        let freshCollector = makeCollector()

        // Should detect persisted state
        XCTAssertTrue(freshCollector.recordingStore.hasRecording)

        let recovered = freshCollector.recordingStore.load()
        XCTAssertNotNil(recovered)
        XCTAssertEqual(recovered?.sessionId, sessionId)
        XCTAssertEqual(recovered?.sessionType, sessionType)

        // Start time should match
        let timeDiff = try abs(XCTUnwrap(recovered?.startTime.timeIntervalSince(startTime)))
        XCTAssertLessThan(timeDiff, 1.0, "Start time should match persisted value")

        XCTAssertNotNil(UserDefaults.standard.object(forKey: UserDefaultsKeys.persistedRecordingState),
                        "the legacy state was not moved into the atomic record")
        XCTAssertNil(UserDefaults.standard.object(forKey: "RRCollector.activeRecordingSessionId"),
                     "the legacy keys stayed after the migration")
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

    /// Saved-session reanalysis over this test's archive and the collector's
    /// scoring context and archive signal, its listeners not started.
    private func makeReanalysis() -> SessionReanalysisCoordinator {
        AppDependencies.makeSessionReanalysis(SessionReanalysisParts(
            archive: archive, healthKit: collector.healthKit, scoring: collector.scoring,
            archiveSignal: collector.archiveSignal, cloudSync: collector.cloudSyncManager,
            trainingMetricsCache: { AppDependencies.current.analysis.trainingMetricsCache },
            invalidateZones: { _ in }
        ))
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

        let stored = await collector.morning.updateCompositeRecoveryScore(for: session)

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

        let stored = await collector.morning.updateCompositeRecoveryScore(for: session)

        XCTAssertFalse(stored)
        XCTAssertEqual(try archive.retrieve(session.id)?.tags, [])
    }

    // MARK: - Rescore during review

    /// A night on the review card that this review saved to the archive,
    /// awaiting acceptance, with nothing entered on it yet.
    private func reviewCard() -> HRVSession {
        var card = night()
        card.recoveryScore = 6.1
        collector.sessionState.currentSession = card
        collector.sessionState.needsAcceptance = true
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
        collector.sessionState.currentSession = card
        var rescored = HRVSession(
            id: card.id, startDate: card.startDate, endDate: card.endDate, state: .complete,
            sessionType: .overnight, rrSeries: nil, analysisResult: nil, artifactFlags: nil
        )
        rescored.recoveryScore = 7.4
        rescored.morningFeeling = 2

        makeReanalysis().finishRescore(sessionId: card.id, prior: nil, updated: rescored, reason: "sleep")

        XCTAssertEqual(collector.sessionState.currentSession?.recoveryScore, 7.4)
        XCTAssertEqual(collector.sessionState.currentSession?.tags, [ReadingTag.alcohol], "edited on the card")
        XCTAssertEqual(collector.sessionState.currentSession?.notes, "late dinner", "edited on the card")
        XCTAssertEqual(collector.sessionState.currentSession?.morningFeeling, 2, "left alone on the card, edited in History")
    }

    /// Stop, Retry or Recover into a night already archived leaves the
    /// archive alone until Accept, so the card holds a newer night than the
    /// archive. A rescore of the archived copy must not replace it.
    func testARescoreOfTheOldArchivedCopyLeavesANewerReviewNightAlone() {
        var card = reviewCard()
        collector.sessionState.reviewArchivedSessionId = nil
        card.recoveryScore = 8.2
        collector.sessionState.currentSession = card
        var oldArchived = card
        oldArchived.recoveryScore = 5.0

        makeReanalysis().finishRescore(sessionId: card.id, prior: nil, updated: oldArchived, reason: "sleep")

        XCTAssertEqual(collector.sessionState.currentSession?.recoveryScore, 8.2)
    }

    /// No session awaits acceptance: a rescore leaves the current session.
    func testARescoreWithNothingAwaitingAcceptanceLeavesTheCurrentSession() {
        let card = reviewCard()
        collector.sessionState.needsAcceptance = false
        var rescored = card
        rescored.recoveryScore = 7.4

        makeReanalysis().finishRescore(sessionId: card.id, prior: nil, updated: rescored, reason: "sleep")

        XCTAssertEqual(collector.sessionState.currentSession?.recoveryScore, 6.1)
    }

    func testAnotherSessionsArchivedCopyLeavesTheReviewCardAlone() {
        let card = reviewCard()
        var other = night()
        other.recoveryScore = 7.4

        collector.adoptArchivedCopy(other)

        XCTAssertEqual(collector.sessionState.currentSession?.id, card.id)
        XCTAssertEqual(collector.sessionState.currentSession?.recoveryScore, 6.1)
    }

    // MARK: - Segment unlink

    /// No archived parent: nothing is unlinked and the reanalysis service
    /// says so, so the report keeps the segment listed.
    func testUnlinkReportsFailureWhenTheParentIsNotArchived() {
        XCTAssertFalse(makeReanalysis().service.unlinkSegment(segmentId: UUID(), fromSession: UUID()))
    }

    /// A segment whose own copy cannot be read: its beats cannot be located,
    /// so the link is kept and the reanalysis service reports false.
    func testUnlinkReportsFailureAndKeepsTheLinkWhenTheSegmentCannotBeRead() throws {
        var parent = night()
        let segmentId = UUID()
        parent.linkedSessionIds = [segmentId]
        try archive.archive(parent)

        XCTAssertFalse(makeReanalysis().service.unlinkSegment(segmentId: segmentId, fromSession: parent.id))
        XCTAssertEqual(try archive.retrieve(parent.id)?.linkedSessionIds, [segmentId])
    }
}
