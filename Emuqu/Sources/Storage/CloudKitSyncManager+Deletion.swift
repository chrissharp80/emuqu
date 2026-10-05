import CloudKit
import Foundation

// The remote-deletion paths, split out of `CloudKitSyncManager.swift` to keep
// that type under its size ceiling: the zone wipe behind "Delete All My Data"
// (GDPR / App Store), which removes every remote record the app has ever
// created, and the per-session tombstones a deletion on this device writes.

extension CloudDeletionCoordinator {
    // MARK: - Remote Deletion (GDPR / App Store)

    /// Every custom zone this app writes to the private database. Deleting
    /// these removes every remote record the app has ever created:
    ///   • "HRVSessions" — HRVSession records AND the "RawBackup"
    ///     live-recording backups (`CloudKitLiveBackupManager` shares this
    ///     zone).
    ///   • "UserSettings" — the `CloudKitSettingsSync` "primary" record.
    private var allCustomZoneIDs: [CKRecordZone.ID] {
        [
            manager.zoneID,
            CKRecordZone.ID(zoneName: "UserSettings", ownerName: CKCurrentUserDefaultName)
        ]
    }

    /// Delete ALL of this app's data from the user's private CloudKit
    /// database by deleting the custom zones outright (zone deletion
    /// removes every record inside, server-side, in one round-trip).
    /// Called by the "Delete All My Data" purge flow (GDPR Art. 17 /
    /// App Store — the flow must offer true remote deletion, not
    /// just local-state reset).
    ///
    /// Deliberately NOT guarded on `iCloudSyncEnabled` — a user who synced
    /// in the past and has since turned sync OFF still has remote records
    /// to remove, and they're asking us to delete them. Also NOT guarded
    /// on `schemaUnavailable` — that flag means record *types* are missing
    /// from the production schema; zone deletion is still valid, and a
    /// zone that doesn't exist counts as success below.
    ///
    /// Serialized via `syncSerializer` so it cannot interleave with an
    /// in-flight push/pull (which could otherwise recreate the zone
    /// mid-deletion via `ensureZoneExists`/`recreateZoneAfterNotFound`).
    ///
    /// On success: resets local sync state, clears the sanitize-drip
    /// bookkeeping (a future re-enable must start clean — those record
    /// ids no longer exist remotely), and returns true. On failure:
    /// logs and returns false; the caller surfaces "retry on network".
    func deleteAllRemoteData() async -> Bool {
        var deleted = false
        await manager.syncSerializer.run { [self] in
            deleted = await performDeleteAllRemoteData()
        }
        return deleted
    }

    /// The remote wipe caps its round-trip with the same timeout race the
    /// full-sync body uses — a wedged CloudKit call here would otherwise pin
    /// the purge UI forever AND block the local wipe that runs after this
    /// returns (the local wipe must proceed regardless of network). 30 s
    /// covers a slow single zone-modify operation; anything longer is hung and
    /// surfaces as "retry on network".
    ///
    /// Once the wipe lands (or nothing existed), local bookkeeping is reset so
    /// a future re-enable starts from scratch. `resetLocalSyncState` also
    /// clears `zoneCreated` and sets `syncState = .idle`, so the next upload
    /// (if the user keeps using the app with sync on) recreates an empty zone
    /// via `ensureZoneExists` — correct.
    private func performDeleteAllRemoteData() async -> Bool {
        let zoneNames = allCustomZoneIDs.map(\.zoneName).joined(separator: ", ")
        let outcome: Result<Bool, Error> = await manager.withTimeoutResult(seconds: 30) {
            try await self.deleteCustomZonesOnce()
        }
        guard Self.remoteDeletionSucceeded(outcome) else { return false }
        manager.resetLocalSyncState()
        clearSanitizeDripState()
        UserDefaults.standard.removeObject(forKey: Self.confirmedTombstonesKey)
        debugLog("[CloudKit] Remote deletion complete — zones [\(zoneNames)] removed from private DB; local sync manager.state reset")
        return true
    }

