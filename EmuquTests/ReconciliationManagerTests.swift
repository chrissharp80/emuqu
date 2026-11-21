@testable import Emuqu
import XCTest

final class ReconciliationManagerTests: XCTestCase {
    /// A folder in the temporary directory standing in for Documents.
    private func makeDocumentsFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReconciliationDocuments-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock {
            do {
                try FileManager.default.removeItem(at: folder)
            } catch {
                // swallow-ok: the folder is temporary; tearDown removes what it can.
            }
        }
        return folder
    }

    // MARK: - Session Exists

    func testSessionExists_notArchived() {
        let manager = ReconciliationManager(archive: SessionArchive.shared)
        XCTAssertFalse(manager.sessionExists(UUID()))
    }

    // MARK: - Retired offline queue

    /// The offline queue an older build left (`HRVOffline/pending.json`,
    /// whole sessions in plain JSON) is removed, folder and all; the rest of
    /// Documents is left alone.
    func testTheRetiredOfflineQueueIsRemoved() throws {
        let documents = try makeDocumentsFolder()
        let queue = documents.appendingPathComponent("HRVOffline", isDirectory: true)
        try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true)
        try Data("[{\"id\":\"x\"}]".utf8).write(to: queue.appendingPathComponent("pending.json"))
        let neighbour = documents.appendingPathComponent("keep.json")
        try Data("{}".utf8).write(to: neighbour)

        ReconciliationManager.removeRetiredOfflineQueue(in: documents)

        XCTAssertFalse(FileManager.default.fileExists(atPath: queue.path), "The retired queue must not stay on disk")
        XCTAssertTrue(FileManager.default.fileExists(atPath: neighbour.path), "Only the retired queue is removed")
    }

    /// With no retired queue there is nothing to remove, and nothing fails.
    func testNoRetiredOfflineQueueIsANoOp() throws {
        let documents = try makeDocumentsFolder()
        ReconciliationManager.removeRetiredOfflineQueue(in: documents)
        XCTAssertTrue(FileManager.default.fileExists(atPath: documents.path))
    }
}
