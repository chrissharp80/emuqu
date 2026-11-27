import CloudKit
import Foundation

/// Manages in-progress session backups to CloudKit so recordings survive device loss.
/// Each backup is a compressed CKAsset of RR points, keyed by session ID, overwritten
/// on each incremental save. Throttled to every 5 minutes to respect CloudKit rate limits.
///
/// Separate from CloudKitSyncManager's session sync, with its own record type
/// ("RawBackup"); it shares the sync manager's zone, and the sync manager's
/// zone-creation step, account check and deleted-zone handling are passed in
/// as `ensureZone`, `confirmAccount` and `zoneGone`.
@MainActor
final class CloudKitLiveBackupManager {
    private let container = CKContainer(identifier: AppConfig.iCloudContainerIdentifier)
    private var privateDB: CKDatabase {
        container.privateCloudDatabase
    }

    private let recordType = "RawBackup"
    private let zoneID = CKRecordZone.ID(zoneName: "HRVSessions", ownerName: CKCurrentUserDefaultName)

    private var lastUpload: Date?
    private let uploadInterval: TimeInterval = 300 // 5 minutes

    /// Sticky per-launch flag. Set when CloudKit rejects the live-backup
    /// save because the RawBackup record type isn't in production schema.
    /// Without this, the per-minute RR collector ticker fires a doomed
    /// CloudKit upload every minute, forever.
    private var schemaUnavailable = false

    /// Whether the current run of upload failures has reached Recent Problems.
    private var failureEpisode = LiveBackupFailureEpisode()

    private let settingsManager: SettingsManager
    /// Opens live backups an older build sealed with the archive key.
    private let archiveKey: EncryptionManager
    private let ensureZone: () async throws -> Void
    /// Whether the signed-in iCloud account is the one sync is enabled for
    /// (`CloudAccountGuard.confirmAccount`). Nothing is uploaded to, or read
    /// back from, another account.
    private let confirmAccount: () async -> Bool
    /// The sync manager's handling of a deleted zone
    /// (`CloudAccountGuard.zoneWasDeleted`): sync stops for the user to opt in
    /// again, as the session uploads do.
    private let zoneGone: () async -> Void

