import CloudKit
import Foundation

// The pull half of CloudKit sync. Pull runs as a distinct phase after push,
// shares only the manager's stored state, and nothing in push reaches into it.

extension CloudPullCoordinator {

    // MARK: - Pull (Fetch Remote Changes)

    /// The tally one pull produced.
    private struct PullCounts {
        var newSessions = 0
        var deleted = 0
        /// Sessions replaced by a newer copy from iCloud.
        var refreshed = 0
        /// Ids of sessions archived NEW, or replaced without their sleep
        /// snapshot, by this pull — handed to the HK sleep/vitals backfill below.
        var backfillIds: [UUID] = []
        /// Records sealed with a key this device does not hold yet.
        var awaitingKey = 0
    }

    /// List every record and process each; then re-queue what iCloud lacks,
    /// save the sync state and run the post-pull backfills. When the stall
    /// watchdog fired, or the iCloud account changed, partway, the pull stops
    /// there: a partial pull, which the next sync redoes for the right
    /// account. A zone found gone is `handleMissingZone`'s.
    func pullRemoteChanges() async {
        manager.lastPullErrorMessage = nil
        do {
            let results = try await fetchAllRemoteRecords()
            let counts = await processRemoteRecords(results)
            guard !Task.isCancelled, CloudAccountIdentity.isConfirmed else { return }
            manager.recordsAwaitingKeyCount = counts.awaitingKey
            reuploadSessionsMissingFromCloud(results)
            await manager.state.saveSyncStateAsync()
            await manager.state.savePendingQueueAsync()
            if counts.newSessions > 0 || counts.refreshed > 0 {
                await runPostPullBackfills(counts)
            }
            if counts.newSessions > 0 || counts.deleted > 0 || counts.refreshed > 0 {
                manager.pullVersion += 1
            }
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            await handleMissingZone(error)
        } catch {
            handlePullFailure(error)
        }
    }

    /// Only the fields that decide what to do with a record. The backup file
    /// (`sessionData`) is fetched separately, for the ids this device lacks or
    /// holds an older copy of (`modifiedAt` says which): listed for every
    /// record, it downloaded every session's file on every sync only to drop
    /// nearly all of them.
    private static let listingKeys: [CKRecord.FieldKey] = [
        "isDeleted", "startDate", CloudKitSessionFreshness.modifiedAtField
    ]

    /// Query CloudKit for all sessions. Uses `startDate > 0` instead of
    /// TRUEPREDICATE because CloudKit custom zones require a queryable indexed
    /// field in the predicate, and paginates because CloudKit returns only
    /// ~200-400 per batch.
    private func fetchAllRemoteRecords() async throws -> [(CKRecord.ID, Result<CKRecord, Error>)] {
        let query = CKQuery(recordType: manager.recordType, predicate: NSPredicate(format: "startDate > %@", NSDate(timeIntervalSince1970: 0)))
        query.sortDescriptors = [NSSortDescriptor(key: "startDate", ascending: false)]
        var allResults: [(CKRecord.ID, Result<CKRecord, Error>)] = []
        var (pageResults, cursor) = try await manager.privateDB.records(
            matching: query, inZoneWith: manager.zoneID,
            desiredKeys: Self.listingKeys, resultsLimit: CKQueryOperation.maximumResults
        )
        allResults.append(contentsOf: pageResults)
        manager.noteSyncProgress() // pulled a page — sync is advancing
        while let nextCursor = cursor, !Task.isCancelled {
            let (moreResults, nextNext) = try await manager.privateDB.records(
                continuingMatchFrom: nextCursor, desiredKeys: Self.listingKeys, resultsLimit: CKQueryOperation.maximumResults
            )
            allResults.append(contentsOf: moreResults)
            cursor = nextNext
            manager.noteSyncProgress() // pulled another page — still advancing
        }
        return allResults
    }

