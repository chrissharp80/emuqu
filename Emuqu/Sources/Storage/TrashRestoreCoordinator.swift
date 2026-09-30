import CloudKit
import Foundation

/// Restoring a session from the Trash when iCloud already holds its tombstone:
/// whose word wins, a deletion or a later restore. The push, pull and deletion
/// paths all ask it.
///
/// Split out of `CloudKitSyncManager` the same way as `CloudPullCoordinator`
/// and `CloudDeletionCoordinator`: a distinct job, reached through one
/// explicit `manager` reference, with its own persisted record of pending
/// restores.
@MainActor
struct TrashRestoreCoordinator {
    let manager: CloudKitSyncManager

    /// `isDeleted` value for a session restored from the Trash after being
    /// deleted. Every build reads a tombstone as `isDeleted == 1`, so an older
    /// build sees this as an ordinary live record; a current one also knows a
    /// restore happened, and when (the record's modification date).
    nonisolated static let restoredMarker: Int64 = -1

    private static let restoredFromTrashKey = "cloudkit.restoredFromTrash"

    /// Sessions restored from the Trash on this device whose upload has not yet
    /// replaced the iCloud tombstone. Their next upload overrides the deletion
    /// instead of yielding to it. Persisted, so a restore made offline survives
    /// a relaunch before it syncs.
    func noteRestored(_ sessionId: UUID) {
        var ids = Set(UserDefaults.standard.stringArray(forKey: Self.restoredFromTrashKey) ?? [])
        ids.insert(sessionId.uuidString)
        UserDefaults.standard.set(Array(ids), forKey: Self.restoredFromTrashKey)
        manager.state.markRemoved(sessionId)
        manager.state.saveSyncState()
        manager.state.savePendingQueue()
    }

    func isRestored(_ sessionId: UUID) -> Bool {
        (UserDefaults.standard.stringArray(forKey: Self.restoredFromTrashKey) ?? []).contains(sessionId.uuidString)
    }

    /// Once an upload has landed, the restore is in iCloud; a later deletion
    /// from another device must win again.
    func clear(_ sessionId: UUID) {
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

    /// A restore overwriting a tombstone leaves the marker behind, so other
    /// devices that still hold the deletion can tell a restore from a deletion
    /// that never reached iCloud.
    func markIfReplacingTombstone(_ serverRecord: CKRecord, sessionId: UUID) {
        guard isRestored(sessionId) else { return }
        serverRecord["isDeleted"] = Self.restoredMarker as CKRecordValue
    }

    /// Whether iCloud's record is a restore made after this device's deletion.
    /// A deletion with no recorded time predates restore markers altogether,
    /// so the restore wins.
    nonisolated static func restoreIsNewer(_ record: CKRecord, thanDeletionAt deletedAt: Date?) -> Bool {
        guard (record["isDeleted"] as? Int64) == restoredMarker else { return false }
        guard let deletedAt else { return true }
        guard let restoredAt = record.modificationDate else { return false }
        return restoredAt > deletedAt
    }

    /// Another device restored this session after this one deleted it: drop the
    /// local deletion so the pull that follows brings the session back.
    func adoptFromAnotherDevice(_ sessionId: UUID) {
        do {
            try manager.archive.unmarkAsDeleted(sessionId)
            debugLog("[CloudKit] \(sessionId.uuidString.prefix(8)) was restored on another device — dropping this device's deletion", level: .info)
        } catch {
            debugLog("[CloudKit] Could not adopt the restore of \(sessionId.uuidString.prefix(8)): \(error)", level: .warning)
        }
    }
}
