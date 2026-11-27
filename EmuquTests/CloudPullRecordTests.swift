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
        hostDefaults = HostDefaults.setAside(
            HostDefaults.cloudSyncBookkeeping + ["cloudkit.restoredFromTrash", "cloudkit.restoredFromTrashAt"]
        )
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

    // MARK: - A restore made on another device

    /// `session` archived and then deleted here, by a build that recorded
    /// no deletion time, so any restore made on another device is newer
    /// (`TrashRestoreCoordinator.restoreIsNewer`): the pull's own restore
    /// decision is what each test below drives.
    private func deletedHereBeforeARestore(_ session: HRVSession) throws {
        try archive.archive(session)
        XCTAssertTrue(try archive.delete(session.id))
        archive.store.reinstateDeletion(session.id, deletedAt: nil)
        XCTAssertNil(archive.store.deletionTime(of: session.id))
        XCTAssertTrue(archive.store.trashedIds.contains(session.id))
    }

    /// The record another device writes when it restores `session` from its Trash.
    private func restoredRecord(of session: HRVSession) throws -> CKRecord {
        let record = try liveRecord(of: session)
        record["isDeleted"] = TrashRestoreCoordinator.restoredMarker as CKRecordValue
        return record
    }

    /// A deletion made here at `deletedAt` meets a restore made on another
    /// device: the restore's own time decides, whatever the record's
    /// modification date.
    func testARestoreIsAdoptedOnlyWhenItWasMadeAfterTheDeletionHere() async throws {
        let deletedAt = Date().addingTimeInterval(-3600)
        let before = night()
        try archive.archive(before)
        XCTAssertTrue(try archive.delete(before.id))
        archive.store.reinstateDeletion(before.id, deletedAt: deletedAt)
        let earlierRestore = try restoredRecord(of: before)
        earlierRestore[TrashRestoreCoordinator.restoredAtField] = deletedAt.addingTimeInterval(-600) as CKRecordValue

        let kept = await manager.pull.processRemoteRecord(earlierRestore, forgotten: [])

        XCTAssertEqual(kept.new, 0, "a restore made before this deletion undid it")
        XCTAssertTrue(archive.store.wasIntentionallyDeleted(before.id))

        let after = night(startingAt: 1_790_100_000)
        try archive.archive(after)
        XCTAssertTrue(try archive.delete(after.id))
        archive.store.reinstateDeletion(after.id, deletedAt: deletedAt)
        let laterRestore = try restoredRecord(of: after)
        laterRestore[TrashRestoreCoordinator.restoredAtField] = deletedAt.addingTimeInterval(600) as CKRecordValue

        let adopted = await manager.pull.processRemoteRecord(laterRestore, forgotten: [])

        XCTAssertEqual(adopted.new, 1, "a restore made after this deletion was not adopted")
        XCTAssertTrue(archive.store.exists(after.id))
    }

    /// Device A deletes at 10:00 and restores at 10:05; this device applies
    /// A's tombstone at 10:10. The deletion keeps A's time, so A's restore
    /// reads as the newer change and is adopted here, not deleted again.
    func testADeletionFromAnotherDeviceKeepsItsOwnTimeSoALaterRestoreWins() async throws {
        let deletedThere = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 600).rounded(.down))
        let session = night()
        try archive.archive(session)

        _ = manager.pull.handleDeletedRecord(sessionId: session.id, sessionIdString: session.id.uuidString, deletedAt: deletedThere)

        XCTAssertEqual(try XCTUnwrap(archive.store.deletionTime(of: session.id)).timeIntervalSince1970, deletedThere.timeIntervalSince1970, accuracy: 0.001)
        let restore = try restoredRecord(of: session)
        restore[TrashRestoreCoordinator.restoredAtField] = deletedThere.addingTimeInterval(300) as CKRecordValue
        let adopted = await manager.pull.processRemoteRecord(restore, forgotten: [])
        XCTAssertEqual(adopted.new, 1, "a restore made after the original deletion lost to the time it was applied here")
        XCTAssertTrue(archive.store.exists(session.id))
    }

    /// The upload that replaces the tombstone carries the time the restore was
    /// made here, not the time of the upload.
    func testTheRestoreUploadCarriesTheTimeOfTheRestore() {
        let id = UUID()
        let restoredAt = Date(timeIntervalSince1970: 1_790_000_000)
        manager.trashRestore.noteRestored(id, at: restoredAt)
        let tombstone = record(of: id, isDeleted: 1)

        manager.trashRestore.markIfReplacingTombstone(tombstone, sessionId: id)

        XCTAssertEqual(tombstone["isDeleted"] as? Int64, TrashRestoreCoordinator.restoredMarker)
        XCTAssertEqual(TrashRestoreCoordinator.restoredAt(of: tombstone), restoredAt)
        manager.trashRestore.clear(id)
        XCTAssertNil(manager.trashRestore.restoreTime(of: id))
    }

    /// The restore is imported, the deletion dropped and the Trash copy removed.
    func testARestoreFromAnotherDeviceBringsTheSessionBack() async throws {
        let session = night()
        try deletedHereBeforeARestore(session)

        let outcome = await manager.pull.processRemoteRecord(try restoredRecord(of: session), forgotten: [])

        XCTAssertEqual(outcome.new, 1)
        XCTAssertTrue(archive.store.exists(session.id))
        XCTAssertFalse(archive.store.wasIntentionallyDeleted(session.id))
        XCTAssertFalse(archive.store.trashedIds.contains(session.id))
    }

    /// A restore whose copy cannot be read changes nothing here: the session
    /// stays deleted and in the Trash, for the next pull to try again.
    func testARestoreThatCannotBeReadLeavesTheSessionInTheTrash() async throws {
        let session = night()
        try deletedHereBeforeARestore(session)
        let record = try restoredRecord(of: session)
        let unreadable = directory.appendingPathComponent("unreadable.asset")
        try Data("not a session".utf8).write(to: unreadable)
        record["sessionData"] = CKAsset(fileURL: unreadable)

        let outcome = await manager.pull.processRemoteRecord(record, forgotten: [])

        XCTAssertEqual(outcome.new, 0)
        XCTAssertFalse(archive.store.exists(session.id))
        XCTAssertTrue(archive.store.wasIntentionallyDeleted(session.id))
        XCTAssertTrue(archive.store.trashedIds.contains(session.id))
    }

    /// A restore the archive refuses to write puts the deletion back with
    /// the time it had: the session stays in the Trash, and the next restore
    /// still wins.
    func testARestoreTheArchiveRefusesPutsTheDeletionBack() throws {
        var session = night()
        try deletedHereBeforeARestore(session)
        session.sourceSchemaVersion = HRVSession.currentSchemaVersion + 1

        XCTAssertThrowsError(try archive.archiveRestoredFromAnotherDevice(session))

        XCTAssertFalse(archive.store.exists(session.id))
        XCTAssertTrue(archive.store.wasIntentionallyDeleted(session.id))
        XCTAssertNil(archive.store.deletionTime(of: session.id))
        XCTAssertTrue(archive.store.trashedIds.contains(session.id))
    }

    // MARK: - Refreshing a session held here

    /// The replacement is stamped with the date of the revision that was
    /// downloaded, not the one the listing showed: another device may have
    /// edited the record between the two reads.
    func testTheReplacementTakesTheDownloadedRevisionsDate() {
        let id = UUID()
        let downloadedAt = Date(timeIntervalSince1970: 1_790_100_000)
        let fetched = record(of: id, isDeleted: 0)
        fetched[CloudKitSessionFreshness.modifiedAtField] = downloadedAt as CKRecordValue
        XCTAssertEqual(manager.pull.remoteCopy(of: fetched, sessionId: id).modifiedAt, downloadedAt)
    }

    // MARK: - A deletion applied later than it was decided

    /// Each way this device can hold a change iCloud does not have yet, met
    /// by a tombstone from another device: the copy goes to this device's
    /// Trash, never removed outright. A request to upload again that sync
    /// has not taken in (an edit made while a long sync held the
    /// serializer), and a copy edited after the deletion was written, count
    /// as a queued upload does. A copy with nothing unsent is removed.
    func testATombstoneKeepsEveryUnsentLocalChangeInTheTrash() throws {
        let deletedThere = Date(timeIntervalSince1970: 1_800_000_000)
        let cases = [
            UnsentChangeCase(name: "upload queued", unsent: true, afterArchive: { self.manager.state.markRemoved($0) }),
            UnsentChangeCase(name: "re-upload requested on disk", unsent: true, afterArchive: { self.archive.state.reuploadRequests.record([$0]) }),
            UnsentChangeCase(name: "edited after the deletion", unsent: true, prepare: { $0.modifiedAt = deletedThere.addingTimeInterval(60) }),
            UnsentChangeCase(name: "edited before the deletion", unsent: false, prepare: { $0.modifiedAt = deletedThere.addingTimeInterval(-60) }),
            UnsentChangeCase(name: "never edited", unsent: false)
        ]
        for (index, testCase) in cases.enumerated() {
            var session = night(startingAt: 1_790_000_000 + Double(index) * 86_400)
            testCase.prepare(&session)
            try archive.archive(session)
            testCase.afterArchive(session.id)

            _ = manager.pull.handleDeletedRecord(sessionId: session.id, sessionIdString: session.id.uuidString, deletedAt: deletedThere)

            XCTAssertFalse(archive.store.exists(session.id), testCase.name)
            XCTAssertEqual(archive.store.trashedSession(session.id) != nil, testCase.unsent, "\(testCase.name): Trash copy")
        }
    }

    /// One way of holding (or not) a change iCloud does not have yet.
    private struct UnsentChangeCase {
        let name: String
        let unsent: Bool
        var prepare: (inout HRVSession) -> Void = { _ in }
        var afterArchive: (UUID) -> Void = { _ in }
    }

    /// A deletion queued behind a sync, or as a task, stands only while the
    /// session is still deleted here when it runs: a restore from the Trash
    /// in between withdraws it, and deleting the session again reinstates it.
    func testAQueuedDeletionStandsOnlyWhileTheSessionIsStillDeletedHere() throws {
        let session = night()
        try archive.archive(session)
        XCTAssertFalse(manager.deletion.isStillDeletedHere(session.id), "a session the archive holds")

        XCTAssertTrue(try archive.delete(session.id))
        XCTAssertTrue(manager.deletion.isStillDeletedHere(session.id), "deleted")

        try archive.store.unmarkAsDeleted(session.id)
        XCTAssertFalse(manager.deletion.isStillDeletedHere(session.id), "restored, its copy not yet written back")

        archive.store.reinstateDeletion(session.id, deletedAt: Date())
        XCTAssertTrue(manager.deletion.isStillDeletedHere(session.id), "deleted again")
    }

    /// A restore undoes the deletion this device holds, so it is dated after
    /// that deletion whatever the device clock says, and after a tombstone
    /// whose write it overtook.
    func testARestoreIsDatedAfterTheDeletionItUndoes() throws {
        let session = night()
        try archive.archive(session)
        XCTAssertTrue(try archive.delete(session.id))
        let deletedAt = try XCTUnwrap(archive.store.deletionTime(of: session.id))

        manager.trashRestore.noteRestored(session.id, at: deletedAt.addingTimeInterval(-600))
        let restoredAt = try XCTUnwrap(manager.trashRestore.restoreTime(of: session.id))
        XCTAssertEqual(restoredAt.timeIntervalSince1970, deletedAt.timeIntervalSince1970 + 1, accuracy: 0.01)

        manager.trashRestore.keepRestore(session.id, after: deletedAt.addingTimeInterval(3600))
        let kept = try XCTUnwrap(manager.trashRestore.restoreTime(of: session.id))
        XCTAssertEqual(kept.timeIntervalSince1970, deletedAt.timeIntervalSince1970 + 3601, accuracy: 0.01)
        manager.trashRestore.clear(session.id)
    }

    /// A confirmed deletion takes iCloud's time for its tombstone when that is
    /// later, never an earlier one, and a session no longer deleted is left.
    func testAConfirmedDeletionTakesICloudsLaterTime() throws {
        let session = night()
        try archive.archive(session)
        XCTAssertTrue(try archive.delete(session.id))
        let local = try XCTUnwrap(archive.store.deletionTime(of: session.id))

        archive.store.raiseDeletionTime(session.id, to: local.addingTimeInterval(-60))
        XCTAssertEqual(try XCTUnwrap(archive.store.deletionTime(of: session.id)).timeIntervalSince1970, local.timeIntervalSince1970, accuracy: 0.001)

        archive.store.raiseDeletionTime(session.id, to: local.addingTimeInterval(120))
        XCTAssertEqual(try XCTUnwrap(archive.store.deletionTime(of: session.id)).timeIntervalSince1970, local.timeIntervalSince1970 + 120, accuracy: 0.001)

        try archive.store.unmarkAsDeleted(session.id)
        archive.store.raiseDeletionTime(session.id, to: local.addingTimeInterval(600))
        XCTAssertNil(archive.store.deletionTime(of: session.id))
    }
}
