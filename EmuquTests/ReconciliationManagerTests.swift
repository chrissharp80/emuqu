@testable import Emuqu
import XCTest

final class ReconciliationManagerTests: XCTestCase {
    // Stored properties rather than implicitly-unwrapped optionals: XCTest
    // builds the test class once per test method. `manager` is `lazy` because
    // it reads `archive`.
    private var archive = SessionArchive.shared
    private lazy var manager = ReconciliationManager(archive: archive)

    // MARK: - Helpers

    private func makeSession(id: UUID = UUID()) -> HRVSession {
        HRVSession(
            id: id,
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            state: .complete,
            rrSeries: nil,
            analysisResult: nil,
            artifactFlags: nil
        )
    }

    // MARK: - Queue for Sync

    func testQueueForSync_addsSessionToPending() throws {
        let session = makeSession()
        try manager.queueForSync(session)

        let pending = manager.pending
        XCTAssertTrue(pending.contains(where: { $0.id == session.id }))
    }

    func testQueueForSync_duplicateRejection() throws {
        let session = makeSession()
        try manager.queueForSync(session)

        XCTAssertThrowsError(try manager.queueForSync(session)) { error in
            XCTAssertTrue(error is ReconciliationManager.ReconciliationError)
        }
    }

    // MARK: - Session Exists

    func testSessionExists_inPending() throws {
        let session = makeSession()
        try manager.queueForSync(session)

        XCTAssertTrue(manager.sessionExists(session.id))
    }

    func testSessionExists_notQueued() {
        XCTAssertFalse(manager.sessionExists(UUID()))
    }

    // MARK: - Pending

    func testPending_returnsOnlyUnsyncedSessions() throws {
        let session1 = makeSession()
        let session2 = makeSession()
        try manager.queueForSync(session1)
        try manager.queueForSync(session2)

        let pending = manager.pending
        XCTAssertGreaterThanOrEqual(pending.count, 2)
        XCTAssertTrue(pending.allSatisfy(\.needsSync))
    }

    // MARK: - Mark Failed

    func testMarkFailed_incrementsSyncAttempts() throws {
        let session = makeSession()
        try manager.queueForSync(session)

        try manager.markFailed(session.id, error: "Network error")

        // Session should still be pending after 1 failure (limit is 3)
        let pending = manager.pending
        XCTAssertTrue(pending.contains(where: { $0.id == session.id }))
    }

    func testMarkFailed_nonExistentSession_doesNotCrash() throws {
        // Should not throw or crash
        try manager.markFailed(UUID(), error: "error")
    }

    // MARK: - Retry Exhaustion

    func testCleanupFailedSessions_removesExhaustedRetries() throws {
        let session = makeSession()
        try manager.queueForSync(session)

        // Fail 3 times (retry limit)
        try manager.markFailed(session.id, error: "fail 1")
        try manager.markFailed(session.id, error: "fail 2")
        try manager.markFailed(session.id, error: "fail 3")

        // Session should no longer be in pending (exhausted retries, needsSync=false)
        let pending = manager.pending
        XCTAssertFalse(pending.contains(where: { $0.id == session.id }))

        // Cleanup should remove it entirely
        try manager.cleanupFailedSessions()
    }

    // MARK: - OfflineSession Properties

    func testOfflineSession_needsSync_trueInitially() {
        let session = makeSession()
        let offline = OfflineSession(session: session)
        XCTAssertTrue(offline.needsSync)
        XCTAssertEqual(offline.syncAttempts, 0)
        XCTAssertNil(offline.syncedAt)
    }

    func testOfflineSession_needsSync_falseAfterThreeAttempts() {
        let session = makeSession()
        var offline = OfflineSession(session: session)
        offline.syncAttempts = 3
        XCTAssertFalse(offline.needsSync)
    }

    func testOfflineSession_needsSync_falseWhenSynced() {
        let session = makeSession()
        var offline = OfflineSession(session: session)
        offline.syncedAt = Date()
        XCTAssertFalse(offline.needsSync)
    }
}
