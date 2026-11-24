import CloudKit
@testable import Emuqu
import XCTest

/// What the pull does with each record it lists
/// (`CloudPullCoordinator.processRemoteRecord`), on a sync manager of the
/// test's own over a temporary archive (`CloudKitSyncManager.isolated`).
///
/// The tombstone branch deletes the local copy without the Trash and
/// discards any Trash copy, so a mistake there loses nights for good: a
/// session restored here and not yet uploaded must survive a tombstone, a
/// local change not yet uploaded must go to the Trash instead, and a copy
/// that cannot be removed must stay with the deletion retried next pull.
/// The live branch imports a session this device does not hold, and leaves
/// alone one marked kept on another device.
///
/// No record here comes from or goes to iCloud: each is built in memory.
@MainActor
final class CloudPullRecordTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("CloudPullRecordTests-\(UUID().uuidString)", isDirectory: true)
    private lazy var archiveDirectory = directory.appendingPathComponent("Archive", isDirectory: true)
    private lazy var archive = SessionArchive(directory: archiveDirectory)
    private lazy var manager = CloudKitSyncManager.isolated(archive: archive, directory: directory)
    private let zone = CKRecordZone.ID(zoneName: "CloudPullRecordTests", ownerName: CKCurrentUserDefaultName)

    /// The restore list (`TrashRestoreCoordinator`) and the sync bookkeeping
    /// live in the host's standard defaults; the host's values go back.
    private var hostDefaults: HostDefaults?

    override func setUp() async throws {
        try await super.setUp()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        hostDefaults = HostDefaults.setAside(HostDefaults.cloudSyncBookkeeping + ["cloudkit.restoredFromTrash"])
    }

    override func tearDown() async throws {
        hostDefaults?.restore()
        try FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private func night(startingAt seconds: TimeInterval = 1_790_000_000) -> HRVSession {
        HRVSession(
            id: UUID(), startDate: Date(timeIntervalSince1970: seconds), endDate: Date(timeIntervalSince1970: seconds + 28_800),
            state: .complete, sessionType: .overnight, rrSeries: nil, analysisResult: nil, artifactFlags: nil
        )
    }

    /// The listing's record of `id` carrying `isDeleted`.
    private func record(of id: UUID, isDeleted: Int64) -> CKRecord {
        let record = CKRecord(recordType: "HRVSession", recordID: CKRecord.ID(recordName: id.uuidString, zoneID: zone))
        record["isDeleted"] = isDeleted as CKRecordValue
        return record
    }

    /// The record a device that holds `session` would upload, its payload
    /// sealed as the upload seals it.
    private func liveRecord(of session: HRVSession) throws -> CKRecord {
        standInForConfirmedICloudAccount()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try CloudPayloadCodec.sealForUpload(DataCompression.compress(encoder.encode(session)))
        let file = directory.appendingPathComponent("\(session.id.uuidString).asset")
        try payload.write(to: file)
        let record = record(of: session.id, isDeleted: 0)
        record["sessionData"] = CKAsset(fileURL: file)
        return record
    }

    // MARK: - Tombstones

    /// A session deleted on another device is removed here without the
    /// Trash, counted as deleted, and dropped from the sync bookkeeping.
    func testATombstoneRemovesTheLocalCopyWithoutTheTrash() async throws {
        let session = night()
        try archive.archive(session)
        manager.state.markUploaded(session.id)

        let outcome = await manager.pull.processRemoteRecord(record(of: session.id, isDeleted: 1), forgotten: [])

        XCTAssertEqual(outcome.deleted, 1)
        XCTAssertFalse(archive.store.exists(session.id))
        XCTAssertTrue(archive.store.wasIntentionallyDeleted(session.id))
        XCTAssertNil(archive.store.trashedSession(session.id), "a deletion from another device was kept in this device's Trash")
        XCTAssertFalse(manager.state.uploadedSessionIds.contains(session.id))
        XCTAssertFalse(manager.state.pendingUploadIds.contains(session.id))
        XCTAssertNil(manager.lastPullErrorMessage)
    }

    /// A tombstone for a session this device does not hold changes nothing
    /// here and counts no deletion.
    func testATombstoneForASessionNotHeldDeletesNothing() async {
        let kept = night()
        XCTAssertNoThrow(try archive.archive(kept))

        let outcome = await manager.pull.processRemoteRecord(record(of: UUID(), isDeleted: 1), forgotten: [])

        XCTAssertEqual(outcome.deleted, 0)
        XCTAssertTrue(archive.store.exists(kept.id))
    }

    /// A session restored from the Trash here and not yet uploaded outranks
    /// the tombstone its earlier deletion left in iCloud: the pull must not
    /// delete it again.
    func testASessionRestoredHereIsNotDeletedByItsOldTombstone() async throws {
        let session = night()
        try archive.archive(session)
        manager.trashRestore.noteRestored(session.id)
        XCTAssertTrue(manager.trashRestore.isRestored(session.id), "Sanity: the restore is recorded")

        let outcome = await manager.pull.processRemoteRecord(record(of: session.id, isDeleted: 1), forgotten: [])

        XCTAssertEqual(outcome.deleted, 0)
        XCTAssertTrue(archive.store.exists(session.id), "the pull deleted a session this device had just restored")
        XCTAssertFalse(archive.store.wasIntentionallyDeleted(session.id))
    }

    /// A copy with a change of this device's still queued goes to this
    /// device's Trash, so the change can still be got back.
    func testATombstoneSendsACopyWithAnUnsyncedChangeToTheTrash() async throws {
        let session = night()
        try archive.archive(session)
        manager.state.markRemoved(session.id)
        XCTAssertTrue(manager.state.pendingUploadIds.contains(session.id), "Sanity: the change is queued")

        let outcome = await manager.pull.processRemoteRecord(record(of: session.id, isDeleted: 1), forgotten: [])

        XCTAssertEqual(outcome.deleted, 1)
        XCTAssertFalse(archive.store.exists(session.id))
        XCTAssertEqual(archive.store.trashedSession(session.id)?.id, session.id, "the unsynced change was not kept in the Trash")
        XCTAssertFalse(manager.state.pendingUploadIds.contains(session.id))
    }

    /// A local copy that cannot be removed (the archive folder is read-only,
    /// so not even the index can be saved) stays, with its bookkeeping: the
    /// deletion is not counted, the pull reports an error, and the next pull
    /// lists the tombstone again.
    func testATombstoneThatCannotBeAppliedKeepsTheSessionAndReportsIt() async throws {
        let session = night()
        try archive.archive(session)
        manager.state.markUploaded(session.id)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: archiveDirectory.path)
        defer {
            XCTAssertNoThrow(try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: archiveDirectory.path))
        }

        let outcome = await manager.pull.processRemoteRecord(record(of: session.id, isDeleted: 1), forgotten: [])

        XCTAssertEqual(outcome.deleted, 0)
        XCTAssertTrue(archive.store.exists(session.id), "a session whose deletion failed left the archive")
        XCTAssertFalse(archive.store.wasIntentionallyDeleted(session.id))
        XCTAssertTrue(manager.state.uploadedSessionIds.contains(session.id), "the failed deletion dropped the bookkeeping")
        XCTAssertNotNil(manager.lastPullErrorMessage, "the failed deletion was not reported")
    }

    // MARK: - Live records

    /// A session marked kept on another device carries no payload: a copy
    /// held here stays as it is and counts as uploaded.
    func testARecordKeptOnAnotherDeviceLeavesTheLocalCopy() async throws {
        let session = night()
        try archive.archive(session)

        let outcome = await manager.pull.processRemoteRecord(
            record(of: session.id, isDeleted: CloudKitSyncManager.keptOnDeviceMarker), forgotten: []
        )

        XCTAssertEqual(outcome.new, 0)
        XCTAssertEqual(outcome.deleted, 0)
        XCTAssertTrue(archive.store.exists(session.id))
        XCTAssertTrue(manager.state.uploadedSessionIds.contains(session.id))
    }

    /// A live record of a session this device does not hold is imported and
    /// marked uploaded; the same record of a session deleted forever here is
    /// not. The first half is what shows the second refuses the import for
    /// the right reason, not because the record could not be read.
    func testALiveRecordIsImportedUnlessTheSessionWasDeletedForever() async throws {
        let imported = night()
        let forgotten = night(startingAt: 1_790_200_000)

        let importRecord = try liveRecord(of: imported)
        let forgottenRecord = try liveRecord(of: forgotten)

        let importOutcome = await manager.pull.processRemoteRecord(importRecord, forgotten: [])
        let forgottenOutcome = await manager.pull.processRemoteRecord(forgottenRecord, forgotten: [forgotten.id])

        XCTAssertEqual(importOutcome.new, 1)
        XCTAssertEqual(importOutcome.backfillId, imported.id)
        XCTAssertTrue(archive.store.exists(imported.id))
        XCTAssertTrue(manager.state.uploadedSessionIds.contains(imported.id))
        XCTAssertEqual(forgottenOutcome.new, 0)
        XCTAssertNil(forgottenOutcome.backfillId)
        XCTAssertFalse(archive.store.exists(forgotten.id))
        XCTAssertFalse(manager.state.uploadedSessionIds.contains(forgotten.id))
    }
}