    /// A session this device believes is in iCloud but the complete remote
    /// listing does not contain goes back in the upload queue: a record lost
    /// from the zone, which nothing else ever noticed, so the archive stayed
    /// out of iCloud while Settings said everything was synced. Only after a
    /// listing with no per-record errors — a partial answer would re-upload
    /// sessions that are there — and only for a session missing from this
    /// listing and the one before it (`missingFromLastListing`): a record
    /// saved seconds ago by the push can be absent from a listing whose query
    /// index has not caught up yet.
    ///
    /// Only while the signed-in account is the recorded one
    /// (`CloudAccountIdentity.isConfirmed`): another Apple ID's listing lacks
    /// every session, and re-queueing them would upload the archive into it.
    private func reuploadSessionsMissingFromCloud(_ results: [(CKRecord.ID, Result<CKRecord, Error>)]) {
        guard CloudAccountIdentity.isConfirmed else { return }
        guard results.allSatisfy({ if case .success = $0.1 { true } else { false } }) else { return }
        let remoteIds = Set(results.compactMap { UUID(uuidString: $0.0.recordName) })
        let missing = manager.state.uploadedSessionIds.filter {
            !remoteIds.contains($0) && manager.archive.store.exists($0) && !manager.archive.store.wasIntentionallyDeleted($0)
        }
        let confirmed = missing.intersection(manager.missingFromLastListing)
        manager.missingFromLastListing = missing
        guard !confirmed.isEmpty else { return }
        for id in confirmed { manager.state.markRemoved(id) }
        debugLog("[CloudKit] Pull: \(confirmed.count) session(s) marked uploaded are not in iCloud — queued to upload again", level: .warning)
    }

    /// `processRemoteRecord` is async (the heavy decode runs in a detached
    /// task), so every iteration suspends and the main actor can interleave UI
    /// work between records — no explicit Task.yield() needed. Records are
    /// still processed strictly in order, one at a time.
    ///
    /// A record the listing could not return is not imported this pass, and
    /// the sync ends as an error rather than "Up to date" (`noteListingFailure`).
    /// The sessions deleted forever (`ForgottenSessions`) are read once per
    /// pull, not once per record. An account change during the pull stops it
    /// at the next record: nothing from another Apple ID is imported.
    private func processRemoteRecords(
        _ results: [(CKRecord.ID, Result<CKRecord, Error>)]
    ) async -> PullCounts {
        var counts = PullCounts()
        let forgotten = ForgottenSessions.ids
        for (_, result) in results {
            if Task.isCancelled || !CloudAccountIdentity.isConfirmed { break }
            guard let record = listedRecord(result) else { continue }
            // Seen, so an edit made here afterwards is stamped after it.
            CloudKitSessionFreshness.noteSeen(CloudKitSessionFreshness.modifiedAt(of: record))
            let outcome = await processRemoteRecord(record, forgotten: forgotten)
            manager.noteSyncProgress() // processed a remote record — sync is advancing
            counts.newSessions += outcome.new
            counts.deleted += outcome.deleted
            counts.refreshed += outcome.refreshed
            counts.awaitingKey += outcome.awaitingKey
            if let id = outcome.backfillId { counts.backfillIds.append(id) }
        }
        return counts
    }

    /// The listed record, or nil when that entry of the listing failed
    /// (`noteListingFailure`).
    private func listedRecord(_ result: Result<CKRecord, Error>) -> CKRecord? {
        switch result {
        case let .success(record):
            return record
        case let .failure(error):
            noteListingFailure(error)
            return nil
        }
    }

    /// One record of the listing failed. Logged, and kept as the pull's error
    /// so the full sync does not report success over a session it did not
    /// import.
    private func noteListingFailure(_ error: Error) {
        debugLog("[CloudKit] Pull: a record in the listing failed: \(error.localizedDescription)", level: .warning)
        manager.lastPullErrorMessage = String(localized: "A session from iCloud couldn't be imported: \(error.localizedDescription)", bundle: LanguageManager.appBundle)
    }

