@testable import Emuqu
import XCTest

/// Which raw-RR backups are genuinely unarchived.
///
/// The `archived` flag is set on each successful archive path, so it is right
/// for anything that completed in one go and wrong for anything that reached
/// the archive another way — a CloudKit pull, a launch recovery, a merge under
/// a different session id. Those entries stay flagged forever and the Data
/// settings page shows a red "Unarchived recordings" count for a user whose
/// data is safe. A field log shows the same fifteen at every launch across five
/// days.
final class BackupReconcileTests: XCTestCase {
    private func entry(_ id: UUID, archived: Bool) -> RawRRBackup.BackupIndex {
        RawRRBackup.BackupIndex(
            id: id,
            captureDate: Date(timeIntervalSince1970: 1_800_000_000),
            fileName: nil,
            beatCount: 100,
            hash: "hash",
            archived: archived,
            lastBackupTime: nil
        )
    }

    func testABackupWhoseSessionIsArchivedIsCorrected() {
        let id = UUID()
        let corrected = RawRRBackup.indicesNeedingArchivedFlag(
            [entry(id, archived: false)], archivedSessionIds: [id]
        )
        XCTAssertEqual(corrected, [0])
    }

    /// The whole point of the count: beats that exist only in a backup. Those
    /// must survive reconciliation, or the one signal the user has that data is
    /// stranded goes quiet.
    func testABackupWithNoArchivedSessionIsLeftFlagged() {
        let corrected = RawRRBackup.indicesNeedingArchivedFlag(
            [entry(UUID(), archived: false)], archivedSessionIds: [UUID()]
        )
        XCTAssertTrue(corrected.isEmpty)
    }

    func testAlreadyArchivedEntriesAreNotTouched() {
        let id = UUID()
        let corrected = RawRRBackup.indicesNeedingArchivedFlag(
            [entry(id, archived: true)], archivedSessionIds: [id]
        )
        XCTAssertTrue(corrected.isEmpty)
    }

    func testOnlyTheMatchingEntriesAreReturnedFromAMixedIndex() {
        let archivedID = UUID()
        let strandedID = UUID()
        let index = [
            entry(strandedID, archived: false),
            entry(archivedID, archived: false),
            entry(UUID(), archived: true)
        ]
        XCTAssertEqual(
            RawRRBackup.indicesNeedingArchivedFlag(index, archivedSessionIds: [archivedID]),
            [1]
        )
    }

    func testAnEmptyArchiveCorrectsNothing() {
        XCTAssertTrue(
            RawRRBackup.indicesNeedingArchivedFlag([entry(UUID(), archived: false)], archivedSessionIds: [])
                .isEmpty
        )
    }
}
