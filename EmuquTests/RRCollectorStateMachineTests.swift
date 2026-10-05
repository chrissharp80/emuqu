@testable import Emuqu
import XCTest

/// State machine and session management tests for RRCollector.
///
/// These tests verify:
/// - Initial state and idle behavior
/// - Invalid state transition prevention (throws when preconditions aren't met)
/// - Session creation and metadata
/// - Persisted state recovery after crash
/// - Background manager state management
///
/// Note: Tests that require direct mutation of private(set) properties
/// (e.g., setting currentSession, isOvernightStreaming) are integration tests
/// that should go through the actual recording API with a connected device.
@MainActor
final class RRCollectorStateMachineTests: XCTestCase {
    /// Constructed on first use rather than assigned in `setUp` as an
    /// implicitly-unwrapped optional. XCTest builds the test class once per
    /// test method, so this is still fresh for every test.
    lazy var collector = RRCollector()

    /// Hermetic store for the session-archive tests below. `collector.archive`
    /// is a default-constructed `SessionArchive`, which resolves to the shared
    /// App Group directory that every other suite in the process also writes
    /// to; these tests only need somewhere to put a session and read it back,
    /// so they get their own directory instead. The section note above the
    /// archive tests below records what sharing it cost.
    private lazy var testArchiveDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("RRCollectorStateMachineTests-\(UUID().uuidString)", isDirectory: true)

    private lazy var testArchive = SessionArchive(directory: testArchiveDirectory)

    override func tearDown() async throws {
        // Clean up any sessions created
        if let session = collector.currentSession {
            try? collector.archive.delete(session.id)
        }
        // Clear persisted state. `PersistedRecordingState.clear()`, not the
        // three legacy keys by hand — those are only half the story, and the
        // missing half leaked across tests. `load()` reads the modern atomic
        // key FIRST and only falls back to the legacy trio, and that fallback
        // auto-migrates: the first test to seed legacy keys and trigger a load
        // writes them into the modern key and wipes the legacy ones. Every
        // later test that seeds legacy keys then reads back the FIRST test's
        // session, because the modern key still holds it and wins. That is what
        // failed testPersistedStateRecovery under a shuffled order — a
        // stranger's UUID and a start time two hours off the one it had just
        // written.
        PersistedRecordingState.clear()
        try? FileManager.default.removeItem(at: testArchiveDirectory)
        try await super.tearDown()
    }

    // MARK: - Initial State Tests

    /// Test collector starts in idle state
    func testInitialState() {
        XCTAssertNil(collector.currentSession, "No session should exist initially")
        XCTAssertFalse(collector.isOvernightStreaming, "Should not be streaming initially")
        XCTAssertFalse(collector.isStreamingMode, "Should not be in streaming mode initially")
        XCTAssertFalse(collector.isCollecting, "Should not be collecting initially")
        XCTAssertFalse(collector.needsAcceptance, "Should not need acceptance initially")
    }

    // MARK: - Invalid State Transition Tests

    /// Test that acceptSession throws when no session exists
    func testAcceptSessionThrowsWithoutSession() async {
        XCTAssertNil(collector.currentSession)
        XCTAssertFalse(collector.needsAcceptance)

        do {
            try await collector.acceptSession()
            XCTFail("acceptSession should throw when no session exists")
        } catch {
            XCTAssertTrue(
                error is RRCollector.CollectorError,
                "Should throw CollectorError, got: \(error)"
            )
        }
    }

    /// Test that startSession throws when not connected
    func testStartSessionThrowsWhenNotConnected() async {
        do {
            try await collector.startSession()
            XCTFail("startSession should throw when not connected")
        } catch {
            XCTAssertTrue(
                error is RRCollector.CollectorError,
                "Should throw CollectorError, got: \(error)"
            )
        }
    }

    /// Test that startStreamingSession throws when not connected
    func testStartStreamingSessionThrowsWhenNotConnected() {
        do {
            try collector.startStreamingSession()
            XCTFail("startStreamingSession should throw when not connected")
        } catch {
            XCTAssertTrue(
                error is RRCollector.CollectorError,
                "Should throw CollectorError, got: \(error)"
            )
        }
    }

