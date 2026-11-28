import CloudKit
import Foundation
import os

/// Restoring a session from the Trash when iCloud already holds its tombstone:
/// whose word wins, a deletion or a later restore. The push, pull and deletion
/// paths all ask it.
///
/// Like `CloudPullCoordinator` and `CloudDeletionCoordinator`: a distinct
/// job, reached through one explicit `manager` reference, with its own
/// persisted record of pending restores.
@MainActor
struct TrashRestoreCoordinator {
    let manager: CloudKitSyncManager

    /// `isDeleted` value for a session restored from the Trash after being
    /// deleted. Every build reads a tombstone as `isDeleted == 1`, so an older
    /// build sees this as an ordinary live record; a current one also knows a
    /// restore happened, and when (`restoredAtField`).
    nonisolated static let restoredMarker: Int64 = -1

    /// The plain date field holding when the restore was made on the device
    /// that made it. Written once, by the upload that replaces the tombstone,
    /// and carried over by every later upload, so re-uploading the session
    /// (a tag edit) does not make the restore look newer than a deletion made
    /// since on another device. A date is not health information.
    nonisolated static let restoredAtField = "restoredAt"

    private static let restoredFromTrashKey = "cloudkit.restoredFromTrash"
    private static let restoredFromTrashAtKey = "cloudkit.restoredFromTrashAt"

    /// Sessions restored from the Trash on this device whose upload has not yet
    /// replaced the iCloud tombstone. Their next upload overrides the deletion
    /// instead of yielding to it. Persisted, so a restore made offline survives
    /// a relaunch before it syncs.
    ///
    /// Called before the deletion mark is dropped. The restore undoes the
    /// deletion this device holds, so it is dated after that deletion's time
    /// (`restoreTime(_:after:)`), which for a deletion iCloud confirmed is
    /// iCloud's own: a device clock running behind would otherwise date the
    /// restore before the tombstone, and other devices would delete it again.
    func noteRestored(_ sessionId: UUID, at restoredAt: Date = Date()) {
        var ids = Set(UserDefaults.standard.stringArray(forKey: Self.restoredFromTrashKey) ?? [])
        ids.insert(sessionId.uuidString)
        UserDefaults.standard.set(Array(ids), forKey: Self.restoredFromTrashKey)
        let deletedAt = manager.archive.store.deletionTime(of: sessionId)
        storeRestoreTime(Self.restoreTime(restoredAt, after: deletedAt), of: sessionId)
        manager.state.markRemoved(sessionId)
        manager.state.saveSyncState()
        manager.state.savePendingQueue()
    }

    /// A restore that undoes a deletion made at `deletedAt` is later than it.
    nonisolated static func restoreTime(_ restoredAt: Date, after deletedAt: Date?) -> Date {
        guard let deletedAt else { return restoredAt }
        return max(restoredAt, deletedAt.addingTimeInterval(1))
    }

    /// A restore still waiting to upload, made while a tombstone iCloud
    /// timed at `deletionAt` was being written: dated after that tombstone.
    func keepRestore(_ sessionId: UUID, after deletionAt: Date) {
        guard isRestored(sessionId) else { return }
        let current = restoreTime(of: sessionId) ?? Date()
        storeRestoreTime(Self.restoreTime(current, after: deletionAt), of: sessionId)
    }

    private func storeRestoreTime(_ restoredAt: Date, of sessionId: UUID) {
        var times = UserDefaults.standard.dictionary(forKey: Self.restoredFromTrashAtKey) ?? [:]
        times[sessionId.uuidString] = restoredAt.timeIntervalSince1970
        UserDefaults.standard.set(times, forKey: Self.restoredFromTrashAtKey)
    }

    func isRestored(_ sessionId: UUID) -> Bool {
        (UserDefaults.standard.stringArray(forKey: Self.restoredFromTrashKey) ?? []).contains(sessionId.uuidString)
    }

    /// When the pending restore of `sessionId` was made here; nil for one
    /// noted before restore times were kept.
    func restoreTime(of sessionId: UUID) -> Date? {
        let seconds = UserDefaults.standard.dictionary(forKey: Self.restoredFromTrashAtKey)?[sessionId.uuidString] as? Double
        return seconds.map(Date.init(timeIntervalSince1970:))
    }