    /// Pulled sessions were archived via `processRemoteRecord` without going
    /// through the deferred-migration backfills (recovery score, end date,
    /// metrics, re-linking). Run them now so the index is consistent with
    /// locally-recorded sessions. The migrations are idempotent and per-entry,
    /// so already-migrated entries are skipped.
    ///
    /// The sessions just archived had their
    /// HK-derived `sleepSnapshot` / `vitalsSnapshot` stripped on upload
    /// (Guideline 5.1.3), so they arrive blank. `autoRefreshTodaysSleepIfImproved`
    /// only re-fills TODAY on a live HK observer bump — it never runs on a pull
    /// and is gated to today, so every synced PAST session stays blank until
    /// manually opened. Hand the ids to RRCollector (it owns `healthKit` + the
    /// bounded backfill helper) via a decoupled notification; the backfill
    /// drips a few per cycle at low priority and respects `sleepUserAdjusted`.
    private func runPostPullBackfills(_ counts: PullCounts) async {
        // Hoisted so the detached closure captures the archive, not `self`.
        let archive = manager.archive
        await Task.detached(priority: .utility) {
            archive.migrations.runDeferredMigrations()
        }.value
        guard !counts.backfillIds.isEmpty else { return }
        NotificationCenter.default.post(
            name: .cloudKitSnapshotBackfillNeeded,
            object: nil,
            userInfo: ["sessionIds": counts.backfillIds]
        )
    }

    /// Zone gone server-side. `.zoneNotFound` after this device created the
    /// zone, or `.userDeletedZone`, means the app's iCloud data was deleted:
    /// by Delete All My Data on another device, or in the iCloud settings.
    /// Recreating the zone and queueing every session again undid that
    /// deletion, so `CloudAccountGuard.zoneWasDeleted` stops sync instead,
    /// after checking the account afresh (another Apple ID's empty container
    /// looks the same). Nothing is recreated or queued; when the account
    /// cannot be checked, the reason ends the sync as an error.
    private func handleMissingZone(_ error: CKError) async {
        debugLog("[CloudKit] Pull: zone gone (\(error.code.rawValue)) — iCloud data was deleted, or the account changed", level: .warning)
        if let message = await manager.accountGuard.zoneWasDeleted() {
            manager.lastPullErrorMessage = message
        }
    }

    /// Record the failure instead of only debug-logging it, so
    /// the sync body reports `.error` rather than a false "Up to date" (see
    /// `lastPullErrorMessage`).
    private func handlePullFailure(_ error: Error) {
        if CloudKitSyncManager.isPermanentSchemaError(error) {
            manager.flagSchemaUnavailable(reason: error.localizedDescription)
            return
        }
        manager.lastPullErrorMessage = manager.cloudKitErrorMessage(error)
        debugLog("[CloudKit] Pull failed: \(error.localizedDescription)")
    }

