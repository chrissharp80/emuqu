@testable import Emuqu
import XCTest

/// Tests for RRCollector - Session orchestration and lifecycle.
///
/// These tests verify:
/// - Initial state and idle behavior
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
    }

    override func tearDown() async throws {
        // Clean up any sessions created during tests
        if let session = collector.currentSession {
            try? collector.archive.delete(session.id)
        }
        clearPersistedState()
        try await super.tearDown()
    }

    // MARK: - Initial State Tests

    /// Test collector starts in correct initial state
    func testInitialState() {
        XCTAssertFalse(collector.isOvernightStreaming, "Should not be streaming initially")
        XCTAssertFalse(collector.isCollecting, "Should not be collecting initially")
        XCTAssertFalse(collector.isStreamingMode, "Should not be in streaming mode initially")
        XCTAssertNil(collector.currentSession, "Should have no session initially")
        XCTAssertEqual(collector.streamingElapsedSeconds, 0, "Elapsed time should be 0")
        XCTAssertEqual(collector.collectedPoints.count, 0, "Should have no points initially")
    }

    /// Test starting overnight streaming requires connected device
    func testStartOvernightStreamingRequiresConnection() {
        do {
            try collector.startOvernightStreaming()
            XCTFail("Should throw when not connected")
        } catch {
            XCTAssertTrue(error is RRCollector.CollectorError)
        }

        // State should not have changed
        XCTAssertFalse(collector.isOvernightStreaming)
        XCTAssertNil(collector.currentSession)
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
            .dataAlreadyExists
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
