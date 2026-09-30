@testable import Emuqu
import XCTest

/// Tests for CloudKitSyncState — the extracted persistence layer for sync tracking.
final class CloudKitSyncStateTests: XCTestCase {
    // A unique directory per test, created when first read. The UUID is what
    // keeps two tests from sharing a path.
    private lazy var tempDir: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudKitSyncStateTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeSyncState() -> CloudKitSyncState {
        let url = tempDir.appendingPathComponent("sync_state.json")
        return CloudKitSyncState(syncStateURL: url)
    }

    // MARK: - Upload State Round-Trip

    func testSaveAndLoadSyncState() {
        var state = makeSyncState()
        let id1 = UUID()
        let id2 = UUID()

        state.uploadedSessionIds = [id1, id2]
        state.saveSyncState()

        var loaded = makeSyncState()
        loaded.loadAll()

        XCTAssertEqual(loaded.uploadedSessionIds.count, 2)
        XCTAssertTrue(loaded.uploadedSessionIds.contains(id1))
        XCTAssertTrue(loaded.uploadedSessionIds.contains(id2))
    }

    // MARK: - Pending Queue Round-Trip

    func testSaveAndLoadPendingQueue() {
        var state = makeSyncState()
        let id = UUID()

        state.pendingUploadIds = [id]
        state.savePendingQueue()

        var loaded = makeSyncState()
        loaded.loadAll()

        XCTAssertEqual(loaded.pendingUploadIds.count, 1)
        XCTAssertTrue(loaded.pendingUploadIds.contains(id))
    }

    // MARK: - Mutation Helpers

    func testMarkUploadedMovesFromPendingToUploaded() {
        var state = makeSyncState()
        let id = UUID()

        state.pendingUploadIds = [id]
        state.uploadFailureCounts[id] = 3

        state.markUploaded(id)

        XCTAssertTrue(state.uploadedSessionIds.contains(id))
        XCTAssertFalse(state.pendingUploadIds.contains(id))
        XCTAssertNil(state.uploadFailureCounts[id])
    }

    func testMarkFailedAddsToPendingAndIncrementsCount() {
        var state = makeSyncState()
        let id = UUID()

        state.markFailed(id)
        XCTAssertTrue(state.pendingUploadIds.contains(id))
        XCTAssertEqual(state.uploadFailureCounts[id], 1)

        state.markFailed(id)
        XCTAssertEqual(state.uploadFailureCounts[id], 2)
    }

    func testMarkRemovedClearsFromUploaded() {
        var state = makeSyncState()
        let id = UUID()

        state.uploadedSessionIds = [id]
        state.markRemoved(id)

        XCTAssertFalse(state.uploadedSessionIds.contains(id))
        // Pending too, so a pull that finds the older copy in iCloud does not
        // mark the local change uploaded before it has gone up.
        XCTAssertTrue(state.pendingUploadIds.contains(id))
    }

    /// A deleted session has nothing left to push. Left pending, it is
    /// retried, fails to retrieve, and is retried again every cycle.
    func testMarkDeletedLeavesNothingToPush() {
        var state = makeSyncState()
        let id = UUID()

        state.uploadedSessionIds = [id]
        state.markFailed(id)
        state.markDeleted(id)

        XCTAssertFalse(state.uploadedSessionIds.contains(id))
        XCTAssertFalse(state.pendingUploadIds.contains(id))
        XCTAssertNil(state.uploadFailureCounts[id])
    }

    // MARK: - Empty State

    func testLoadAllWithNoFilesStartsEmpty() {
        var state = makeSyncState()
        state.loadAll()

        XCTAssertTrue(state.uploadedSessionIds.isEmpty)
        XCTAssertTrue(state.pendingUploadIds.isEmpty)
        XCTAssertTrue(state.uploadFailureCounts.isEmpty)
    }

    // MARK: - Corrupted Data

    func testLoadSyncStateHandlesCorruptedFile() {
        var state = makeSyncState()

        // Write garbage to the sync state file
        let url = tempDir.appendingPathComponent("sync_state.json")
        try? Data("not json".utf8).write(to: url)

        state.loadAll()
        XCTAssertTrue(state.uploadedSessionIds.isEmpty, "Should start empty when file is corrupted")
    }
}
