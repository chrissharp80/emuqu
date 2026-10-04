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
    }

    func pullRemoteChanges() async {
        manager.lastPullErrorMessage = nil
        do {
            let results = try await fetchAllRemoteRecords()
            let counts = await processRemoteRecords(results)
            guard !Task.isCancelled else { return } // stall watchdog: partial pull, the next sync redoes it
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
    /// listing does not contain goes back in the upload queue. That is what an
    /// emptied zone or a switched Apple ID looks like from here, and nothing
    /// else ever noticed: the archive stayed out of iCloud while Settings said
    /// everything was synced. Only after a listing with no per-record errors —
    /// a partial answer would re-upload sessions that are there — and only
    /// for a session missing from this listing and the one before it
    /// (`missingFromLastListing`): a record saved seconds ago by the push can
    /// be absent from a listing whose query index has not caught up yet.
    private func reuploadSessionsMissingFromCloud(_ results: [(CKRecord.ID, Result<CKRecord, Error>)]) {
        guard results.allSatisfy({ if case .success = $0.1 { true } else { false } }) else { return }
        let remoteIds = Set(results.compactMap { UUID(uuidString: $0.0.recordName) })
        let missing = manager.state.uploadedSessionIds.filter {
            !remoteIds.contains($0) && manager.archive.exists($0) && !manager.archive.wasIntentionallyDeleted($0)
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
    private func processRemoteRecords(
        _ results: [(CKRecord.ID, Result<CKRecord, Error>)]
    ) async -> PullCounts {
        var counts = PullCounts()
        for (_, result) in results {
            if Task.isCancelled { break }
            guard case .success(let record) = result else { continue }
            let outcome = await processRemoteRecord(record)
            manager.noteSyncProgress() // processed a remote record — sync is advancing
            counts.newSessions += outcome.new
            counts.deleted += outcome.deleted
            counts.refreshed += outcome.refreshed
            if let id = outcome.backfillId { counts.backfillIds.append(id) }
        }
        return counts
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
    /// and is gated to today, so every synced PAST session stayed blank until
    /// manually opened. Hand the ids to RRCollector (it owns `healthKit` + the
    /// bounded backfill helper) via a decoupled notification; the backfill
    /// drips a few per cycle at low priority and respects `sleepUserAdjusted`.
    private func runPostPullBackfills(_ counts: PullCounts) async {
        // Hoisted so the detached closure captures the archive, not `self`.
        let archive = manager.archive
        await Task.detached(priority: .utility) {
            archive.runDeferredMigrations()
        }.value
        guard !counts.backfillIds.isEmpty else { return }
        NotificationCenter.default.post(
            name: .cloudKitSnapshotBackfillNeeded,
            object: nil,
            userInfo: ["sessionIds": counts.backfillIds]
        )
    }

    /// Zone gone server-side — recreate and try once more. After recreating an
    /// empty zone there's nothing to pull yet, and every session this device
    /// believed uploaded went with the old zone: they are queued again so the
    /// next push repopulates it.
    private func handleMissingZone(_ error: CKError) async {
        debugLog("[CloudKit] Pull: zone gone (\(error.code.rawValue)) — attempting recreation", level: .warning)
        if await manager.recreateZoneAfterNotFound() {
            let uploaded = manager.state.uploadedSessionIds
            for id in uploaded { manager.state.markRemoved(id) }
            await manager.state.saveSyncStateAsync()
            await manager.state.savePendingQueueAsync()
            debugLog("[CloudKit] Pull: zone recreated — \(uploaded.count) session(s) queued to upload on next cycle", level: .info)
        } else {
            debugLog("[CloudKit] Pull: zone recreation failed", level: .error)
            manager.lastPullErrorMessage = String(localized: "iCloud pull failed: sync zone could not be recreated.", bundle: LanguageManager.appBundle)
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
    /// new sessions, and replace a held copy only with a newer one.
    /// Cheap guards run on the main actor; the expensive asset read + decompress +
    /// JSON decode runs in a detached utility task (see comment at the decode site).
    ///
    /// `backfillId` reports the session id when this record was
    /// archived as a NEW session, so `pullRemoteChanges` can hand it to the
    /// HK sleep/vitals backfill (synced past sessions arrive with the
    /// HK-derived snapshots stripped per Guideline 5.1.3 and must be
    /// re-derived locally). nil for skips and deletes.
    func processRemoteRecord(_ record: CKRecord) async -> RecordOutcome {
        let sessionIdString = record.recordID.recordName
        guard let sessionId = UUID(uuidString: sessionIdString) else { return RecordOutcome() }
        // Handle soft-deleted records — except one this device restored from
        // the Trash and has not uploaded yet: its upload overrides the
        // tombstone, and deleting it here undid the restore.
        if (record["isDeleted"] as? Int64 ?? 0) == 1, !manager.trashRestore.isRestored(sessionId) {
            let counts = handleDeletedRecord(sessionId: sessionId, sessionIdString: sessionIdString)
            return RecordOutcome(new: counts.new, deleted: counts.deleted)
        }
        guard !isKnownLocally(sessionId) else { return await refreshIfRemoteIsNewer(record, sessionId: sessionId) }
        guard let assetURL = await assetURL(for: record) else { return RecordOutcome() }
        return await importPulledSession(from: assetURL, sessionId: sessionId, sessionIdString: sessionIdString)
    }

    /// The local file of the record's backup, fetching the full record when
    /// the listing left it out; nil, logged, when there is none.
    func assetURL(for record: CKRecord) async -> URL? {
        guard let full = await recordWithAsset(record),
              let asset = full["sessionData"] as? CKAsset,
              let assetURL = asset.fileURL else {
            debugLog("[CloudKit] Pull: No asset data for \(record.recordID.recordName.prefix(8))")
            return nil
        }
        return assetURL
    }

    /// The record with its backup file. A listed record carries only
    /// `listingKeys`, so the full one is fetched; nil, with the failure
    /// reported, when that fetch fails.
    private func recordWithAsset(_ record: CKRecord) async -> CKRecord? {
        if record["sessionData"] is CKAsset { return record }
        do {
            return try await manager.privateDB.record(for: record.recordID)
        } catch {
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
    private func isKnownLocally(_ sessionId: UUID) -> Bool {
        guard manager.archive.exists(sessionId) || manager.archive.wasIntentionallyDeleted(sessionId) else {
            return false
        }
        if !manager.state.pendingUploadIds.contains(sessionId) {
            manager.state.markUploaded(sessionId)
        }
        return true
    }

    /// Asset read + decompress + JSON decode run off
    /// the main actor (a
    /// 30k-point rrSeries decode per record, repeated for every
    /// pulled record in one uninterrupted MainActor slice, froze
    /// launch/foreground). Only `assetURL` (URL, Sendable) crosses
    /// into the detached task; only the decoded `HRVSession`
    /// (Sendable value struct) crosses back.
    ///
    /// CloudKit-pulled sessions are the authoritative
    /// cross-device-merged version of their session id. Folding
    /// them into a local same-night entry is double-merging AND
    /// catastrophically slow under load (user log showed 37
    /// merges in 5 s on a single launch — each one a full
    /// retrieve + decrypt + decode + merge + encode + encrypt +
    /// write + SHA256 + index save, all on main thread under
    /// archiveLock). The merge is skipped here; the existing
    /// `removeDuplicates` migration handles genuine stale-night
    /// cleanup after the 24-hour safety window.
    ///
    /// NOTE: `archive.archive` (encode + encrypt + write under archiveLock)
    /// still runs on the main actor — bounded per record; the archive-side fix
    /// is the SessionFileCodec path.
    ///
    /// Per-record failures are surfaced instead of only
    /// debug-logged. The record IS retried on the next pull (it stays
    /// un-marked, and the query returns everything), but a record that fails
    /// deterministically (corrupt asset, future-schema payload) would fail
    /// forever while Settings showed "Up to date". Recording it here makes the
    /// sync body report `.error` and skip the lastSyncDate stamp.
    ///
    /// A record sealed with a key this device does not hold yet — another
    /// device's, still travelling through iCloud Keychain — is not a failure:
    /// it stays un-imported and the next pull, once the key has arrived,
    /// imports it. Reporting it as an error would withhold the sync stamp and
    /// re-run the full pull on every activation until then.
    ///
    /// A record saved by a newer app version is skipped the same way: this
    /// build refuses to write it, and an error would keep sync failing on
    /// every pull until the app is updated.
    private func importPulledSession(
        from assetURL: URL, sessionId: UUID, sessionIdString: String
    ) async -> RecordOutcome {
        do {
            let session = try await Task.detached(priority: .utility) {
                try Self.decodeSessionAsset(at: assetURL)
            }.value
            try manager.archive.archive(session, skipSameNightMerge: true)
            manager.state.markUploaded(sessionId)
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
        } else if let archiveError = error as? SessionArchive.ArchiveError,
                  case .newerSchemaVersion(let version) = archiveError {
            debugLog("[CloudKit] Pull: \(sessionIdString.prefix(8)) is from a newer app version (schema v\(version)) — skipped until the app is updated", level: .warning)
        } else {
            manager.lastPullErrorMessage = String(localized: "A session from iCloud couldn't be imported: \(error.localizedDescription)", bundle: LanguageManager.appBundle)
            debugLog("[CloudKit] Pull: Failed to process \(sessionIdString.prefix(8)): \(error.localizedDescription)", level: .warning)
        }
        return RecordOutcome()
    }

    /// JSONDecoder is not Sendable — a fresh one is built here, inside the
    /// detached closure, rather than captured across the actor boundary.
    nonisolated static func decodeSessionAsset(at assetURL: URL) throws -> HRVSession {
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
        let decrypted = try CloudPayloadCodec.decode(compressedData)
        let jsonData = try DataCompression.decompress(decrypted)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(HRVSession.self, from: jsonData)
    }

    /// Deleted on another device. Copying this device's `isDeleted = 0` over
    /// the tombstone brought the session back everywhere, so on a conflict
    /// with a tombstone — batch push or direct upload — the deletion wins and
    /// is applied here, the same way a pull applies it.
    func applyDeletionMetDuringUpload(_ sessionId: UUID) {
        let counts = handleDeletedRecord(sessionId: sessionId, sessionIdString: sessionId.uuidString)
        if counts.deleted > 0 { manager.pullVersion += 1 }
        debugLog("[CloudKit] Upload of \(sessionId.uuidString.prefix(8)) met a deletion from another device — applying it")
    }

    /// Handle a soft-deleted remote record by deleting the local copy if it exists.
    /// The copy is not kept in this device's Trash: the deletion was made, and
    /// can be undone or made final, on the other device. Kept here, a session
    /// deleted for good there could be restored here.
    func handleDeletedRecord(sessionId: UUID, sessionIdString: String) -> (new: Int, deleted: Int) {
        var deletedCount = 0
        if manager.archive.exists(sessionId) {
            do {
                try manager.archive.delete(sessionId)
                manager.archive.discardTrashed(sessionId)
                deletedCount = 1
            } catch {
                debugLog("[CloudKit] Pull: Failed to delete local session \(sessionIdString.prefix(8)): \(error)")
            }
        }
        manager.state.markDeleted(sessionId)
        return (0, deletedCount)
    }
}
