import CloudKit
import Foundation

// The push half of CloudKit sync. The manager's state, configuration and the
// full-sync orchestration that drives both halves live in
// `CloudKitSyncManager.swift`.

/// Failures specific to preparing a record for upload.
enum CloudSyncError: LocalizedError {
    /// The device key is unreachable, so the payload cannot be encrypted.
    ///
    /// Fail closed. Guideline 5.1.3(ii) forbids storing personal health
    /// information in iCloud, so a plaintext fallback would upload exactly
    /// what the rule prohibits. A skipped backup can be retried; an uploaded
    /// one cannot be recalled.
    case encryptionUnavailable

    /// Shown in Settings for both session and settings backups, so it names
    /// neither.
    var errorDescription: String? {
        switch self {
        case .encryptionUnavailable:
            return String(
                localized: "The encryption key is unavailable, and data is never uploaded to iCloud unencrypted.",
                bundle: LanguageManager.appBundle
            )
        }
    }
}

/// A session that is never uploaded. Not a failure: the push keeps it on
/// this device (`CloudKitSyncState.markLocalOnly`).
enum CloudUploadExclusion: Error {
    /// Read out of Apple Health whole (`CloudSessionPayload.isHealthKitSourced`).
    case healthKitSourced
    /// A sample night (`DemoSessionSeeder.isSampleData`). Its removal and the
    /// baseline it fed are this device's only, so in iCloud it would score
    /// other devices' nights against synthetic data nothing removes there.
    case sampleData
}

extension CloudKitSyncManager {
    // MARK: - Push (Upload Pending)

    // Cap the per-cycle push batch. Without it, a user who hits a
    // permanent server error (schema not promoted) builds up a queue of
    // 100+ pending sessions, and every sync cycle tries to push all of
    // them serially on the main actor — 10–50 s of MainActor work per cycle,
    // which the user perceives as the app "lagging a lot" with iCloud sync on.
    // Cap keeps each cycle bounded; the rest drain across cycles.
    private static let pushBatchLimit = 25

    /// Exponential-backoff ceiling: a session is never skipped for more than
    /// this many cycles in a row.
    nonisolated static let maxBackoffCycles = 32

    /// Advancing counter for the retry backoff.
    ///
    /// A deferral test built only from the session's UUID bucket and its
    /// failure count — both constant while an item is being skipped — never
    /// makes a deferred session eligible again. Something in
    /// the deferral test has to change between cycles; this is it.
    private static var pushCycleCounter = 0
    /// Shifting by more than this overflows before `maxBackoffCycles` can clamp
    /// the result.
    nonisolated static let maxBackoffExponent = 6

    // DESIGN NOTE on serial vs batched uploads.
    // CKModifyRecordsOperation would parallelise these saves into a single
    // network roundtrip, but it would also collapse per-session failure
    // handling (serverRecordChanged retry, the deleted-zone stop,
    // exponential backoff per session ID, schema-unavailable
    // circuit breaker) into a batch-level failure mode that's far harder to
    // recover from. The serial loop below intentionally keeps each save
    // independent so one bad record (e.g. malformed asset on disk) doesn't
    // poison the whole batch. The 25-record cap keeps the serial cost
    // bounded; the next cycle picks up where this one left off.
    //
    // The four decision blocks (batch selection, backoff, prep-failure
    // classification, zone recovery) are named functions rather than inline
    // so each is readable on its own.
    /// A zone found gone ends the cycle (`handleZoneGone`), and so does an
    /// account change: nothing more is uploaded once the signed-in account is
    /// no longer the confirmed one.
    ///
    /// The backoff counter advances on every cycle that gets this far, one
    /// whose whole batch is deferred included; advanced only after a
    /// non-empty batch, it froze while every pending session was deferred and
    /// none of them was ever tried again. Each session's turn counts as
    /// progress for the stall watchdog, failed or not.
    func pushPendingSessions() async {
        lastPushErrorMessage = nil
        guard cloudUploadsAllowed, !schemaUnavailable else { return }
        let pendingIds = pendingPushBatch()
        Self.pushCycleCounter &+= 1
        guard !pendingIds.isEmpty else { return }
        for sessionId in pendingIds {
            if schemaUnavailable || Task.isCancelled || !CloudAccountIdentity.isConfirmed { break }
            defer { noteSyncProgress() }
            guard let prepared = await prepareUpload(sessionId) else { continue }
            if await pushOne(prepared, sessionId: sessionId) {
                break
            }
        }
        await state.saveSyncStateAsync()
        await state.savePendingQueueAsync()
    }