    /// Process a single remote CloudKit record: handle soft-deletes, archive
    /// new sessions, and replace a held copy only with a newer one. A session
    /// deleted forever on this device (in `forgotten`) is left alone, whatever
    /// iCloud holds of it: never imported, refreshed or marked uploaded.
    /// Cheap guards run on the main actor; the expensive asset read + decompress +
    /// JSON decode runs in a detached utility task (see comment at the decode site).
    ///
    /// `backfillId` reports the session id when this record was
    /// archived as a NEW session, so `pullRemoteChanges` can hand it to the
    /// HK sleep/vitals backfill (synced past sessions arrive with the
    /// HK-derived snapshots stripped per Guideline 5.1.3 and must be
    /// re-derived locally). nil for skips and deletes.
    ///
    /// A record marked kept on another device
    /// (`CloudKitSyncManager.keptOnDeviceMarker`) has no payload and is left
    /// alone; a copy held here counts as uploaded and stays as it is. A
    /// restore made on another device after this one applied a deletion
    /// (`isRestoreToAdopt`) is imported with this pull; the local deletion is
    /// dropped only in the step that writes the iCloud copy here.
    func processRemoteRecord(_ record: CKRecord, forgotten: Set<UUID>) async -> RecordOutcome {
        let sessionIdString = record.recordID.recordName
        guard let sessionId = UUID(uuidString: sessionIdString), !forgotten.contains(sessionId) else { return RecordOutcome() }
        let deletedFlag = record["isDeleted"] as? Int64 ?? 0
        // Handle soft-deleted records — except one this device restored from
        // the Trash and has not uploaded yet: its upload overrides the
        // tombstone, and deleting it here undid the restore.
        if deletedFlag == 1, !manager.trashRestore.isRestored(sessionId) {
            let counts = handleDeletedRecord(sessionId: sessionId, sessionIdString: sessionIdString, deletedAt: record.modificationDate)
            return RecordOutcome(new: counts.new, deleted: counts.deleted)
        }
        if deletedFlag == CloudKitSyncManager.keptOnDeviceMarker {
            _ = isKnownLocally(sessionId, listed: record)
            return RecordOutcome()
        }
        let adopting = isRestoreToAdopt(record, sessionId: sessionId)
        guard adopting || !isKnownLocally(sessionId, listed: record) else { return await refreshIfRemoteIsNewer(record, sessionId: sessionId) }
        guard let fetched = await assetFile(for: record) else { return RecordOutcome() }
        return await importPulledSession(from: fetched, sessionId: sessionId, sessionIdString: sessionIdString, adoptingRestore: adopting)
    }

    /// The local file of the record's backup and the record it came from,
    /// fetching the full record when the listing left it out; nil when there
    /// is none. The file's date and change tag are the fetched record's: the
    /// record may have been edited on another device since it was listed. A live record that
    /// carries no backup is kept as the pull's error, as a failed fetch is
    /// (`recordWithAsset`): the session is not imported, so the sync must not
    /// read "Up to date".
    func assetFile(for record: CKRecord) async -> (url: URL, record: CKRecord)? {
        guard let full = await recordWithAsset(record) else { return nil }
        guard let asset = full["sessionData"] as? CKAsset, let assetURL = asset.fileURL else {
            debugLog("[CloudKit] Pull: No asset data for \(record.recordID.recordName.prefix(8))", level: .warning)
            manager.lastPullErrorMessage = String(
                localized: "A session in iCloud has no recording attached, so it couldn't be imported.",
                bundle: LanguageManager.appBundle
            )
            return nil
        }
        return (assetURL, full)
    }

    /// This device applied a deletion of the session (from another device,
    /// or its own), and another device has since restored it from its Trash:
    /// the record carries the restore marker, dated after the deletion here
    /// (`TrashRestoreCoordinator.restoreIsNewer`). This pull imports the
    /// session, rather than the daily re-check of local deletions doing it up
    /// to a day later. A session deleted forever here never reaches this point.
    private func isRestoreToAdopt(_ record: CKRecord, sessionId: UUID) -> Bool {
        !manager.archive.store.exists(sessionId) && manager.archive.store.wasIntentionallyDeleted(sessionId)
            && TrashRestoreCoordinator.restoreIsNewer(record, thanDeletionAt: manager.archive.store.deletionTime(of: sessionId))
    }

    /// The record with its backup file. A listed record carries only
    /// `listingKeys`, so the full one is fetched; nil, with the failure
    /// reported, when that fetch fails.
    private func recordWithAsset(_ record: CKRecord) async -> CKRecord? {
        if record["sessionData"] is CKAsset { return record }
        do {
            return try await manager.privateDB.record(for: record.recordID)
        } catch {
            // A pull the stall watchdog abandoned reports nothing into the next one.
            guard !Task.isCancelled else { return nil }
            manager.lastPullErrorMessage = manager.cloudKitErrorMessage(error)
            debugLog("[CloudKit] Pull: fetching \(record.recordID.recordName.prefix(8)) failed: \(error.localizedDescription)", level: .warning)
            return nil
        }
    }