    /// Test that startOvernightStreaming throws when not connected
    func testStartOvernightStreamingThrowsWhenNotConnected() {
        do {
            try collector.startOvernightStreaming()
            XCTFail("startOvernightStreaming should throw when not connected")
        } catch {
            XCTAssertTrue(
                error is RRCollector.CollectorError,
                "Should throw CollectorError, got: \(error)"
            )
        }
    }

    /// Test state remains idle after all failed transitions
    func testStateRemainsIdleAfterFailedTransitions() async {
        // Try all transitions — all should fail
        try? await collector.startSession()
        try? collector.startStreamingSession()
        try? collector.startOvernightStreaming()
        try? await collector.acceptSession()

        // State should still be idle
        XCTAssertNil(collector.currentSession, "Session should remain nil after failed transitions")
        XCTAssertFalse(collector.isCollecting, "Should not be collecting after failed transitions")
        XCTAssertFalse(collector.isOvernightStreaming, "Should not be streaming after failed transitions")
    }

    // MARK: - Session Creation Tests

    /// Test overnight session creation has correct metadata
    func testOvernightSessionCreation() {
        let session = HRVSession(sessionType: .overnight)

        XCTAssertEqual(session.sessionType, .overnight)
        XCTAssertEqual(session.state, .collecting, "New sessions start in collecting state")
        XCTAssertNotNil(session.id)
    }

    /// Test nap session creation
    func testNapSessionCreation() {
        let session = HRVSession(sessionType: .nap)

        XCTAssertEqual(session.sessionType, .nap)
        XCTAssertEqual(session.state, .collecting)
    }

    /// Test quick session creation
    func testQuickSessionCreation() {
        let session = HRVSession(sessionType: .quick)

        XCTAssertEqual(session.sessionType, .quick)
        XCTAssertEqual(session.state, .collecting)
    }

    /// Test session ID consistency
    func testSessionIDConsistency() {
        let session = HRVSession()
        let id1 = session.id
        let id2 = session.id
        XCTAssertEqual(id1, id2, "Session ID should be stable")
    }

    /// Test session timestamp accuracy
    func testSessionTimestampAccuracy() {
        let before = Date()
        let session = HRVSession()
        let after = Date()

        XCTAssertGreaterThanOrEqual(session.startDate, before)
        XCTAssertLessThanOrEqual(session.startDate, after)
    }

    /// Test session metadata tracking
    func testSessionMetadataTracking() {
        let session = HRVSession(sessionType: .overnight)

        XCTAssertEqual(session.sessionType, .overnight)
        XCTAssertNil(session.notes)
        XCTAssertEqual(session.tags.count, 0)
    }

    // MARK: - Persisted State Recovery Tests

    /// Test persisted state recovery after app crash
    func testPersistedStateRecovery() throws {
        let sessionId = UUID()
        let startTime = Date().addingTimeInterval(-7200) // 2 hours ago
        let sessionType = SessionType.overnight

        // Simulate app crashed during recording
        UserDefaults.standard.set(startTime, forKey: "RRCollector.activeRecordingStartTime")
        UserDefaults.standard.set(sessionId.uuidString, forKey: "RRCollector.activeRecordingSessionId")
        UserDefaults.standard.set(sessionType.rawValue, forKey: "RRCollector.activeRecordingSessionType")

        // Create new collector (simulates app restart)
        let recovered = RRCollector()

        // Should detect persisted state
        XCTAssertTrue(recovered.hasPersistedRecordingState)

        let state = recovered.getPersistedRecordingState()
        XCTAssertNotNil(state)
        XCTAssertEqual(state?.sessionId, sessionId)
        XCTAssertEqual(state?.sessionType, sessionType)

        // Start time should match
        let timeDiff = try abs(XCTUnwrap(state?.startTime.timeIntervalSince(startTime)))
        XCTAssertLessThan(timeDiff, 1.0)
    }