    /// Heavyweight prep (retrieve + decrypt + encode + compress + temp
    /// file write) runs off MainActor. The MainActor only does the CK
    /// save itself (which is async and yields anyway). Without this,
    /// each iteration burned 50–300 ms of main-thread time on a
    /// backlog of 100+ sessions.
    private func prepareUpload(_ sessionId: UUID) async -> PreparedUpload? {
        do {
            guard let prepared = try await prepareUploadOffMain(sessionId: sessionId) else {
                // Gone from the archive (merged away, deduped, deleted): there
                // is nothing to upload, so it leaves the queue instead of
                // taking a batch slot every cycle.
                debugLog("[CloudKit] Push: session \(sessionId.uuidString.prefix(8)) is no longer in the archive — dropped from the queue")
                state.markDeleted(sessionId)
                return nil
            }
            return prepared
        } catch is CloudUploadExclusion {
            await keepOnDevice(sessionId)
            return nil
        } catch {
            await handlePrepFailure(error, sessionId: sessionId)
            return nil
        }
    }

    /// Save one prepared record. Returns true when the whole push cycle should
    /// stop (the zone is gone, the schema turned out to be unavailable, or the
    /// stall watchdog fired while the save ran); false continues with the next
    /// session.
    ///
    /// A save that returns after the watchdog fired marks nothing: the next
    /// sync already owns the state, and uploads the session again over its own
    /// record. Nor does one that returns once the account is no longer
    /// confirmed (sync stopped meanwhile, which reset the bookkeeping, or the
    /// account changed): the cycle ends, and the session is not marked
    /// uploaded into the reset state.
    ///
    /// The record's temp asset file is removed only once this session is done
    /// with — a conflict re-save reuses the same file.
    private func pushOne(_ prepared: PreparedUpload, sessionId: UUID) async -> Bool {
        defer { cleanupTempAsset(for: prepared.record) }
        do {
            let saved = try await privateDB.save(prepared.record)
            guard !Task.isCancelled, CloudAccountIdentity.isConfirmed else { return true }
            state.markUploaded(sessionId)
            state.noteRecordVersion(saved.recordChangeTag, of: sessionId)
            trashRestore.clear(sessionId)
        } catch let error as CKError where error.code == .serverRecordChanged {
            return await resolveConflict(error, prepared: prepared, sessionId: sessionId)
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            return await handleZoneGone(error, sessionId: sessionId)
        } catch {
            if Self.isPermanentSchemaError(error) {
                flagSchemaUnavailable(reason: error.localizedDescription)
                return true
            }
            state.markFailed(sessionId)
            CloudKitSessionFreshness.noteSaveFailure(error, uploading: sessionId)
        }
        return false
    }

    // MARK: - Push helpers

    /// Everything archived or explicitly queued, minus what is already
    /// uploaded or quarantined or sitting out its backoff, capped at
    /// `pushBatchLimit` for this cycle. Backoff is applied before the cap so a
    /// deferred session never takes a slot another could use.
    ///
    /// Quarantined ids are corrupt or newer-schema payloads that can never
    /// succeed; excluding them is what kills the per-cycle error spam.
    /// Local-only ids were read out of Apple Health and are never uploaded.
    private func pendingPushBatch() -> [UUID] {
        let allEntries = archive.entries
        let pendingIdsAll = Set(allEntries.map { $0.sessionId })
            .union(state.pendingUploadIds)
            .subtracting(state.uploadedSessionIds)
            .subtracting(state.quarantinedSessionIds)
            .subtracting(state.localOnlySessionIds)

        guard !pendingIdsAll.isEmpty else { return [] }

        let batch: [UUID] = Array(pendingIdsAll.filter { !shouldDeferForBackoff($0) }.prefix(Self.pushBatchLimit))
        if pendingIdsAll.count > Self.pushBatchLimit {
            debugLog("[CloudKit] Push: \(pendingIdsAll.count) pending, processing first \(Self.pushBatchLimit) this cycle")
        }
        return batch
    }