    /// True when this device already has the session, or deleted it on
    /// purpose (so a pull never re-downloads something the user removed). The
    /// session is then marked uploaded — unless it is pending: a pending id is
    /// a local change waiting to go up, and iCloud holding an older copy does
    /// not make it uploaded. Whether a held copy is replaced by a newer one is
    /// `refreshIfRemoteIsNewer`'s decision.
    private func isKnownLocally(_ sessionId: UUID, listed record: CKRecord) -> Bool {
        guard manager.archive.store.exists(sessionId) || manager.archive.store.wasIntentionallyDeleted(sessionId) else {
            return false
        }
        // A Trash restore not yet uploaded is not in iCloud, whatever the
        // queue says: its upload clears the flag.
        if !manager.state.pendingUploadIds.contains(sessionId), !manager.trashRestore.isRestored(sessionId) {
            markHeldCopy(sessionId, against: record)
        }
        return true
    }

    /// A held copy edited later than the iCloud copy (`holdsUnsentEdit`) is a
    /// change iCloud lacks whatever the bookkeeping says, such as one whose
    /// upload request was lost with the launch that made it: it is queued to
    /// go up rather than marked uploaded. Any other held copy is what iCloud
    /// holds, or older.
    private func markHeldCopy(_ sessionId: UUID, against record: CKRecord) {
        let local = manager.archive.entryById(sessionId)?.modifiedAt
        if CloudKitSessionFreshness.holdsUnsentEdit(localModifiedAt: local, remoteModifiedAt: CloudKitSessionFreshness.modifiedAt(of: record)) {
            manager.state.markRemoved(sessionId)
        } else {
            manager.state.markUploaded(sessionId)
        }
    }

    /// Asset read + decompress + JSON decode run off
    /// the main actor (a
    /// 30k-point rrSeries decode per record, repeated for every
    /// pulled record in one uninterrupted MainActor slice, would freeze
    /// launch/foreground). Only `assetURL` (URL, Sendable) crosses
    /// into the detached task; only the decoded `HRVSession`
    /// (Sendable value struct) crosses back.
    ///
    /// CloudKit-pulled sessions are the authoritative
    /// cross-device-merged version of their session id. Folding
    /// them into a local same-night entry is double-merging AND
    /// catastrophically slow under load (one pull can trigger dozens
    /// of merges in seconds — each one a full
    /// retrieve + decrypt + decode + merge + encode + encrypt +
    /// write + SHA256 + index save, all on main thread under
    /// archiveLock). The merge is skipped here; the existing
    /// `removeDuplicates` migration handles genuine stale-night
    /// cleanup after the 24-hour safety window.
    ///
    /// NOTE: `archive.archive` (encode + encrypt + write under archiveLock)
    /// runs on the main actor, bounded per record.
    ///
    /// Per-record failures are surfaced instead of only
    /// debug-logged. The record IS retried on the next pull (it stays
    /// un-marked, and the query returns everything), but a record that fails
    /// deterministically (corrupt asset, future-schema payload) would fail
    /// forever while Settings shows "Up to date". Recording it here makes the
    /// sync body report `.error` and skip the lastSyncDate stamp.
    ///
    /// A record sealed with a key this device does not hold yet — another
    /// device's, still travelling through iCloud Keychain — is not a failure:
    /// it stays un-imported and the next pull, once the key has arrived,
    /// imports it. Reporting it as an error would withhold the sync stamp and
    /// re-run the full pull on every activation until then. It is counted
    /// instead (`RecordOutcome.awaitingKey`), and the sync ends waiting for
    /// keys rather than up to date (`CloudKitSyncManager.completion`).
    ///
    /// A record saved by a newer app version is skipped the same way: this
    /// build refuses to write it, and an error would keep sync failing on
    /// every pull until the app is updated.
    ///
    /// A restore made on another device (`adoptingRestore`) drops the local
    /// deletion in the same step as the write
    /// (`SessionArchive.archiveRestoredFromAnotherDevice`), so a failed
    /// download, decode or write leaves the session deleted and in this
    /// device's Trash. A Trash copy left here is removed once the session is
    /// in the archive.
    private func importPulledSession(
        from fetched: (url: URL, record: CKRecord), sessionId: UUID, sessionIdString: String, adoptingRestore: Bool
    ) async -> RecordOutcome {
        let (assetURL, version) = (fetched.url, fetched.record.recordChangeTag)
        do {
            let session = try await Task.detached(priority: .utility) {
                try Self.decodeSessionAsset(at: assetURL, archiveKey: manager.archive.encryption)
            }.value
            // The stall watchdog fired, or the account changed, while it
            // decoded: the next sync imports it.
            guard !Task.isCancelled, CloudAccountIdentity.isConfirmed else { return RecordOutcome() }
            if adoptingRestore {
                try manager.archive.archiveRestoredFromAnotherDevice(session)
            } else {
                try manager.archive.archive(session, skipSameNightMerge: true)
                manager.archive.store.discardTrashed(sessionId)
            }
            manager.state.markUploaded(sessionId)
            manager.state.noteRecordVersion(version, of: sessionId)
            return RecordOutcome(new: 1, backfillId: sessionId)
        } catch {
            return importFailure(error, sessionIdString: sessionIdString)
        }
    }

