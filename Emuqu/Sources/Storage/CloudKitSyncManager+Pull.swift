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
        /// Ids of sessions archived NEW by this pull, handed to
        /// the HK sleep/vitals backfill below.
        var newlyArchivedIds: [UUID] = []
    }

    func pullRemoteChanges() async {
        manager.lastPullErrorMessage = nil
        do {
            let results = try await fetchAllRemoteRecords()
            let counts = await processRemoteRecords(results)
            await manager.state.saveSyncStateAsync()
            if counts.newSessions > 0 {
                await runPostPullBackfills(counts)
            }
            if counts.newSessions > 0 || counts.deleted > 0 {
                manager.pullVersion += 1
            }
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            await handleMissingZone(error)
        } catch {
            handlePullFailure(error)
        }
    }

    /// Query CloudKit for all sessions. Uses `startDate > 0` instead of
    /// TRUEPREDICATE because CloudKit custom zones require a queryable indexed
    /// field in the predicate, and paginates because CloudKit returns only
    /// ~200-400 per batch.
    private func fetchAllRemoteRecords() async throws -> [(CKRecord.ID, Result<CKRecord, Error>)] {
        let query = CKQuery(recordType: manager.recordType, predicate: NSPredicate(format: "startDate > %@", NSDate(timeIntervalSince1970: 0)))
        query.sortDescriptors = [NSSortDescriptor(key: "startDate", ascending: false)]
        var allResults: [(CKRecord.ID, Result<CKRecord, Error>)] = []
        var (pageResults, cursor) = try await manager.privateDB.records(
            matching: query,
            inZoneWith: manager.zoneID,
            resultsLimit: CKQueryOperation.maximumResults
        )
        allResults.append(contentsOf: pageResults)
        manager.noteSyncProgress() // pulled a page — sync is advancing
        while let nextCursor = cursor {
            let (moreResults, nextNext) = try await manager.privateDB.records(
                continuingMatchFrom: nextCursor,
                resultsLimit: CKQueryOperation.maximumResults
            )
            allResults.append(contentsOf: moreResults)
            cursor = nextNext
            manager.noteSyncProgress() // pulled another page — still advancing
        }
        return allResults
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
            guard case .success(let record) = result else { continue }
            let recordCounts = await processRemoteRecord(record)
            manager.noteSyncProgress() // processed a remote record — sync is advancing
            counts.newSessions += recordCounts.new
            counts.deleted += recordCounts.deleted
            if let id = recordCounts.archivedId { counts.newlyArchivedIds.append(id) }
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
        guard !counts.newlyArchivedIds.isEmpty else { return }
        NotificationCenter.default.post(
            name: .cloudKitSnapshotBackfillNeeded,
            object: nil,
            userInfo: ["sessionIds": counts.newlyArchivedIds]
        )
    }

    /// Zone gone server-side — recreate and try once more. After recreating an
    /// empty zone there's nothing to pull yet; the next push cycle populates
    /// it with locally-pending sessions.
    private func handleMissingZone(_ error: CKError) async {
        debugLog("[CloudKit] Pull: zone gone (\(error.code.rawValue)) — attempting recreation", level: .warning)
        if await manager.recreateZoneAfterNotFound() {
            debugLog("[CloudKit] Pull: zone recreated — sessions will sync up on next cycle", level: .info)
        } else {
            debugLog("[CloudKit] Pull: zone recreation failed", level: .error)
            manager.lastPullErrorMessage = "iCloud pull failed: sync zone could not be recreated."
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

    /// Process a single remote CloudKit record: handle soft-deletes, skip duplicates, archive new sessions.
    /// Cheap guards run on the main actor; the expensive asset read + decompress +
    /// JSON decode runs in a detached utility task (see comment at the decode site).
    ///
    /// `archivedId` reports the session id when this record was
    /// archived as a NEW session, so `pullRemoteChanges` can hand it to the
    /// HK sleep/vitals backfill (synced past sessions arrive with the
    /// HK-derived snapshots stripped per Guideline 5.1.3 and must be
    /// re-derived locally). nil for skips, duplicates, and deletes.
    func processRemoteRecord(_ record: CKRecord) async -> (new: Int, deleted: Int, archivedId: UUID?) {
        let sessionIdString = record.recordID.recordName
        guard let sessionId = UUID(uuidString: sessionIdString) else { return (0, 0, nil) }
        // Handle soft-deleted records
        if (record["isDeleted"] as? Int64 ?? 0) == 1 {
            let counts = handleDeletedRecord(sessionId: sessionId, sessionIdString: sessionIdString)
            return (counts.new, counts.deleted, nil)
        }
        // Skip if we already have this session, or if it was intentionally
        // deleted locally (prevents re-downloading sessions the user removed).
        guard !manager.archive.exists(sessionId), !manager.archive.wasIntentionallyDeleted(sessionId) else {
            manager.state.markUploaded(sessionId)
            return (0, 0, nil)
        }
        guard let asset = record["sessionData"] as? CKAsset,
              let assetURL = asset.fileURL else {
            debugLog("[CloudKit] Pull: No asset data for \(sessionIdString.prefix(8))")
            return (0, 0, nil)
        }
        return await importPulledSession(from: assetURL, sessionId: sessionId, sessionIdString: sessionIdString)
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
    private func importPulledSession(
        from assetURL: URL, sessionId: UUID, sessionIdString: String
    ) async -> (new: Int, deleted: Int, archivedId: UUID?) {
        do {
            let session = try await Task.detached(priority: .utility) {
                try Self.decodeSessionAsset(at: assetURL)
            }.value
            try manager.archive.archive(session, skipSameNightMerge: true)
            manager.state.markUploaded(sessionId)
            return (1, 0, sessionId)
        } catch {
            manager.lastPullErrorMessage = "iCloud pull: \(sessionIdString.prefix(8))… failed to import (\(error.localizedDescription))"
            debugLog("[CloudKit] Pull: Failed to process \(sessionIdString.prefix(8)): \(error.localizedDescription)", level: .warning)
            return (0, 0, nil)
        }
    }

    /// JSONDecoder is not Sendable — a fresh one is built here, inside the
    /// detached closure, rather than captured across the actor boundary.
    nonisolated private static func decodeSessionAsset(at assetURL: URL) throws -> HRVSession {
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

    /// Handle a soft-deleted remote record by deleting the local copy if it exists
    func handleDeletedRecord(sessionId: UUID, sessionIdString: String) -> (new: Int, deleted: Int) {
        var deletedCount = 0
        if manager.archive.exists(sessionId) {
            do {
                try manager.archive.delete(sessionId)
                deletedCount = 1
            } catch {
                debugLog("[CloudKit] Pull: Failed to delete local session \(sessionIdString.prefix(8)): \(error)")
            }
        }
        manager.state.markRemoved(sessionId)
        return (0, deletedCount)
    }
}