    /// Whether this session should sit out the current push cycle, read from
    /// its stored failure count, its stable bucket and the cycle counter.
    private func shouldDeferForBackoff(_ sessionId: UUID) -> Bool {
        Self.defersForBackoff(
            failCount: state.uploadFailureCounts[sessionId] ?? 0,
            bucket: Self.stableRetryBucket(for: sessionId),
            cycle: Self.pushCycleCounter
        )
    }

    /// Cycles between attempts for a session that has failed `failCount`
    /// times: 2^failCount, with the exponent capped before shifting (`1 << 64`
    /// is undefined) and the result capped at `maxBackoffCycles`.
    nonisolated static func backoffPeriod(failCount: Int) -> Int {
        min(1 << min(max(failCount, 0), maxBackoffExponent), maxBackoffCycles)
    }

    /// Whether a session defers on push cycle `cycle`.
    ///
    /// A session with no failures never defers. Otherwise it is tried once
    /// per backoff period, on the cycle where `(cycle + bucket) % period == 0`.
    /// The cycle counter is what makes a deferred session eligible again: the
    /// bucket and the failure count stay constant while it is skipped, so a
    /// test built from them alone would defer the same session forever. The
    /// bucket only spreads sessions that failed together across cycles.
    nonisolated static func defersForBackoff(failCount: Int, bucket: Int, cycle: Int) -> Bool {
        guard failCount > 0 else { return false }
        let period = backoffPeriod(failCount: failCount)
        return (cycle + bucket % period) % period != 0
    }

    /// Re-save a record that lost a revision race.
    ///
    /// `.serverRecordChanged` must not simply call
    /// `markUploaded`. That is wrong in the direction that loses data
    /// silently — CloudKit reports the conflict because the save did NOT
    /// happen, so the local state would say "uploaded" while the server kept the
    /// older contents. It mattered most where re-upload is the whole point:
    /// `forceReuploadSession` after a reanalysis, and the sanitation queue,
    /// both of which clear the uploaded marker precisely to overwrite an
    /// existing record.
    ///
    /// The error carries the server's record. Re-applying this device's fields
    /// onto it preserves the change tag, which is what lets the save succeed.
    /// Last writer wins, by edit time (`CloudKitSessionFreshness`): a server
    /// copy edited more recently on another device is not overwritten — the
    /// session counts as uploaded, and the pull imports the newer copy.
    ///
    /// The one exception is a deletion. A server record flagged deleted means
    /// the user removed the session on another device; copying this device's
    /// `isDeleted = 0` over it would bring the session back everywhere. The
    /// deletion wins and is applied here, the same way a pull applies it. A
    /// record marked kept on another device (`keptOnDeviceMarker`) is not
    /// overwritten either: the session counts as uploaded and the record stays
    /// a marker, as the pull leaves it.
    ///
    /// Shared by the batch push and the direct upload
    /// (`CloudKitSyncManager.resolveDirectConflict`), which persists the state
    /// afterwards. Always returns false: a conflict never stops the cycle. A
    /// re-save that returns after the stall watchdog fired marks nothing, as
    /// in `pushOne`. The server copy's edit stamp counts as seen
    /// (`CloudKitSessionFreshness.noteSeen`).
    func resolveConflict(
        _ error: CKError, prepared: PreparedUpload, sessionId: UUID
    ) async -> Bool {
        guard let serverRecord = error.serverRecord else {
            noteConflictUnresolved(sessionId, reason: "no server record in the error")
            return false
        }
        CloudKitSessionFreshness.noteSeen(CloudKitSessionFreshness.modifiedAt(of: serverRecord))
        let serverFlag = serverRecord["isDeleted"] as? Int64 ?? 0
        if serverFlag == 1, !trashRestore.isRestored(sessionId) {
            pull.applyDeletionMetDuringUpload(sessionId)
            return false
        }
        if serverFlag == Self.keptOnDeviceMarker {
            state.markUploaded(sessionId)
            return false
        }
        let restoring = trashRestore.isRestored(sessionId)
        guard CloudKitSessionFreshness.overwrite(serverRecord, with: prepared.record, restoring: restoring, yieldingIn: &state) else { return false }
        trashRestore.markIfReplacingTombstone(serverRecord, sessionId: sessionId)
        await saveResolved(serverRecord, sessionId: sessionId)
        return false
    }