    /// A record that could not be imported: waiting for its key and from a
    /// newer app version are skipped quietly (see `importPulledSession`);
    /// anything else is reported.
    func importFailure(_ error: Error, sessionIdString: String) -> RecordOutcome {
        if let codecError = error as? CloudPayloadCodec.CodecError, case .noMatchingKey = codecError {
            debugLogExternal("iCloud record \(sessionIdString.prefix(8)) is waiting for its backup key to sync to this device", cause: .iCloud)
            return RecordOutcome(awaitingKey: 1)
        } else if let archiveError = error as? SessionArchive.ArchiveError,
                  case .newerSchemaVersion(let version) = archiveError {
            debugLog("[CloudKit] Pull: \(sessionIdString.prefix(8)) is from a newer app version (schema v\(version)) — skipped until the app is updated", level: .warning)
        } else if !Task.isCancelled {
            // A pull the stall watchdog abandoned reports nothing into the next one.
            manager.lastPullErrorMessage = String(localized: "A session from iCloud couldn't be imported: \(error.localizedDescription)", bundle: LanguageManager.appBundle)
            debugLog("[CloudKit] Pull: Failed to process \(sessionIdString.prefix(8)): \(error.localizedDescription)", level: .warning)
        }
        return RecordOutcome()
    }

    /// JSONDecoder is not Sendable — a fresh one is built here, inside the
    /// detached closure, rather than captured across the actor boundary.
    nonisolated static func decodeSessionAsset(at assetURL: URL, archiveKey: EncryptionManager) throws -> HRVSession {
        let compressedData = try Data(contentsOf: assetURL)
        // Payloads are encrypted before upload. Older records predate
        // that and are still compressed-only, so decryption is attempted and
        // the raw bytes are used when it fails — otherwise every backup made
        // before encryption would be orphaned.
        // The codec identifies its own envelope, so a pre-encryption record is
        // recognised rather than inferred from a failed decryption: a
        // `try?`-and-fall-back would treat a
        // wrong-key ciphertext as legacy data and hand compressed garbage to
        // the decoder.
        let decrypted = try CloudPayloadCodec.decode(compressedData, archiveKey: archiveKey)
        let jsonData = try DataCompression.decompress(decrypted)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(HRVSession.self, from: jsonData)
    }