    /// A zone-already-gone error counts as success: the remote data the user
    /// asked us to delete doesn't exist, which IS the requested end state.
    private static func remoteDeletionSucceeded(_ outcome: Result<Bool, Error>) -> Bool {
        switch outcome {
        case .success(true):
            return true
        case .success(false):
            return false
        case let .failure(error):
            guard isZoneAlreadyGoneError(error) else {
                debugLog("[CloudKit] Remote deletion failed: \(error.localizedDescription)", level: .error)
                return false
            }
            return true
        }
    }

    /// One zone-modify round-trip deleting both custom zones. MainActor-
    /// isolated like every other CK call in this class (the async save
    /// suspends, never blocks). Returns false on a real per-zone failure;
    /// a zone that's already gone counts as deleted.
    private func deleteCustomZonesOnce() async throws -> Bool {
        let (_, deleteResults) = try await manager.privateDB.modifyRecordZones(
            saving: [],
            deleting: allCustomZoneIDs
        )
        for (zone, result) in deleteResults {
            if case let .failure(error) = result, !Self.isZoneAlreadyGoneError(error) {
                debugLog("[CloudKit] Remote deletion failed for zone \(zone.zoneName): \(error.localizedDescription)", level: .error)
                return false
            }
        }
        return true
    }

    /// Clear the Guideline 5.1.3 sanitize-drip bookkeeping. After a remote
    /// wipe the drip's remaining-id list refers to records that no longer
    /// exist; leaving it behind would make a future sync re-enable churn
    /// through pointless re-marks. Internal (not private) for unit tests.
    func clearSanitizeDripState() {
        manager.healthScrub.clear()
    }

    /// True when `error` means the zone we tried to delete doesn't exist —
    /// `.zoneNotFound` / `.userDeletedZone`, directly or wrapped in a
    /// batch `.partialFailure`. For a deletion, "already gone" is success.
    static func isZoneAlreadyGoneError(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        switch ckError.code {
        case .zoneNotFound, .userDeletedZone:
            return true
        case .partialFailure:
            guard let partial = ckError.partialErrorsByItemID, !partial.isEmpty else { return false }
            return partial.values.allSatisfy { isZoneAlreadyGoneError($0) }
        default:
            return false
        }
    }
}

// MARK: - Session tombstones

extension CloudDeletionCoordinator {
    func performUploadDeletion(sessionId: UUID) async {
        guard !manager.schemaUnavailable else { return }
        do {
            try await manager.ensureZoneExists()
            guard try await flagRecordDeleted(sessionId) else {
                manager.trashRestore.adoptFromAnotherDevice(sessionId)
                return
            }
            Self.noteTombstoneConfirmed(sessionId)
            manager.state.markDeleted(sessionId)
            manager.state.saveSyncState()
        } catch {
            if CloudKitSyncManager.isPermanentSchemaError(error) {
                manager.flagSchemaUnavailable(reason: error.localizedDescription)
                return
            }
            debugLog("[CloudKit] Delete sync failed for \(sessionId.uuidString.prefix(8)): \(error.localizedDescription)")
        }
    }

    /// Set `isDeleted` on the remote record, creating a tombstone record when
    /// the session was never uploaded in the first place.
    ///
    /// False, and nothing written, when the record says the session was
    /// restored from the Trash after this device deleted it. The full sync
    /// re-checks local deletions, so without this a restore on one phone
    /// was undone by the next sync of any other phone that had deleted it.
    private func flagRecordDeleted(_ sessionId: UUID) async throws -> Bool {
        let recordID = CKRecord.ID(recordName: sessionId.uuidString, zoneID: manager.zoneID)
        do {
            let existingRecord = try await manager.privateDB.record(for: recordID)
            let deletedAt = manager.archive.deletionTime(of: sessionId)
            if TrashRestoreCoordinator.restoreIsNewer(existingRecord, thanDeletionAt: deletedAt) {
                return false
            }
            // A deletion already in iCloud needs no second write.
            guard (existingRecord["isDeleted"] as? Int64) != 1 else { return true }
            existingRecord["isDeleted"] = 1 as CKRecordValue
            // A tombstone carries no recording. Keeping the encrypted payload
            // stored health data the user had deleted, and every device
            // re-downloaded it with each pull.
            existingRecord["sessionData"] = nil
            try await manager.privateDB.save(existingRecord)
            return true
        } catch let error as CKError where error.code == .unknownItem {
            try await saveNewTombstone(sessionId, recordID: recordID)
            return true
        }
    }

