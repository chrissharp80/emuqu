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

    /// The recovery list's length, and how many dated records it is chosen
    /// from.
    private static let recoveryLimit = 10
    private static let listingLimit = 200

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
    /// Same gate as session uploads (`CloudKitSyncManager.cloudUploadsAllowed`):
    /// nothing goes up before onboarding has asked about iCloud, and nothing
    /// to an iCloud account other than the one sync is enabled for.
    func upload(sessionId: UUID, points: [RRPoint], deviceId: String?, force: Bool = false) async {
        guard isUploadDue(pointCount: points.count, force: force) else { return }
        lastUpload = Date()
        guard await confirmAccount() else { return }
        do {
            try await ensureZone()
            let record = try await liveBackupRecord(sessionId: sessionId)
            Self.setPlainFields(of: record)
            let compressedData = try Self.compressedPoints(points)
            try await saveWithAsset(record, compressedData: compressedData, sessionId: sessionId)
            backedUpIds.insert(sessionId.uuidString)
            debugLog("[CloudKit] Live backup: \(points.count) beats → iCloud (\(compressedData.count)B)")
        } catch let error as CKError where CloudKitSyncManager.isZoneGone(error) {
            debugLog("[CloudKit] Live backup: zone gone (\(error.code.rawValue)) — iCloud data was deleted, or the account changed", level: .warning)
            await zoneGone()
        } catch {
            handleUploadFailure(error)
        }
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

    /// Unique filename avoids collisions; cleanup happens AFTER save completes
    /// because CloudKit reads the file asynchronously during `privateDB.save()`.
    private func saveWithAsset(
        _ record: CKRecord, compressedData: Data, sessionId: UUID
    ) async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("live_\(sessionId.uuidString)_\(UUID().uuidString.prefix(8))")
            .appendingPathExtension("gz")
        try compressedData.write(to: tempURL)
        record["rrData"] = CKAsset(fileURL: tempURL)
        defer { _ = attempt("CloudKitLiveBackupManager.remove") { try FileManager.default.removeItem(at: tempURL) } }
        _ = try await privateDB.save(record)
    }

    private func handleUploadFailure(_ error: Error) {
        guard !CloudKitSyncManager.isPermanentSchemaError(error) else {
            schemaUnavailable = true
            debugLog("[CloudKit] Live backup paused for this launch — RawBackup record type not in production schema", level: .error)
            return
        }
        debugLog("[CloudKit] Live backup upload failed: \(error.localizedDescription)")
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
    /// order, so a capped query would let stale backups crowd out the one the user
    /// needs. Dates are listed first, without the beats, and only the newest
    /// records are then fetched whole.
    func fetchAll() async -> [LiveBackupSummary] {
        guard settings.iCloudSyncEnabled, await confirmAccount() else { return [] }
        do {
            try await ensureZone()
            let newest = try await newestBackupIDs()
            let fetched = try await privateDB.records(for: newest)
            let backups = newest.compactMap { fetched[$0] }.compactMap { Self.liveBackupSummary(from: $0, archiveKey: archiveKey) }
            if !backups.isEmpty {
                debugLog("[CloudKit] Found \(backups.count) live backup(s) in iCloud")
            }
            return backups
        } catch {
            debugLog("[CloudKit] Failed to fetch live backups: \(error.localizedDescription)")
            return []
        }
    }

    /// The ids of the `recoveryLimit` newest backups among up to
    /// `listingLimit` listed by their capture date alone.
    private func newestBackupIDs() async throws -> [CKRecord.ID] {
        let (results, _) = try await privateDB.records(
            matching: recoveryQuery, inZoneWith: zoneID, desiredKeys: ["captureDate"], resultsLimit: Self.listingLimit
        )
        var dated: [(id: CKRecord.ID, captureDate: Date)] = []
        for (id, result) in results {
            guard case let .success(record) = result, let captureDate = record["captureDate"] as? Date else { continue }
            dated.append((id, captureDate))
        }
        return dated.sorted { $0.captureDate > $1.captureDate }.prefix(Self.recoveryLimit).map { $0.id }
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
