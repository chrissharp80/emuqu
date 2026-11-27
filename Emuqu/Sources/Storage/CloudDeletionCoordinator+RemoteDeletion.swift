import CloudKit
import Foundation

// The remote-deletion paths: the zone wipe behind "Delete All My Data"
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
    /// a future re-enable starts from scratch, and iCloud Sync is turned off
    /// with the recorded account forgotten: the user asked for their iCloud
    /// data to be deleted, so nothing recreates the zones or uploads again
    /// until they turn sync on, the same rule a deletion found by a sync
    /// follows (`CloudAccountGuard.zoneWasDeleted`). `resetLocalSyncState`
    /// also clears `zoneCreated` and sets `syncState = .idle`.
    ///
    /// Zones are deleted only in an account this device may delete from
    /// (`mayDeleteInSignedInAccount`); in any other the remote step reports
    /// failure, deletes nothing, and the purge tells the user to run it again
    /// signed into their iCloud account. The account check runs inside the
    /// same 30 s cap.
    private func performDeleteAllRemoteData() async -> Bool {
        let zoneNames = allCustomZoneIDs.map(\.zoneName).joined(separator: ", ")
        let outcome: Result<Bool, Error> = await manager.withTimeoutResult(seconds: 30) {
            guard await self.mayDeleteInSignedInAccount() else { return false }
            return try await self.deleteCustomZonesOnce()
        }
        guard Self.remoteDeletionSucceeded(outcome) else { return false }
        manager.settingsManager.settings.iCloudSyncEnabled = false
        CloudAccountIdentity.forget()
        manager.resetLocalSyncState()
        clearSanitizeDripState()
        forgetConfirmedTombstones()
        debugLog("[CloudKit] Remote deletion complete — zones [\(zoneNames)] removed from private DB; sync turned off, local sync manager.state reset")
        return true
    }

    /// Whether "Delete All My Data" may delete the app's zones in the
    /// signed-in iCloud account: it is the account sync is enabled for
    /// (`CloudAccountGuard.confirmAccount`, which adopts an unrecorded one as
    /// a sync would), or no account is recorded and nothing shows the
    /// signed-in one to be another person's (a reinstall, sync never turned
    /// on). Not when the check finds a different account (and resets the
    /// bookkeeping), when the app stopped sync earlier because the device was
    /// signed into a different account, or when the account cannot be
    /// checked.
    private func mayDeleteInSignedInAccount() async -> Bool {
        switch await manager.accountGuard.confirmAccount() {
        case .confirmed:
            return true
        case .unavailable, .differentAccount:
            debugLog("[CloudKit] Remote deletion skipped — the signed-in iCloud account could not be checked, or is not the one this device synced with", level: .warning)
            return false
        case .stopped:
            // Nothing is recorded here (`CloudAccountIdentity.Verdict.awaitingOptIn`).
            let mayDelete = CloudAccountIdentity.stopReason != .differentAccount
            if !mayDelete {
                debugLog("[CloudKit] Remote deletion skipped — sync was stopped for a different iCloud account", level: .warning)
            }
            return mayDelete
        }
    }

    /// Forget which deletions iCloud confirmed: they describe zones that are
    /// gone, or another account's.
    func forgetConfirmedTombstones() {
        UserDefaults.standard.removeObject(forKey: Self.confirmedTombstonesKey)
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
    /// Write this device's deletion of the session to iCloud
    /// (`flagRecordDeleted`) and, once it is there, record it as confirmed
    /// (`noteDeletionConfirmed`). A restore made on another device since is
    /// adopted instead (`yieldToRestore`). A failure is logged and left for
    /// the next full sync (`reconcileLocalDeletions`). An account change or
    /// an abandoned sync during the fetch stops it before anything is written
    /// or recorded (`requireAccountStillConfirmed`); the deletion stays to be
    /// sent by the next sync for the right account.
    func performUploadDeletion(sessionId: UUID) async {
        guard !manager.schemaUnavailable else { return }
        do {
            try await manager.ensureZoneExists()
            guard try await flagRecordDeleted(sessionId) else {
                yieldToRestore(sessionId)
                return
            }
            try requireAccountStillConfirmed()
            noteDeletionConfirmed(sessionId)
        } catch CloudAccountGuard.Halt.stopped {
            debugLog("[CloudKit] Delete sync for \(sessionId.uuidString.prefix(8)) stopped: the account changed or the sync was abandoned", level: .info)
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            // The zone was deleted: no tombstone is written into a recreated
            // one, and sync stops for the user to opt in again.
            debugLog("[CloudKit] Delete sync found the zone gone (\(error.code.rawValue)) for \(sessionId.uuidString.prefix(8))", level: .warning)
            _ = await manager.accountGuard.zoneWasDeleted()
        } catch {
            noteDeletionFailed(error, sessionId: sessionId)
        }
    }

    /// A schema error pauses sync; any other failure is retried next sync,
    /// which until then is not shown as up to date (`lastDeletionErrorMessage`).
    private func noteDeletionFailed(_ error: Error, sessionId: UUID) {
        // A deletion the stall watchdog abandoned reports nothing into the
        // next sync, which sends it again.
        guard !Task.isCancelled else { return }
        if CloudKitSyncManager.isPermanentSchemaError(error) {
            manager.flagSchemaUnavailable(reason: error.localizedDescription)
            return
        }
        manager.lastDeletionErrorMessage = CloudSyncMessages.deletionsPending
        debugLog("[CloudKit] Delete sync failed for \(sessionId.uuidString.prefix(8)): \(error.localizedDescription)", level: .warning)
    }

    /// Another device restored the session after this one deleted it: no
    /// deletion is written over the restore. The local deletion stays until
    /// the pull, which follows in the same sync, writes the restored copy
    /// here (`SessionArchive.archiveRestoredFromAnotherDevice`), so a failed
    /// download leaves the session in this device's Trash. A session deleted
    /// forever here (`ForgottenSessions`) is never imported.
    private func yieldToRestore(_ sessionId: UUID) {
        debugLog("[CloudKit] \(sessionId.uuidString.prefix(8)) was restored on another device — leaving it to the pull", level: .info)
    }

    /// iCloud holds the deletion: it is recorded as confirmed, and the sync
    /// state forgets the session. A session deleted forever here then drops
    /// its deletion mark (`SessionArchive.forgetDeletedSession`), which no
    /// longer needs re-sending.
    private func noteDeletionConfirmed(_ sessionId: UUID) {
        Self.noteTombstoneConfirmed(sessionId)
        manager.state.markDeleted(sessionId)
        manager.state.saveSyncState()
        guard ForgottenSessions.ids.contains(sessionId) else { return }
        do {
            try manager.archive.forgetDeletedSession(sessionId)
        } catch {
            debugLog("[CloudKit] Could not drop the deletion mark of \(sessionId.uuidString.prefix(8)): \(error)", level: .warning)
        }
    }

    /// Whether the deletion mark of a session deleted forever may be dropped:
    /// iCloud has confirmed the deletion (`confirmedTombstonesKey`), or this
    /// device has never synced (no sync completed, no zone created), so
    /// iCloud never received the session from here. Until then the mark
    /// stays, and the full sync keeps sending the deletion.
    func tombstoneIsSettled(_ sessionId: UUID) -> Bool {
        let confirmed = UserDefaults.standard.dictionary(forKey: Self.confirmedTombstonesKey)?[sessionId.uuidString] != nil
        return confirmed || (manager.lastSyncDate == nil && !manager.zoneCreated)
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
            let deletedAt = manager.archive.store.deletionTime(of: sessionId)
            if TrashRestoreCoordinator.restoreIsNewer(existingRecord, thanDeletionAt: deletedAt) {
                return false
            }
            // A deletion already in iCloud needs no second write, unless an older build left its payload on it.
            guard (existingRecord["isDeleted"] as? Int64) != 1 || existingRecord["sessionData"] != nil else { return true }
            existingRecord["isDeleted"] = 1 as CKRecordValue
            // A tombstone carries no recording. Keeping the encrypted payload
            // stored health data the user had deleted, and every device
            // re-downloaded it with each pull.
            existingRecord["sessionData"] = nil
            try await saveTombstone(existingRecord)
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
        try await saveTombstone(record)
    }

    /// Writes a tombstone, only while the account it was checked against is
    /// still the one signed in (`requireAccountStillConfirmed`).
    private func saveTombstone(_ record: CKRecord) async throws {
        try requireAccountStillConfirmed()
        _ = try await manager.privateDB.save(record)
    }

    /// The account the deletion was checked against is still the one signed
    /// in, and the sync it runs in was not abandoned by the stall watchdog:
    /// the fetch before a tombstone's write suspends, and a write after an
    /// account change would land in the other account's zone while this
    /// one's deletion was recorded as sent. Throws `Halt.stopped` otherwise.
    private func requireAccountStillConfirmed() throws {
        guard CloudAccountIdentity.isConfirmed, !Task.isCancelled else { throw CloudAccountGuard.Halt.stopped }
    }

    /// Re-check this device's deletions against iCloud: a deletion that never
    /// landed is written, and a restore made on another device since is
    /// adopted (`flagRecordDeleted`). The deleted list only grows, so a
    /// deletion iCloud has confirmed is re-checked once a day
    /// (`tombstoneRecheckInterval`), not on every sync: one fetch per deleted
    /// session per sync is hundreds of round-trips for a long-time user.
    ///
    /// Not a serial for-loop awaiting each delete in turn: at ~150 ms a
    /// network round-trip, 53 deletions add 8 s to a full sync. CloudKit handles parallel ops in a single
    /// zone fine; this runs with a bounded concurrency of 6 so we don't
    /// hammer the zone's per-second rate limit. Each delete fails
    /// independently — no shared throw. A cancelled sync (the stall watchdog
    /// fired), or one whose iCloud account is no longer confirmed, starts no
    /// further deletions.
    ///
    /// Lock-safe copy via `deletedIds` — the raw `deletedSessionIds` set
    /// is mutated under `archiveLock` (delete / restore / tombstone
    /// paths); reading it unlocked would race those writers.
    ///
    /// First, the iCloud live backups of deleted sessions, and of sessions
    /// deleted forever, whose delete failed are deleted again
    /// (`CloudKitLiveBackupManager.retryAwaitingDeletion`), and those of
    /// sessions archived here and already in iCloud, which the backup no
    /// longer protects.
    ///
    /// Writes nothing before onboarding's iCloud choice
    /// (`cloudUploadsAllowed`): a tombstone is a write to iCloud like an
    /// upload. The deletions stay listed and go up once it is allowed.
    func reconcileLocalDeletions() async {
        manager.lastDeletionErrorMessage = nil
        guard manager.cloudUploadsAllowed else { return }
        let deleted = manager.archive.store.deletedIds
        let archivedAndInCloud = manager.state.uploadedSessionIds.filter { manager.archive.store.exists($0) }
        await manager.liveBackup.retryAwaitingDeletion(among: deleted.union(ForgottenSessions.ids).union(archivedAndInCloud))
        let due = Self.tombstonesDue(among: deleted)
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
        guard !Task.isCancelled, CloudAccountIdentity.isConfirmed, let sessionId = iterator.next() else { return }
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