    /// A deletion for a record iCloud never had: written as a bare tombstone
    /// so other devices still learn of it.
    private func saveNewTombstone(_ sessionId: UUID, recordID: CKRecord.ID) async throws {
        let record = CKRecord(recordType: manager.recordType, recordID: recordID)
        record["sessionId"] = sessionId.uuidString as CKRecordValue
        record["isDeleted"] = 1 as CKRecordValue
        record["startDate"] = Date() as CKRecordValue // Placeholder
        try await manager.privateDB.save(record)
    }

    /// Re-check this device's deletions against iCloud: a deletion that never
    /// landed is written, and a restore made on another device since is
    /// adopted (`flagRecordDeleted`). The deleted list only grows, so a
    /// deletion iCloud has confirmed is re-checked once a day
    /// (`tombstoneRecheckInterval`), not on every sync: one fetch per deleted
    /// session per sync was hundreds of round-trips for a long-time user.
    ///
    /// Not a serial for-loop awaiting each delete in turn (53 deletions ×
    /// ~150 ms network roundtrip each = an 8-second chunk inside a 49.5 s
    /// full-sync a user logged). CloudKit handles parallel ops in a single
    /// zone fine; this runs with a bounded concurrency of 6 so we don't
    /// hammer the zone's per-second rate limit. Each delete fails
    /// independently — no shared throw. A cancelled sync (the stall watchdog
    /// fired) starts no further deletions.
    ///
    /// Lock-safe copy via `deletedIds` — the raw `deletedSessionIds` set
    /// is mutated under `archiveLock` (delete / restore / tombstone
    /// paths); reading it unlocked would race those writers.
    func reconcileLocalDeletions() async {
        let due = Self.tombstonesDue(among: manager.archive.deletedIds)
        guard !due.isEmpty else { return }
        debugLog("[CloudKit] Reconciling \(due.count) local deletions to iCloud")
        await withTaskGroup(of: Void.self) { group in
            var iterator = due.makeIterator()
            for _ in 0 ..< Self.maxConcurrentDeletions {
                addDeletionTask(to: &group, from: &iterator)
            }
            // Each finished deletion is progress: on a slow network this
            // phase alone outlasted the watchdog.
            while await group.next() != nil {
                manager.noteSyncProgress()
                addDeletionTask(to: &group, from: &iterator)
            }
        }
    }

    private func addDeletionTask(to group: inout TaskGroup<Void>, from iterator: inout Set<UUID>.Iterator) {
        guard !Task.isCancelled, let sessionId = iterator.next() else { return }
        let syncManager = manager
        group.addTask { await syncManager.deletion.performUploadDeletion(sessionId: sessionId) }
    }

    private static let maxConcurrentDeletions = 6

    /// When each deletion was last confirmed in iCloud, keyed by session id.
    static let confirmedTombstonesKey = "cloudkit.confirmedTombstones"
    private static let tombstoneRecheckInterval: TimeInterval = 86_400

    /// The deletions not confirmed within `tombstoneRecheckInterval`. Entries
    /// for sessions no longer deleted (restored, or purged) are dropped.
    private static func tombstonesDue(among deleted: Set<UUID>) -> Set<UUID> {
        let stored = UserDefaults.standard.dictionary(forKey: confirmedTombstonesKey) as? [String: Double] ?? [:]
        let confirmed = stored.filter { entry in UUID(uuidString: entry.key).map { deleted.contains($0) } ?? false }
        if confirmed.count != stored.count {
            UserDefaults.standard.set(confirmed, forKey: confirmedTombstonesKey)
        }
        let cutoff = Date().timeIntervalSince1970 - tombstoneRecheckInterval
        return deleted.filter { (confirmed[$0.uuidString] ?? 0) < cutoff }
    }

    private static func noteTombstoneConfirmed(_ sessionId: UUID) {
        var confirmed = UserDefaults.standard.dictionary(forKey: confirmedTombstonesKey) ?? [:]
        confirmed[sessionId.uuidString] = Date().timeIntervalSince1970
        UserDefaults.standard.set(confirmed, forKey: confirmedTombstonesKey)
    }
}