    /// Save the server record with this device's fields on it. One that
    /// returns after the stall watchdog fired, or once the account is no
    /// longer confirmed, marks nothing.
    private func saveResolved(_ serverRecord: CKRecord, sessionId: UUID) async {
        do {
            let saved = try await privateDB.save(serverRecord)
            guard !Task.isCancelled, CloudAccountIdentity.isConfirmed else { return }
            state.markUploaded(sessionId)
            state.noteRecordVersion(saved.recordChangeTag, of: sessionId)
            trashRestore.clear(sessionId)
        } catch {
            noteConflictUnresolved(sessionId, reason: "\(error)", error: error)
        }
    }

    /// Leave the session pending after a conflict we could not resolve.
    ///
    /// Marked failed, never uploaded — the whole point of F2 is that a conflict
    /// is not a successful save. The backoff spaces the next attempt out rather
    /// than spinning against a device that is writing concurrently.
    private func noteConflictUnresolved(_ sessionId: UUID, reason: String, error: Error? = nil) {
        if let error { CloudKitSessionFreshness.noteSaveFailure(error) }
        state.markFailed(sessionId)
        debugLog("[CloudKit] Conflict unresolved for \(sessionId.uuidString.prefix(8)): \(reason)",
                 level: .error)
    }

    /// Distinguish PERMANENT prep failures from transient ones.
    ///
    /// A hash mismatch (corrupt file) or a newer-schema payload can NEVER be
    /// fixed by retrying, yet a blanket `markFailed` keeps the id in
    /// the pending set forever, re-throwing + re-logging the same integrity
    /// error every cycle (field log: session 6B275356 failed its hash on
    /// every sync).
    ///
    /// A hash mismatch is USUALLY a stale fingerprint on good data (an older
    /// write path rewrote the file without updating its hash — see
    /// `_retrieve`), not real corruption. Repair is attempted first: if the
    /// file still decodes to a valid session, refresh the fingerprint so it
    /// syncs normally — saving the night instead of holding it back. Only
    /// quarantine when it genuinely won't decode. (`.newerSchemaVersion`
    /// isn't a hash problem, so it skips repair and quarantines directly.)
    ///
    /// Quarantine stops re-attempts (kills the spam), leaves the file on disk
    /// untouched (reversible via `state.clearQuarantine`), and surfaces via
    /// `quarantinedCount` — no silent data loss.
    ///
    /// A transient failure is retried with backoff. One the user can see the
    /// cause of (`CloudSyncError`, the encryption key being unavailable) is
    /// also kept as `lastPushErrorMessage`, which ends the full sync as an
    /// error rather than "Up to date".
    private func handlePrepFailure(_ error: Error, sessionId: UUID) async {
        guard let archiveError = error as? SessionArchive.ArchiveError,
              archiveError.isPermanentUploadFailure
        else {
            state.markFailed(sessionId)
            if let syncError = error as? CloudSyncError { lastPushErrorMessage = syncError.localizedDescription }
            debugLog("[CloudKit] Push: prep failed for \(sessionId.uuidString.prefix(8)): \(error.localizedDescription)")
            return
        }
        switch hashRepair(for: archiveError, sessionId: sessionId) {
        case .repaired:
            // Reset backoff so the now-good file uploads next cycle.
            state.clearFailureCount(sessionId)
            debugLog("[CloudKit] Push: REPAIRED stale hash for \(sessionId.uuidString.prefix(8)) — file decoded fine; will re-attempt upload next cycle", level: .warning)
        case .notNow:
            state.markFailed(sessionId)
        case .undecodable:
            state.markQuarantined(sessionId)
            await state.saveQuarantineQueueAsync()
            debugLog("[CloudKit] Push: QUARANTINED \(sessionId.uuidString.prefix(8)) — permanent, undecodable prep failure (\(error.localizedDescription)); will not retry. File kept on disk.", level: .warning)
        }
    }

