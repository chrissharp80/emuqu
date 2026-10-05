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
    private static let maxBackoffCycles = 32

    /// Advancing counter for the retry backoff.
    ///
    /// A deferral test built only from the session's UUID bucket and its
    /// failure count — both constant while an item is being skipped — never
    /// makes a deferred session eligible again. Something in
    /// the deferral test has to change between cycles; this is it.
    private static var pushCycleCounter = 0
    /// Shifting by more than this overflows before `maxBackoffCycles` can clamp
    /// the result.
    private static let maxBackoffExponent = 6

    // DESIGN NOTE on serial vs batched uploads.
    // CKModifyRecordsOperation would parallelise these saves into a single
    // network roundtrip, but it would also collapse per-session failure
    // handling (serverRecordChanged retry, zone-not-found single-shot
    // recreation, exponential backoff per session ID, schema-unavailable
    // circuit breaker) into a batch-level failure mode that's far harder to
    // recover from. The serial loop below intentionally keeps each save
    // independent so one bad record (e.g. malformed asset on disk) doesn't
    // poison the whole batch. The 25-record cap keeps the serial cost
    // bounded; the next cycle picks up where this one left off.
    //
    // The four decision blocks (batch selection, backoff, prep-failure
    // classification, zone recovery) are named functions rather than inline
    // so each is readable on its own.
    /// `zoneNotFoundEncountered` tracks consecutive zone-not-found failures so
    /// we attempt ONE zone recreation per sync cycle, not once per session — a
    /// single zoneNotFound from session A means the entire batch will fail, so
    /// recreate and then retry the loop.
    func pushPendingSessions() async {
        guard cloudUploadsAllowed else { return }
        guard !schemaUnavailable else { return }
        let pendingIds = pendingPushBatch()
        guard !pendingIds.isEmpty else { return }
        var zoneNotFoundEncountered = false
        for sessionId in pendingIds {
            if schemaUnavailable || Task.isCancelled { break }
            guard let prepared = await prepareUpload(sessionId) else { continue }
            if await pushOne(prepared, sessionId: sessionId, zoneNotFound: &zoneNotFoundEncountered) {
                break
            }
        }
        Self.pushCycleCounter &+= 1
        state.saveSyncState()
        state.savePendingQueue()
        if zoneNotFoundEncountered {
            debugLog("[CloudKit] Push cycle hit zoneNotFound at least once — recreation handled inline", level: .info)
        }
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
    /// stop (zone recreated, or the schema turned out to be unavailable); false
    /// continues with the next session.
    ///
    /// The record's temp asset file is removed only once this session is done
    /// with — a conflict re-save reuses the same file.
    private func pushOne(
        _ prepared: PreparedUpload, sessionId: UUID, zoneNotFound: inout Bool
    ) async -> Bool {
        defer { cleanupTempAsset(for: prepared.record) }
        do {
            try await privateDB.save(prepared.record)
            state.markUploaded(sessionId)
            trashRestore.clear(sessionId)
            noteSyncProgress()
        } catch let error as CKError where error.code == .serverRecordChanged {
            return await resolveConflict(error, prepared: prepared, sessionId: sessionId)
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            zoneNotFound = true
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

    /// Whether this session is still inside its exponential-backoff window.
    ///
    /// Skips every 2^failCount cycles (capped). The spread uses a STABLE
    /// per-id value, not `sessionId.hashValue`, which is
    /// randomly seeded per process launch, so the schedule would reshuffle on
    /// every launch and a session could be unlucky across many launches in a
    /// row. The UUID's own bytes are stable forever.
    /// Whether this session should sit out the current push cycle.
    ///
    /// Not simply
    /// `stableRetryBucket(id) % skipCycles != 0`: both operands are constant
    /// while an item is being skipped — the bucket is derived from the UUID and
    /// the failure count only changes on an *attempt* — so a session that
    /// deferred once would defer on every subsequent cycle for the life of the
    /// process, and a backup pending its first upload would never retry, even
    /// after the network came back. UUID `01000000-…` gives bucket 1: after one
    /// failure the test is `1 % 2 != 0`, true, forever.
    ///
    /// The cycle counter is what makes it advance. The bucket stays in the
    /// expression as deterministic jitter so a hundred sessions failing
    /// together do not all retry on the same cycle, but it can no longer decide
    /// the outcome on its own.
    private func shouldDeferForBackoff(_ sessionId: UUID) -> Bool {
        let failCount = state.uploadFailureCounts[sessionId] ?? 0
        guard failCount > 0 else { return false }
        // Cap the EXPONENT, not the result: `1 << 64` is undefined, and a
        // session that fails often enough would otherwise shift past Int width.
        let exponent = min(failCount, Self.maxBackoffExponent)
        let period = min(1 << exponent, Self.maxBackoffCycles)
        let offset = Self.stableRetryBucket(for: sessionId) % period
        return (Self.pushCycleCounter + offset) % period != 0
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
    /// deletion wins and is applied here, the same way a pull applies it.
    private func resolveConflict(
        _ error: CKError, prepared: PreparedUpload, sessionId: UUID
    ) async -> Bool {
        guard let serverRecord = error.serverRecord else {
            noteConflictUnresolved(sessionId, reason: "no server record in the error")
            return false
        }
        if (serverRecord["isDeleted"] as? Int64 ?? 0) == 1, !trashRestore.isRestored(sessionId) {
            pull.applyDeletionMetDuringUpload(sessionId)
            return false
        }
        let restoring = trashRestore.isRestored(sessionId)
        guard CloudKitSessionFreshness.overwrite(serverRecord, with: prepared.record, restoring: restoring, yieldingIn: &state) else { return false }
        trashRestore.markIfReplacingTombstone(serverRecord, sessionId: sessionId)
        do {
            try await privateDB.save(serverRecord)
            state.markUploaded(sessionId)
            trashRestore.clear(sessionId)
            noteSyncProgress()
        } catch {
            noteConflictUnresolved(sessionId, reason: "\(error)", error: error)
        }
        return false
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
    private func handlePrepFailure(_ error: Error, sessionId: UUID) async {
        guard let archiveError = error as? SessionArchive.ArchiveError,
              archiveError.isPermanentUploadFailure
        else {
            state.markFailed(sessionId)
            debugLog("[CloudKit] Push: prep failed for \(sessionId.uuidString.prefix(8)): \(error.localizedDescription)")
            return
        }

        if case .hashMismatch = archiveError, archive.repairSessionHashIfDecodable(sessionId: sessionId) {
            // Reset backoff so the now-good file uploads next cycle.
            state.clearFailureCount(sessionId)
            debugLog("[CloudKit] Push: REPAIRED stale hash for \(sessionId.uuidString.prefix(8)) — file decoded fine; will re-attempt upload next cycle", level: .warning)
        } else {
            state.markQuarantined(sessionId)
            await state.saveQuarantineQueueAsync()
            debugLog("[CloudKit] Push: QUARANTINED \(sessionId.uuidString.prefix(8)) — permanent, undecodable prep failure (\(error.localizedDescription)); will not retry. File kept on disk; surfaced to user.", level: .warning)
        }
    }

    /// A session read out of Apple Health whole stays on this device. One this
    /// device had uploaded or queued may have an iCloud copy from an earlier
    /// build; that copy is deleted outright, not tombstoned, because a
    /// tombstone would delete the session on the user's other devices. The
    /// session is marked local-only once iCloud holds no copy; a failed delete
    /// leaves it queued, and a later cycle tries again.
    private func keepOnDevice(_ sessionId: UUID) async {
        let mayBeInCloud = state.uploadedSessionIds.contains(sessionId) || state.pendingUploadIds.contains(sessionId)
        if mayBeInCloud {
            do {
                try await privateDB.deleteRecord(withID: CKRecord.ID(recordName: sessionId.uuidString, zoneID: zoneID))
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
        debugLog("[CloudKit] Push: \(sessionId.uuidString.prefix(8)) came from Apple Health — kept on this device only")
    }

    /// Zone gone server-side — recreate ONCE per cycle and retry this session
    /// inline. Returns `true` when the whole cycle should bail: if recreation
    /// fails, every remaining push will fail too, and continuing would log
    /// the same error twenty times.
    private func handleZoneGone(_ error: CKError, sessionId: UUID) async -> Bool {
        debugLog("[CloudKit] Push: zone gone (\(error.code.rawValue)) — attempting recreation", level: .warning)

        guard await recreateZoneAfterNotFound() else {
            debugLog("[CloudKit] Push: zone recreation failed — bailing on this sync cycle", level: .error)
            state.markFailed(sessionId)
            return true
        }

        do {
            guard let retryPrepared = try await prepareUploadOffMain(sessionId: sessionId) else { return false }
            defer { cleanupTempAsset(for: retryPrepared.record) }
            try await privateDB.save(retryPrepared.record)
            state.markUploaded(sessionId)
        } catch {
            state.markFailed(sessionId)
            debugLog("[CloudKit] Push: retry-after-recreate failed for \(sessionId.uuidString.prefix(8)): \(error.localizedDescription)", level: .error)
        }
        return false
    }

    /// Stable retry-spreading bucket derived from the UUID's own bytes —
    /// unlike `hashValue`, identical across launches so exponential
    /// backoff schedules actually hold.
    static func stableRetryBucket(for id: UUID) -> Int {
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
    /// whole: this is the one builder every upload goes through, so the
    /// refusal here covers every path.
    nonisolated static func buildSessionRecord(from session: HRVSession, zoneID: CKRecordZone.ID, recordTypeName: String) throws -> CKRecord {
        guard !CloudSessionPayload.isHealthKitSourced(session) else { throw CloudUploadExclusion.healthKitSourced }
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
        let compressedData = try compressedPayload(for: session)
        record["sessionData"] = CKAsset(fileURL: try writeAssetFile(compressedData, sessionId: session.id))
        return record
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
    /// reach is the encryption in `encryptedForCloud`, not this function.
    nonisolated private static func compressedPayload(for session: HRVSession) throws -> Data {
        let sanitized = CloudSessionPayload.uploadable(session)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        let compressed = try DataCompression.compress(try encoder.encode(sanitized))
        return try encryptedForCloud(compressed)
    }

    /// Encrypt a payload before it is handed to CloudKit.
    ///
    /// ## Why
    ///
    /// App Review Guideline 5.1.3(ii): apps "may not store personal health
    /// information in iCloud." The text carries no HealthKit-origin
    /// qualification — assuming one meant uploading compressed-but-readable
    /// JSON containing RR intervals, recovery scores and RMSSD.
    ///
    /// Compression is not confidentiality. A compressed payload is readable by
    /// anyone who can read the container.
    ///
    /// Encrypting with the cloud key (`CloudPayloadCodec`, held in the iCloud
    /// Keychain) means CloudKit holds ciphertext rather than health
    /// information. The key never goes into a CloudKit record, so the stored
    /// bytes are not personal health information to anyone holding them.
    ///
    /// Throws rather than falling back to plaintext. This is the same
    /// fail-closed decision as `Archive+SessionCodec`, and
    /// the stakes are higher here: a plaintext fallback would upload readable
    /// health data to a third party. A skipped backup is recoverable; an
    /// uploaded one is not.
    nonisolated private static func encryptedForCloud(_ payload: Data) throws -> Data {
        // `CloudPayloadCodec`, not `EncryptionManager`: the archive key is
        // non-synchronizable, so a backup sealed with it could not be read by
        // the user's other devices — which defeats the point of a cloud backup.
        guard CloudPayloadCodec.hasUsableKey else { throw CloudSyncError.encryptionUnavailable }
        return try CloudPayloadCodec.encode(payload)
    }

    /// The CKAsset temp file is short-lived (deleted right
    /// after the save via `cleanupTempAsset`) but holds compressed health
    /// data, so protect it at rest until first unlock rather than leaving
    /// it readable while the device is locked.
    nonisolated private static func writeAssetFile(_ compressedData: Data, sessionId: UUID) throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck_\(sessionId.uuidString)_\(UUID().uuidString.prefix(8))")
            .appendingPathExtension("gz")
        try compressedData.write(to: tempURL, options: [.completeFileProtectionUntilFirstUserAuthentication])
        return tempURL
    }

    // MARK: - Zone Management

    func ensureZoneExists() async throws {
        guard !zoneCreated else { return }

        let zone = CKRecordZone(zoneID: zoneID)
        do {
            try await privateDB.save(zone)
            zoneCreated = true
        } catch let error as CKError where error.code == .serverRejectedRequest {
            // Zone may already exist
            zoneCreated = true
        }
    }

    /// Force re-creation of the zone after a `.zoneNotFound` failure.
    /// Resets the cached `zoneCreated` flag and re-attempts the save.
    /// Returns true if creation succeeded, false otherwise (caller can
    /// then disable sync to stop a retry storm).
    ///
    /// **Why this exists:** A beta tester had their CloudKit
    /// zone disappear server-side (likely an iCloud account state
    /// transition). Every push attempt then failed with
    /// `Zone does not exist` and was queued for retry — 20 sessions
    /// retrying every sync cycle, infinite loop, hammering CPU + battery
    /// on their iPhone 11. `ensureZoneExists` alone only runs on
    /// first sync and caches its result; once `zoneCreated = true`, it
    /// never re-attempts even when the zone is clearly gone.
    func recreateZoneAfterNotFound() async -> Bool {
        zoneCreated = false  // Force re-attempt
        do {
            try await ensureZoneExists()
            debugLog("[CloudKit] Zone recreated after .zoneNotFound", level: .warning)
            return true
        } catch {
            debugLog("[CloudKit] Zone recreation failed: \(error.localizedDescription)", level: .error)
            return false
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
    /// the sleep won the race. Used to cap the full-sync body so a wedged
    /// CloudKit call can't freeze the syncState machine. `runWithTimeout`
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