    /// Test state persistence across crash
    func testStatePersistenceOnCrash() {
        let sessionId = UUID()
        let startTime = Date()

        // Simulate recording was in progress when app terminated
        UserDefaults.standard.set(startTime, forKey: "RRCollector.activeRecordingStartTime")
        UserDefaults.standard.set(sessionId.uuidString, forKey: "RRCollector.activeRecordingSessionId")
        UserDefaults.standard.set("overnight", forKey: "RRCollector.activeRecordingSessionType")

        // On restart, new collector should detect persisted state
        let newCollector = RRCollector()
        XCTAssertTrue(newCollector.hasPersistedRecordingState)
    }

    // MARK: - Session Archive Tests
    //
    // These write to `testArchive`, a hermetic SessionArchive over a per-test
    // temp directory, NOT `collector.archive`.
    //
    // `RRCollector()` takes the default
    // `archive: SessionArchive = SessionArchive()`, and a default-constructed
    // SessionArchive resolves to the shared App Group container, so every suite
    // in the process writes to one store. Tests that archive into it fail
    // `fileNotFound` on a session they archived two lines earlier: sessions
    // seeded elsewhere, and the same-night relink migration their dates
    // trigger, reach across and delete it. `verifyIntegrity()` makes it worse
    // by walking every entry in the archive, so one stale index entry fails a
    // test that has done nothing wrong.
    //
    // Worse, the residue PERSISTS. index.json keeps entries whose files are
    // gone, nothing rebuilds it, and the suite then fails on every subsequent
    // run with no code change to explain it, until the directory is deleted.
    // scripts/run_tests_with_coverage.sh carries the path and the symptom.
    //
    // Keep these hermetic — a default SessionArchive here re-opens the whole
    // problem.
    //
    // Emuqu.xctestplan runs both targets with `testExecutionOrdering:
    // "random"`, so any suite may run before or after these; residue left in
    // the shared archive by one suite reaches the next one in the same process.
    //
    // The same residue reaches those UI suites, which is the confusing part: a
    // single stale index entry fails testDashboardShowsRecoveryScoreSection,
    // testFreshInstallDashboardShowsTheFirstReadingPrompt and
    // testDashboardTabPassesAccessibilityAudit on ANY ordering, and moves the
    // skip count 7 -> 4. The dashboard reads the archive on launch, so a broken
    // index is a broken dashboard. scripts/run_tests_with_coverage.sh carries
    // the path and the recovery step.

    /// Test session archive round-trip
    func testSessionArchiveRoundTrip() throws {
        let mockPoints = (0 ..< 200).map { i in
            RRPoint(t_ms: Int64(i * 800), rr_ms: 800)
        }

        let series = RRSeries(points: mockPoints, sessionId: UUID(), startDate: Date())
        let flags = [ArtifactFlags](repeating: .clean, count: mockPoints.count)

        let timeDomain = TimeDomainAnalyzer.computeTimeDomain(
            series, flags: flags, windowStart: 0, windowEnd: mockPoints.count
        )

        let session = HRVSession(
            id: UUID(),
            startDate: Date(),
            endDate: Date(),
            state: .complete,
            sessionType: .overnight,
            rrSeries: series,
            analysisResult: timeDomain.map { td in
                HRVAnalysisResult(
                    windowStart: 0,
                    windowEnd: mockPoints.count,
                    timeDomain: td,
                    frequencyDomain: nil,
                    nonlinear: NonlinearMetrics(sd1: 30.0, sd2: 40.0, sd1Sd2Ratio: 0.75, sampleEntropy: nil, approxEntropy: nil, dfaAlpha1: nil, dfaAlpha2: nil, dfaAlpha1R2: nil),
                    ansMetrics: nil,
                    artifactPercentage: 0,
                    cleanBeatCount: mockPoints.count,
                    analysisDate: Date()
                )
            },
            artifactFlags: flags
        )

        // Archive
        try testArchive.archive(session)

        // Verify it exists
        XCTAssertTrue(testArchive.exists(session.id))

        // Retrieve
        let retrieved = try testArchive.retrieve(session.id)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.id, session.id)
        XCTAssertEqual(retrieved?.sessionType, .overnight)
        XCTAssertEqual(retrieved?.state, .complete)