    /// A hash mismatch is repaired when the file still decodes, or left to a
    /// later retry while it cannot be read or decrypted (`.notNow`: a
    /// transient failure is never quarantined). Any other permanent failure
    /// (`.newerSchemaVersion`) is not a hash problem and counts as
    /// undecodable.
    private func hashRepair(for archiveError: SessionArchive.ArchiveError, sessionId: UUID) -> SessionArchive.HashRepair {
        guard case .hashMismatch = archiveError else { return .undecodable }
        return archive.repairSessionHashIfDecodable(sessionId: sessionId)
    }

    /// A session excluded from upload (`CloudUploadExclusion`: read out of
    /// Apple Health whole, or a sample night) stays on this device. One this
    /// device had uploaded or queued may have an iCloud copy from an earlier
    /// build; that copy's payload is removed and the record kept as a marker
    /// (`markKeptOnDevice`), not tombstoned, because a tombstone would delete
    /// the session on the user's other devices. The session is marked
    /// local-only once iCloud holds no payload of it; a failed write leaves it
    /// queued, and a later cycle tries again.
    private func keepOnDevice(_ sessionId: UUID) async {
        let mayBeInCloud = state.uploadedSessionIds.contains(sessionId) || state.pendingUploadIds.contains(sessionId)
        if mayBeInCloud {
            do {
                try await markKeptOnDevice(CKRecord.ID(recordName: sessionId.uuidString, zoneID: zoneID))
            } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
                debugLog("[CloudKit] Push: \(sessionId.uuidString.prefix(8)) has no iCloud copy to remove (\(error.code.rawValue))")
            } catch {
                state.markFailed(sessionId)
                debugLog("[CloudKit] Push: could not remove the iCloud copy of \(sessionId.uuidString.prefix(8)): \(error.localizedDescription)", level: .warning)
                return
            }
        }
        state.markLocalOnly(sessionId)
        await state.saveLocalOnlyAsync()
        debugLog("[CloudKit] Push: \(sessionId.uuidString.prefix(8)) is excluded from iCloud — kept on this device only")
    }

    /// `isDeleted` value of a record whose session is kept on one device: no
    /// payload, not a deletion. Every build reads a tombstone as
    /// `isDeleted == 1` only, so an older build sees a live record without a
    /// payload and skips it.
    nonisolated static let keptOnDeviceMarker: Int64 = 2

    /// Remove the payload of a session's record and mark it kept on device,
    /// rather than delete the record. Deleted outright, the record was missing
    /// from the next listings of every other device, and one that held a copy
    /// under the same id (a stub a rebuild replaced here) uploaded it back
    /// (`reuploadSessionsMissingFromCloud`). Listed with this marker, it is
    /// left alone by the pull and counts as present. Fetched without its
    /// payload; throws `.unknownItem` when there is no record.
    func markKeptOnDevice(_ recordID: CKRecord.ID) async throws {
        let fetched = try await privateDB.records(for: [recordID], desiredKeys: ["isDeleted"])
        guard let record = try fetched[recordID]?.get() else { throw CKError(.unknownItem) }
        record["isDeleted"] = Self.keptOnDeviceMarker as CKRecordValue
        record["sessionData"] = nil
        _ = try await privateDB.save(record)
    }

    /// Zone gone server-side: the app's iCloud data was deleted (Delete All My
    /// Data on another device, or the iCloud settings), or the account
    /// changed. Recreating the zone and uploading into it undid the deletion,
    /// so the cycle ends here and `CloudAccountGuard.zoneWasDeleted` stops
    /// sync for the user to opt in again. When the account cannot be checked,
    /// the session stays queued and the reason ends the sync as an error.
    /// Always `true`: every remaining push would meet the same zone.
    private func handleZoneGone(_ error: CKError, sessionId: UUID) async -> Bool {
        debugLog("[CloudKit] Push: zone gone (\(error.code.rawValue)) — iCloud data was deleted, or the account changed", level: .warning)
        if let message = await accountGuard.zoneWasDeleted() {
            state.markFailed(sessionId)
            lastPushErrorMessage = message
        }
        return true
    }

    /// Stable retry-spreading bucket derived from the UUID's own bytes —
    /// unlike `hashValue`, identical across launches, so a session's place in
    /// the retry spread does not reshuffle at each launch. The failure counts
    /// themselves are kept in memory only (`CloudKitSyncState`), so every
    /// backoff starts over when the app is relaunched.
    nonisolated static func stableRetryBucket(for id: UUID) -> Int {
        let b = id.uuid
        return Int(b.0) | (Int(b.1) << 8) | (Int(b.2) << 16)
    }

    /// Bundle of everything needed to call `privateDB.save(record)`.
    struct PreparedUpload: Sendable {
        let record: CKRecord
    }

    /// Move the expensive part of upload prep off the main actor.
    /// Returns nil only when the session cannot be retrieved (e.g., deleted
    /// between scheduling and execution). Throws on encode/encrypt errors.
    func prepareUploadOffMain(sessionId: UUID) async throws -> PreparedUpload? {
        let archive = self.archive
        let zoneID = self.zoneID
        let recordTypeName = self.recordType
        return try await Task.detached(priority: .utility) { () -> PreparedUpload? in
            guard let session = try archive.retrieve(sessionId) else { return nil }
            let record = try Self.buildSessionRecord(from: session, zoneID: zoneID, recordTypeName: recordTypeName)
            return PreparedUpload(record: record)
        }.value
    }

    /// Off-main version of `createRecord(from:)`. Pure compute + temp file
    /// write, no actor-isolated state read. Marked `nonisolated` so it
    /// can run from a detached task without main-actor hops.
    ///
    /// Throws `CloudUploadExclusion` for a session read out of Apple Health
    /// whole, or a sample night: this is the one builder every upload goes
    /// through, so the refusal here covers every path.
    nonisolated static func buildSessionRecord(from session: HRVSession, zoneID: CKRecordZone.ID, recordTypeName: String) throws -> CKRecord {
        guard !CloudSessionPayload.isHealthKitSourced(session) else { throw CloudUploadExclusion.healthKitSourced }
        guard !DemoSessionSeeder.isSampleData(session.tags) else { throw CloudUploadExclusion.sampleData }
        let recordID = CKRecord.ID(recordName: session.id.uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: recordTypeName, recordID: recordID)
        record["sessionId"] = session.id.uuidString as CKRecordValue
        record["startDate"] = session.startDate as CKRecordValue
        record["isDeleted"] = 0 as CKRecordValue
        CloudKitSessionFreshness.stampRecord(record, from: session)
        // `recoveryScore`, `meanRMSSD` and `sessionType` are deliberately NOT
        // written as plaintext CKRecord fields. Nothing reads them back — the
        // pull path re-derives them from the payload — so they would be health information
        // published to iCloud for no functional gain.
        record["sessionData"] = try sessionAsset(for: session)
        return record
    }

    /// The session's payload as a record carries it: without its HealthKit
    /// readings, compressed and encrypted, in a protected temp file that
    /// `cleanupTempAsset` removes after the save.
    nonisolated static func sessionAsset(for session: HRVSession) throws -> CKAsset {
        CKAsset(fileURL: try writeAssetFile(try compressedPayload(for: session), sessionId: session.id))
    }

    /// What the (encrypted) session payload contains: the session without
    /// anything read from HealthKit and without the auto-window comparison
    /// (`CloudSessionPayload.uploadable` lists what stays behind).
    ///
    /// What does go up is still health data — the strap's `rrSeries`, the
    /// app's analysis and scores (`analysisResult`, `recoveryScore`,
    /// `frozenReadiness`, `hrvDataQuality`, the score breakdown's sub-scores),
    /// the app's training-load figures, a workout's GPS track and per-second
    /// samples, `tags`, `notes` and the morning feeling. What keeps it out of
    /// reach is the encryption in `CloudPayloadCodec.sealForUpload`, not this
    /// function.
    nonisolated private static func compressedPayload(for session: HRVSession) throws -> Data {
        let sanitized = CloudSessionPayload.uploadable(session)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        let compressed = try DataCompression.compress(try encoder.encode(sanitized))
        return try CloudPayloadCodec.sealForUpload(compressed)
    }

    /// The CKAsset temp file, deleted right after the save
    /// (`cleanupTempAsset`). Its bytes are already sealed
    /// (`compressedPayload`). The class is until-first-unlock, not complete:
    /// a sync running in the background while the device is locked must
    /// still be able to read the file to upload it.
    nonisolated private static func writeAssetFile(_ compressedData: Data, sessionId: UUID) throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck_\(sessionId.uuidString)_\(UUID().uuidString.prefix(8))")
            .appendingPathExtension("gz")
        try compressedData.write(to: tempURL, options: [.completeFileProtectionUntilFirstUserAuthentication])
        return tempURL
    }

    // MARK: - Zone Management

    /// Create the session zone unless this device already has. Only for the
    /// confirmed account (`CloudAccountIdentity.isConfirmed`): a zone is never
    /// created in another Apple ID's iCloud; otherwise it throws
    /// `CloudAccountGuard.Halt.stopped`.
    func ensureZoneExists() async throws {
        guard !zoneCreated else { return }
        guard CloudAccountIdentity.isConfirmed else { throw CloudAccountGuard.Halt.stopped }

        let zone = CKRecordZone(zoneID: zoneID)
        do {
            try await privateDB.save(zone)
            zoneCreated = true
        } catch let error as CKError where error.code == .serverRejectedRequest {
            // Usually the zone already exists. Confirmed by fetching it before
            // it counts as created; a fetch that fails throws, so a refused
            // zone is not reported as recreated.
            _ = try await privateDB.recordZone(for: zoneID)
            debugLog("[CloudKit] Zone save rejected (\(error.code.rawValue)) but the zone exists")
            zoneCreated = true
        }
    }

    // MARK: - Record Creation

    // `buildSessionRecord` is the single source of truth for the CK payload.
    // A second builder is how records ship without the Guideline 5.1.3
    // HealthKit strip (`CloudSessionPayload`); don't add one.

    /// Remove the temp file backing a CKAsset after the record has been saved.
    func cleanupTempAsset(for record: CKRecord) {
        guard let asset = record["sessionData"] as? CKAsset,
              let url = asset.fileURL else { return }
        removeTempFileIfNeeded(at: url, context: "session asset cleanup")
    }

    // MARK: - Live Backup (Delegated)

    func uploadLiveBackup(sessionId: UUID, points: [RRPoint], deviceId: String?, force: Bool = false) async {
        await liveBackup.upload(sessionId: sessionId, points: points, deviceId: deviceId, force: force)
    }

    func deleteLiveBackup(sessionId: UUID) async {
        await liveBackup.delete(sessionId: sessionId)
    }

    func fetchLiveBackups() async -> [LiveBackupSummary] {
        await liveBackup.fetchAll()
    }

    // MARK: - Helpers

    func removeTempFileIfNeeded(at url: URL, context: String) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let nsError as NSError where nsError.domain == NSCocoaErrorDomain &&
                                            nsError.code == NSFileNoSuchFileError {
            // Already gone; no action needed.
        } catch {
            debugLog("[CloudKit] Failed \(context): \(error)")
        }
    }

    // MARK: - Error Helpers

    func cloudKitErrorMessage(_ error: Error) -> String {
        guard let ckError = error as? CKError else { return error.localizedDescription }
        switch ckError.code {
        case .networkFailure, .networkUnavailable: return CloudSyncMessages.noInternet
        case .quotaExceeded: return CloudSyncMessages.storageFull
        case .notAuthenticated: return CloudSyncMessages.notSignedIn
        case .requestRateLimited:
            return CloudSyncMessages.rateLimited(retryAfter: ckError.userInfo[CKErrorRetryAfterKey] as? Double)
        default:
            return ckError.localizedDescription
        }
    }

    /// Race an async operation against a timeout. Returns
    /// `.success(value)` if the operation finished first, `.failure(error)`
    /// if the operation threw, `.failure(SyncTimeoutError.timedOut)` if
    /// the sleep won the race. Used to cap the remote delete
    /// (`CloudDeletionCoordinator.performDeleteAllRemoteData`) so a wedged
    /// CloudKit call can't hold it; the full sync uses the no-progress
    /// `withProgressWatchdog` instead. `runWithTimeout`
    /// returns without awaiting the loser, so a call that ignores
    /// cancellation cannot hold it past the deadline.
    func withTimeoutResult<T: Sendable>(
        seconds: TimeInterval,
        operation: @Sendable @escaping () async throws -> T
    ) async -> Result<T, Error> {
        await runWithTimeout(seconds: seconds) { await Self.captured(operation) } ?? .failure(SyncTimeoutError.timedOut)
    }

    /// Race `operation` against a NO-PROGRESS watchdog. Fails ONLY if no progress
    /// has been reported via `noteSyncProgress()` for `stuckAfter` seconds — a
    /// genuinely wedged CloudKit call — never a slow-but-progressing sync. Unlike
    /// a fixed wall-clock deadline on the whole body, the
    /// watchdog resets every time a record is pushed / a page is pulled / a remote
    /// record is processed, so a sync that legitimately takes minutes on a slow
    /// network runs to completion.
    ///
    /// Not a task group: a group waits for every child before returning, so a
    /// wedged call that ignores cancellation held the sync even after the
    /// watchdog fired. The first result resumes the caller; the operation is
    /// then cancelled and left to finish on its own.
    func withProgressWatchdog<T: Sendable>(
        stuckAfter: TimeInterval,
        operation: @Sendable @escaping () async throws -> T
    ) async -> Result<T, Error> {
        lastSyncProgressAt = Date() // on the MainActor here
        let raced: Result<T, Error>? = await withCheckedContinuation { continuation in
            let gate = FirstResultGate(continuation)
            let work = Task { gate.resume(await Self.captured(operation)) }
            Task { [weak self] in
                await self?.awaitProgressStall(stuckAfter: stuckAfter, unlessResolved: gate)
                gate.resume(.failure(SyncTimeoutError.stalled))
                work.cancel()
            }
        }
        return raced ?? .failure(SyncTimeoutError.stalled)
    }

    /// Run the operation, folding a throw into the Result rather than
    /// propagating it out of the task group.
    private static func captured<T: Sendable>(
        _ operation: @Sendable @escaping () async throws -> T
    ) async -> Result<T, Error> {
        do { return try .success(await operation()) } catch { return .failure(error) }
    }

    /// Polls every 5 s and returns once progress has been silent for
    /// `stuckAfter`, or once `gate` holds a result (the operation finished).
    private func awaitProgressStall<T: Sendable>(stuckAfter: TimeInterval, unlessResolved gate: FirstResultGate<T>) async {
        while !Task.isCancelled, !gate.isResolved {
            await sleepQuietly(5_000_000_000, context: "awaitProgressStall") // poll every 5s
            if Date().timeIntervalSince(lastSyncProgressAt) > stuckAfter { return }
        }
    }
}