    /// Once an upload has landed, the restore is in iCloud; a later deletion
    /// from another device must win again.
    func clear(_ sessionId: UUID) {
        if var times = UserDefaults.standard.dictionary(forKey: Self.restoredFromTrashAtKey),
           times.removeValue(forKey: sessionId.uuidString) != nil {
            UserDefaults.standard.set(times, forKey: Self.restoredFromTrashAtKey)
        }
        guard var ids = UserDefaults.standard.stringArray(forKey: Self.restoredFromTrashKey),
              let index = ids.firstIndex(of: sessionId.uuidString) else { return }
        ids.remove(at: index)
        UserDefaults.standard.set(ids, forKey: Self.restoredFromTrashKey)
    }

    /// The restore found nothing to bring back: nothing is queued for it.
    func abandon(_ sessionId: UUID) {
        clear(sessionId)
        manager.state.markDeleted(sessionId)
        manager.state.saveSyncState()
        manager.state.savePendingQueue()
    }

    /// A restore overwriting a tombstone leaves the marker behind, with the
    /// time the restore was made here (`restoredAtField`), so other devices
    /// that still hold the deletion can tell a restore from a deletion that
    /// never reached iCloud, and which came last. A restore noted with no
    /// time is dated at this upload, which can only make it read later.
    func markIfReplacingTombstone(_ serverRecord: CKRecord, sessionId: UUID) {
        guard isRestored(sessionId) else { return }
        serverRecord["isDeleted"] = Self.restoredMarker as CKRecordValue
        Self.stampRestore(on: serverRecord, at: restoreTime(of: sessionId) ?? Date())
    }

    /// When iCloud's record says the restore was made; nil for a record
    /// without the field.
    nonisolated static func restoredAt(of record: CKRecord) -> Date? {
        record[restoredAtField] as? Date
    }

    /// Whether iCloud's record is a restore made after this device's deletion.
    /// A deletion with no recorded time predates restore markers altogether,
    /// so the restore wins. The restore's own time decides, never the
    /// record's modification date, which every re-upload moves. A record
    /// marked by a build that kept no restore time falls back to its
    /// modification date, the latest the restore can have been made, until
    /// an upload from this build fixes that bound on it (`carryRestore`).
    nonisolated static func restoreIsNewer(_ record: CKRecord, thanDeletionAt deletedAt: Date?) -> Bool {
        restoreIsNewer(
            isRestore: (record["isDeleted"] as? Int64) == restoredMarker, restoredAt: restoredAt(of: record),
            recordModifiedAt: record.modificationDate, thanDeletionAt: deletedAt
        )
    }

    /// `restoreIsNewer(_:thanDeletionAt:)` from the record's parts.
    nonisolated static func restoreIsNewer(
        isRestore: Bool, restoredAt: Date?, recordModifiedAt: Date?, thanDeletionAt deletedAt: Date?
    ) -> Bool {
        guard isRestore else { return false }
        guard let deletedAt else { return true }
        guard let restoredAt = restoredAt ?? recordModifiedAt else { return false }
        return restoredAt > deletedAt
    }

    /// Keeps a restore on `server` through an upload that overwrites its
    /// fields with this device's (every upload writes `isDeleted = 0` and no
    /// restore time): the marker stays, and so does the restore's time. A
    /// record marked with no time is given its modification date before this
    /// upload, so the re-upload does not move it.
    nonisolated static func carryRestore(onto server: CKRecord, serverDeleted: Int64?, restoredAt: Date?, modifiedAt: Date?) {
        guard serverDeleted == restoredMarker else { return }
        server["isDeleted"] = restoredMarker as CKRecordValue
        if let time = restoredAt ?? modifiedAt { stampRestore(on: server, at: time) }
    }

    /// Set once per launch when the production schema rejects the field (it is
    /// added in Development and must be deployed). Restores then go up with
    /// the marker alone, compared by the record's modification date.
    nonisolated private static let restoredAtRejected = OSAllocatedUnfairLock(initialState: false)

    nonisolated private static func stampRestore(on record: CKRecord, at date: Date) {
        guard !restoredAtRejected.withLock({ $0 }) else { return }
        record[restoredAtField] = date as CKRecordValue
    }

    /// Notice a save the schema refused because of `restoredAtField`, so the
    /// next attempt leaves it out.
    nonisolated static func noteRejection(ofFieldIn message: String, isSchemaRejection: Bool) {
        guard message.contains(restoredAtField), message.contains("production schema") || isSchemaRejection else { return }
        restoredAtRejected.withLock { $0 = true }
        debugLog("[CloudKit] Session record field \(restoredAtField) is not in the production schema; restores upload without it until it is deployed", level: .error)
    }
}