    /// Sessions whose live backup this device put in iCloud and has not
    /// deleted yet. Persisted, so a night that ends after iCloud Sync was
    /// turned off — or after a relaunch — still has its backup removed.
    private static let backedUpKey = "cloudkit.liveBackup.awaitingDeletion"
    private var backedUpIds: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.backedUpKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.backedUpKey) }
    }

    /// The recovery list's length, and the size of each page of the
    /// listing it is chosen from.
    private static let recoveryLimit = 10
    private static let listingLimit = 200
    /// Pages of `listingLimit` read before the listing stops: live backups
    /// are deleted once their night is archived, so a real listing is a page.
    private static let maxListingPages = 50

    init(
        settingsManager: SettingsManager,
        archiveKey: EncryptionManager,
        ensureZone: @escaping () async throws -> Void,
        confirmAccount: @escaping () async -> Bool,
        zoneGone: @escaping () async -> Void
    ) {
        self.settingsManager = settingsManager
        self.archiveKey = archiveKey
        self.ensureZone = ensureZone
        self.confirmAccount = confirmAccount
        self.zoneGone = zoneGone
    }

    private var settings: UserSettings {
        settingsManager.settings
    }

    /// Push an in-progress streaming backup to CloudKit so it survives device loss.
    /// Overwrites the same record (keyed by sessionId) on each call.
    /// Fire-and-forget, throttled to every 5 minutes to respect CloudKit rate limits.
    ///
    /// The throttle advances BEFORE the network call. A
    /// "set on success only" throttle lets any failure (network, schema,
    /// anything) bypass the 5-minute interval — the RR collector ticker
    /// re-triggers upload every minute and hammers CloudKit, floods the
    /// error catalog, and burned battery.
    ///
    /// A session deleted forever or discarded (`ForgottenSessions`) is not
    /// uploaded, and an upload it was discarded during is deleted again.
    ///
    /// Same gate as session uploads (`CloudKitSyncManager.cloudUploadsAllowed`):
    /// nothing goes up before onboarding has asked about iCloud, and nothing
    /// to an iCloud account other than the one sync is enabled for.
    func upload(sessionId: UUID, points: [RRPoint], deviceId: String?, force: Bool = false) async {
        guard isUploadDue(pointCount: points.count, force: force), !ForgottenSessions.ids.contains(sessionId) else { return }
        lastUpload = Date()
        guard await confirmAccount() else { return }
        do {
            try await ensureZone()
            let record = try await liveBackupRecord(sessionId: sessionId)
            let assetURL = try Self.attachUpload(of: points, sessionId: sessionId, to: record)
            try await saveWithAsset(record, at: assetURL)
            debugLog("[CloudKit] Live backup: \(points.count) beats → iCloud")
            await noteUploaded(sessionId)
        } catch let error as CKError where CloudKitSyncManager.isZoneGone(error) {
            debugLog("[CloudKit] Live backup: zone gone (\(error.code.rawValue)) — iCloud data was deleted, or the account changed", level: .warning)
            await zoneGone()
        } catch {
            handleUploadFailure(error)
        }
    }

    /// A saved upload: the backup awaits deletion and the run of failures is
    /// over. A session discarded while the upload ran is deleted again: its
    /// delete may have landed first, and this save would bring it back.
    private func noteUploaded(_ sessionId: UUID) async {
        backedUpIds.insert(sessionId.uuidString)
        failureEpisode.noteSuccess()
        if ForgottenSessions.ids.contains(sessionId) { await delete(sessionId: sessionId) }
    }

    /// The record's only plain field is the first upload's time, kept: a
    /// pulling device dates the night by it, and the recovery query selects on
    /// it. The beat count travels inside the encrypted asset (recovery counts
    /// the decoded points) and the strap ID was never read back by any build;
    /// older builds wrote both in the clear, so both are cleared. (`deviceId`
    /// stays in `upload`'s signature: the callers pass it, and the local backup
    /// still keeps it.)
    private static func setPlainFields(of record: CKRecord) {
        if record["captureDate"] == nil { record["captureDate"] = Date() as CKRecordValue }
        record["beatCount"] = nil
        record["deviceId"] = nil
    }

    /// Sync on, onboarding done, something to send, a schema that accepts it,
    /// and — unless forced — the upload interval elapsed since the last one.
    private func isUploadDue(pointCount: Int, force: Bool) -> Bool {
        guard settings.iCloudSyncEnabled, settings.hasCompletedOnboarding else { return false }
        guard pointCount > 0, !schemaUnavailable else { return false }
        if !force, let last = lastUpload, Date().timeIntervalSince(last) < uploadInterval { return false }
        return true
    }

    /// The existing live-backup record for this session, or a fresh one.
    ///
    /// Fetched without its `rrData` asset, which this save replaces anyway:
    /// fetched whole, every 5-minute save first downloaded the night's
    /// previous backup file. Fields left out of the fetch keep their server
    /// values on save.
    private func liveBackupRecord(sessionId: UUID) async throws -> CKRecord {
        let recordID = CKRecord.ID(recordName: "live_\(sessionId.uuidString)", zoneID: zoneID)
        do {
            let fetched = try await privateDB.records(for: [recordID], desiredKeys: ["captureDate", "sessionId"])
            if let existing = fetched[recordID] { return try existing.get() }
        } catch let error as CKError where error.code == .unknownItem {
            debugLog("[CloudKit] Live backup: first upload for \(sessionId.uuidString.prefix(8))")
        }
        let record = CKRecord(recordType: recordType, recordID: recordID)
        record["sessionId"] = sessionId.uuidString as CKRecordValue
        return record
    }

    /// The night's points, encoded, compressed and sealed for upload by
    /// `CloudPayloadCodec.sealForUpload`, which throws rather than upload
    /// plaintext.
    ///
    /// Runs in an autoreleasepool: this fires about every 5 minutes through
    /// the night and encodes the whole accumulated buffer (25k+ points by
    /// morning), so the transient JSONEncoder tree is freed at once instead of
    /// growing all night.
    private static func compressedPoints(_ points: [RRPoint]) throws -> Data {
        try autoreleasepool {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let compressed = try DataCompression.compress(try encoder.encode(points))
            return try CloudPayloadCodec.sealForUpload(compressed)
        }
    }

    /// Everything an upload writes on `record`: its plain fields, and the
    /// sealed points as the `rrData` asset. The asset's file is returned for
    /// the caller to remove once the save has read it. The one place the
    /// uploaded record's contents are decided, so a test can read exactly what
    /// goes to iCloud.
    static func attachUpload(of points: [RRPoint], sessionId: UUID, to record: CKRecord) throws -> URL {
        setPlainFields(of: record)
        let sealed = try compressedPoints(points)
        // A unique filename avoids collisions between overlapping uploads.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("live_\(sessionId.uuidString)_\(UUID().uuidString.prefix(8))")
            .appendingPathExtension("gz")
        try sealed.write(to: tempURL)
        record["rrData"] = CKAsset(fileURL: tempURL)
        return tempURL
    }

    /// Save `record`, then remove its asset file. Cleanup happens after the
    /// save completes because CloudKit reads the file asynchronously during
    /// `privateDB.save()`.
    private func saveWithAsset(_ record: CKRecord, at tempURL: URL) async throws {
        defer { _ = attempt("CloudKitLiveBackupManager.remove") { try FileManager.default.removeItem(at: tempURL) } }
        guard uploadsStillAllowed else { throw CloudUploadStopped() }
        _ = try await privateDB.save(record)
    }

    /// The upload's gate, read again right before the save: the record fetch
    /// and the sealing before it await, and sync can be switched off, a purge
    /// begin or the account change meanwhile. The same conditions as
    /// `CloudKitSyncManager.saveUpload`.
    var uploadsStillAllowed: Bool {
        settings.iCloudSyncEnabled && settings.hasCompletedOnboarding && !PurgeGate.isPurging
            && !schemaUnavailable && CloudAccountIdentity.isConfirmed && !Task.isCancelled
    }

    private func handleUploadFailure(_ error: Error) {
        guard !(error is CloudUploadStopped) else {
            return debugLog("[CloudKit] Live backup not sent: sync was switched off or the account changed while it was prepared")
        }
        guard !CloudKitSyncManager.isPermanentSchemaError(error) else {
            schemaUnavailable = true
            debugLog("[CloudKit] Live backup paused for this launch — RawBackup record type not in production schema", level: .error)
            return
        }
        switch failureEpisode.entry(for: error) {
        case .problem:
            debugLog("[CloudKit] Live backup upload failed: \(error.localizedDescription)", level: .warning)
        case .repeated:
            debugLog("[CloudKit] Live backup upload failed again: \(error.localizedDescription)")
        case let .external(cause):
            debugLogExternal("Live backup not sent this time (\(error.localizedDescription)); the next save sends it", cause: cause)
        }
    }

    /// Delete the live backup record after a session is completed and archived.
    ///
    /// With iCloud Sync on, or for a backup this device uploaded whatever the
    /// setting is now: removing the user's own data from iCloud is not an
    /// upload. No zone is created for it; a missing zone means there is
    /// nothing to delete. A delete that fails leaves the session awaiting
    /// deletion (`backedUpIds`, persisted), and the full sync deletes it
    /// again once its session is deleted (`retryAwaitingDeletion`). While the
    /// signed-in account is not confirmed as the one the backup went to
    /// (`CloudAccountIdentity.isConfirmed`), nothing is deleted and the
    /// session stays awaiting deletion.
    func delete(sessionId: UUID) async {
        guard settings.iCloudSyncEnabled || backedUpIds.contains(sessionId.uuidString) else { return }
        guard CloudAccountIdentity.isConfirmed else {
            backedUpIds.insert(sessionId.uuidString)
            return
        }
        do {
            let recordID = CKRecord.ID(recordName: "live_\(sessionId.uuidString)", zoneID: zoneID)
            try await privateDB.deleteRecord(withID: recordID)
            debugLog("[CloudKit] Cleaned up live backup for \(sessionId.uuidString.prefix(8))")
        } catch let error as CKError where [.unknownItem, .zoneNotFound, .userDeletedZone].contains(error.code) {
            debugLog("[CloudKit] No live backup in iCloud for \(sessionId.uuidString.prefix(8))")
        } catch {
            debugLog("[CloudKit] Failed to clean up live backup, kept for the next full sync: \(error.localizedDescription)", level: .warning)
            backedUpIds.insert(sessionId.uuidString)
            return
        }
        backedUpIds.remove(sessionId.uuidString)
    }

    /// Delete again every backup awaiting deletion whose session is in
    /// `finished` (deleted, deleted forever, or archived and in iCloud). Run
    /// by the full sync (`CloudDeletionCoordinator.reconcileLocalDeletions`).
    /// A session not in `finished`, such as a recording still in progress,
    /// keeps its backup.
    func retryAwaitingDeletion(among finished: Set<UUID>) async {
        let due = backedUpIds.compactMap(UUID.init(uuidString:)).filter { finished.contains($0) }
        for sessionId in due {
            await delete(sessionId: sessionId)
        }
    }

    /// Fetch any live backups in CloudKit for recovery after device loss.
    ///
    /// Selected on `captureDate`, which every record carries, so the query
    /// needs that field's queryable index in the production schema.
    ///
    /// The newest backups by capture date: a query returns records in no set
    /// order, so every page of the listing is read (dates only, without the
    /// beats) before the newest are picked and fetched whole. Taking the
    /// first page alone could leave out the night the user needs.
    ///
    /// nil when nothing was asked of iCloud (sync off, or another account);
    /// throws when the listing or the fetch failed, so a caller can tell a
    /// failure from an iCloud that holds no backups.
    func fetchAll() async throws -> [LiveBackupSummary]? {
        guard settings.iCloudSyncEnabled, await confirmAccount() else { return nil }
        try await ensureZone()
        let newest = try await newestBackupIDs()
        let fetched = try await privateDB.records(for: newest)
        let backups = newest.compactMap { fetched[$0] }.compactMap { Self.liveBackupSummary(from: $0, archiveKey: archiveKey) }
        if !backups.isEmpty {
            debugLog("[CloudKit] Found \(backups.count) live backup(s) in iCloud")
        }
        return backups
    }

    /// The ids of the `recoveryLimit` newest backups, from every page of
    /// the listing up to `maxListingPages`.
    private func newestBackupIDs() async throws -> [CKRecord.ID] {
        var page = try await privateDB.records(
            matching: recoveryQuery, inZoneWith: zoneID, desiredKeys: ["captureDate"], resultsLimit: Self.listingLimit
        )
        var dated = Self.dated(page.matchResults)
        var pagesRead = 1
        while let cursor = page.queryCursor, pagesRead < Self.maxListingPages {
            page = try await privateDB.records(continuingMatchFrom: cursor, desiredKeys: ["captureDate"], resultsLimit: Self.listingLimit)
            dated += Self.dated(page.matchResults)
            pagesRead += 1
        }
        if page.queryCursor != nil {
            debugLog("[CloudKit] Live backups: more than \(Self.maxListingPages * Self.listingLimit) listed; the newest of those are offered", level: .warning)
        }
        return Self.newest(dated, limit: Self.recoveryLimit)
    }

    /// The capture date of each listed record that has one.
    private static func dated(_ results: [(CKRecord.ID, Result<CKRecord, Error>)]) -> [(id: CKRecord.ID, captureDate: Date)] {
        results.compactMap { id, result in
            guard case let .success(record) = result, let captureDate = record["captureDate"] as? Date else { return nil }
            return (id, captureDate)
        }
    }

    /// The ids of the `limit` newest of `dated`, newest first.
    static func newest(_ dated: [(id: CKRecord.ID, captureDate: Date)], limit: Int) -> [CKRecord.ID] {
        dated.sorted { $0.captureDate > $1.captureDate }.prefix(limit).map(\.id)
    }

    private var recoveryQuery: CKQuery {
        CKQuery(recordType: recordType, predicate: NSPredicate(format: "captureDate > %@", NSDate(timeIntervalSince1970: 0)))
    }

    /// Decode one queried record into a summary. Nil when the record is
    /// missing a required field, its asset can't be unsealed, decompressed
    /// or decoded, or it holds no beats. The beat count is the decoded
    /// points' count. A record that failed to fetch, or lacks a field, is
    /// logged too, so a backup that exists but cannot be offered leaves a
    /// trace; one that cannot be read is logged at error level. Either is
    /// still left out of the recovery list: there are no beats to recover
    /// from it.
    private static func liveBackupSummary(from result: Result<CKRecord, Error>, archiveKey: EncryptionManager) -> LiveBackupSummary? {
        guard let record = fetchedRecord(result) else { return nil }
        guard let sessionIdStr = record["sessionId"] as? String,
              let sessionId = UUID(uuidString: sessionIdStr),
              let captureDate = record["captureDate"] as? Date,
              let asset = record["rrData"] as? CKAsset,
              let fileURL = asset.fileURL else {
            debugLog("[CloudKit] Live backup \(record.recordID.recordName.prefix(13)) is missing a field or its beats — not offered", level: .warning)
            return nil
        }
        do {
            let points = try Self.decodePoints(at: fileURL, archiveKey: archiveKey)
            guard !points.isEmpty else { return nil }
            return LiveBackupSummary(sessionId: sessionId, beatCount: points.count, captureDate: captureDate, points: points)
        } catch {
            debugLog("[CloudKit] Live backup \(sessionIdStr.prefix(8)) is present but unreadable: \(error)",
                     level: .error)
            return nil
        }
    }
    /// The record a fetch returned; nil, logged, when it failed.
    private static func fetchedRecord(_ result: Result<CKRecord, Error>) -> CKRecord? {
        switch result {
        case let .success(record):
            return record
        case let .failure(error):
            debugLog("[CloudKit] A live backup could not be fetched: \(error.localizedDescription)", level: .warning)
            return nil
        }
    }

    /// Unseal, decompress and decode one live-backup asset.
    ///
    /// The exact inverse of `compressedPoints`, in that order. The live-backup
    /// defect in `CloudPayloadCodec`'s header was these two halves disagreeing.
    private static func decodePoints(at fileURL: URL, archiveKey: EncryptionManager) throws -> [RRPoint] {
        let raw = try Data(contentsOf: fileURL)
        let jsonData = try DataCompression.decompress(CloudPayloadCodec.decode(raw, archiveKey: archiveKey))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([RRPoint].self, from: jsonData)
    }
}