    /// Deleted on another device. Copying this device's `isDeleted = 0` over
    /// the tombstone brought the session back everywhere, so on a conflict
    /// with a tombstone — batch push or direct upload — the deletion wins and
    /// is applied here, the same way a pull applies it.
    func applyDeletionMetDuringUpload(_ sessionId: UUID, deletedAt: Date?) {
        let counts = handleDeletedRecord(sessionId: sessionId, sessionIdString: sessionId.uuidString, deletedAt: deletedAt)
        if counts.deleted > 0 { manager.pullVersion += 1 }
        debugLog("[CloudKit] Upload of \(sessionId.uuidString.prefix(8)) met a deletion from another device — applying it")
    }

    /// Handle a soft-deleted remote record by deleting the local copy if it exists
    /// (`removeLocalCopy`). `deletedAt` is when the tombstone was written to
    /// iCloud (its record's modification date), kept as the deletion's time
    /// here: dated by when this device applied it, the deletion read as newer
    /// than a Trash restore made since on the deleting device, and the next
    /// sync rewrote the tombstone over that restore.
    ///
    /// A local copy that could not be removed stays in the archive, and in
    /// the sync state: the deletion is not counted, the sync ends as an error
    /// rather than "Up to date", and the next pull, which lists the tombstone
    /// again, tries once more.
    func handleDeletedRecord(sessionId: UUID, sessionIdString: String, deletedAt: Date?) -> (new: Int, deleted: Int) {
        var deletedCount = 0
        if manager.archive.store.exists(sessionId) {
            do {
                try removeLocalCopy(sessionId, deletedAt: deletedAt)
                deletedCount = 1
            } catch {
                debugLog("[CloudKit] Pull: Failed to delete local session \(sessionIdString.prefix(8)): \(error)", level: .warning)
                manager.lastPullErrorMessage = String(
                    localized: "A session deleted on another device couldn't be removed from this device. It will be tried again at the next sync.",
                    bundle: LanguageManager.appBundle
                )
                return (0, 0)
            }
        }
        manager.state.markDeleted(sessionId)
        return (0, deletedCount)
    }

    /// The local copy of a session deleted on another device. It is normally
    /// not kept in this device's Trash: the deletion was made, and can be
    /// undone or made final, on the other device, and kept here a session
    /// deleted for good there could be restored here. So the file is removed
    /// directly (`deleteWithoutTrash`), which throws when the file will
    /// neither go nor move into the Trash, keeping the session.
    ///
    /// A copy with a change of this device's that iCloud does not hold yet
    /// (`hasUnsentLocalChange`) goes to this device's Trash instead, so the
    /// change is not lost unrecoverably. When the Trash cannot take it the
    /// copy stays, and the next pull tries again: it is never removed
    /// without a Trash copy.
    private func removeLocalCopy(_ sessionId: UUID, deletedAt: Date?) throws {
        if hasUnsentLocalChange(sessionId, deletedAt: deletedAt) {
            try manager.archive.delete(sessionId, deletedAt: deletedAt)
            return
        }
        try manager.archive.deleteWithoutTrash(sessionId, deletedAt: deletedAt)
        if !manager.archive.store.discardTrashed(sessionId) {
            debugLog("[CloudKit] Pull: \(sessionId.uuidString.prefix(8)) left a copy in the Trash, removed when the Trash expires", level: .warning)
        }
    }

    /// Whether this device changed the session in a way iCloud does not hold
    /// yet: an upload queued in the sync state (`pendingUploadIds`), a
    /// re-upload request on disk that sync has not taken in yet
    /// (`ReuploadRequestJournal`: an edit made while a long sync held the
    /// serializer), or a copy stamped as changed after the deletion was
    /// written to iCloud (`modifiedAt`).
    func hasUnsentLocalChange(_ sessionId: UUID, deletedAt: Date?) -> Bool {
        if manager.state.pendingUploadIds.contains(sessionId) { return true }
        if manager.archive.state.reuploadRequests.pending[sessionId] != nil { return true }
        guard let deletedAt, let modifiedAt = manager.archive.entryById(sessionId)?.modifiedAt else { return false }
        return modifiedAt > deletedAt
    }
}