        // Clean up
        try testArchive.delete(session.id)
    }

    /// Test session tagging through archive
    func testSessionTagging() throws {
        let mockPoints = (0 ..< 200).map { i in
            RRPoint(t_ms: Int64(i * 800), rr_ms: 800)
        }

        let series = RRSeries(points: mockPoints, sessionId: UUID(), startDate: Date())
        let flags = [ArtifactFlags](repeating: .clean, count: mockPoints.count)

        let timeDomain = TimeDomainAnalyzer.computeTimeDomain(
            series, flags: flags, windowStart: 0, windowEnd: mockPoints.count
        )

        var session = HRVSession(
            id: UUID(),
            startDate: Date(),
            endDate: Date(),
            state: .complete,
            sessionType: .overnight,
            rrSeries: series,
            analysisResult: timeDomain.map { td in
                HRVAnalysisResult(
                    windowStart: 0,
                    windowEnd: mockPoints.count,
                    timeDomain: td,
                    frequencyDomain: nil,
                    nonlinear: NonlinearMetrics(sd1: 30.0, sd2: 40.0, sd1Sd2Ratio: 0.75, sampleEntropy: nil, approxEntropy: nil, dfaAlpha1: nil, dfaAlpha2: nil, dfaAlpha1R2: nil),
                    ansMetrics: nil,
                    artifactPercentage: 0,
                    cleanBeatCount: mockPoints.count,
                    analysisDate: Date()
                )
            },
            artifactFlags: flags
        )

        session.tags = [ReadingTag.morning, ReadingTag.stressed]
        try testArchive.archive(session)

        // Update tags
        try testArchive.updateTags(
            session.id,
            tags: [ReadingTag.morning, ReadingTag.stressed, ReadingTag.recovery],
            notes: "Test notes"
        )

        let retrieved = try testArchive.retrieve(session.id)
        XCTAssertEqual(retrieved?.tags.count, 3)
        XCTAssertEqual(retrieved?.notes, "Test notes")

        // Clean up
        try testArchive.delete(session.id)
    }

    /// Test session notes management
    func testSessionNotesManagement() throws {
        let session = HRVSession(
            id: UUID(),
            startDate: Date(),
            endDate: Date(),
            state: .complete,
            sessionType: .overnight,
            rrSeries: nil,
            analysisResult: nil,
            artifactFlags: nil
        )

        try testArchive.archive(session)

        // Add notes
        try testArchive.updateTags(session.id, tags: [], notes: "Initial notes")
        var retrieved = try testArchive.retrieve(session.id)
        XCTAssertEqual(retrieved?.notes, "Initial notes")

        // Update notes
        try testArchive.updateTags(session.id, tags: [], notes: "Updated notes")
        retrieved = try testArchive.retrieve(session.id)
        XCTAssertEqual(retrieved?.notes, "Updated notes")

        // Clean up
        try testArchive.delete(session.id)
    }

    // MARK: - Background Operations Tests

    /// Test background audio manager state transitions
    func testBackgroundAudioLifecycle() {
        let audioManager = BackgroundAudioManager.shared

        // Should not be running initially
        XCTAssertFalse(audioManager.isRunning, "Background audio should not be running initially")
        XCTAssertFalse(audioManager.wasInterrupted, "Should not be interrupted initially")

        // Verify collector isn't streaming initially
        XCTAssertFalse(collector.isOvernightStreaming)

        // Stop on non-running manager should be safe (idempotent)
        audioManager.stopBackgroundAudio()
        XCTAssertFalse(audioManager.isRunning, "Stop on non-running manager should be safe")
    }

    // MARK: - CollectorError Tests

    /// Test retryFetchRecording throws when disconnected
    func testRetryFetchRecordingThrowsWhenDisconnected() async {
        do {
            _ = try await collector.retryFetchRecording()
            XCTFail("retryFetchRecording should throw when not connected")
        } catch {
            XCTAssertTrue(error is RRCollector.CollectorError, "Should throw CollectorError")
        }
    }
}