/// How a failed live-backup upload is logged.
///
/// A real failure reaches the user's Recent Problems once per run of
/// failures: the upload retries every few minutes all night, and an entry
/// per retry would bury everything else there. A success ends the run, so
/// the next failure is reported again. A cause outside the app (no network,
/// iCloud signed out or briefly unavailable, CloudKit asking the app to slow
/// down) is logged as external (`debugLogExternal`) and never as a problem:
/// the next save retries it, and the full sync reports it in its own status
/// (`cloudKitErrorMessage`).
struct LiveBackupFailureEpisode {
    enum Entry: Equatable {
        /// The first real failure of a run: a warning, in Recent Problems.
        case problem
        /// A real failure in a run already reported: logged, not repeated there.
        case repeated
        /// A condition outside the app.
        case external(ExternalCause)
    }

    private var reported = false

    /// The entry `error` gets, and the run's state after it.
    mutating func entry(for error: Error) -> Entry {
        if let cause = Self.externalCause(of: error) { return .external(cause) }
        defer { reported = true }
        return reported ? .repeated : .problem
    }

    /// An upload went through: the run of failures is over.
    mutating func noteSuccess() { reported = false }

    /// The outside cause of `error`, or nil when the failure is a real one.
    static func externalCause(of error: Error) -> ExternalCause? {
        guard let code = (error as? CKError)?.code else { return nil }
        switch code {
        case .networkUnavailable, .networkFailure: return .network
        case .notAuthenticated, .accountTemporarilyUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy: return .iCloud
        default: return nil
        }
    }
}
