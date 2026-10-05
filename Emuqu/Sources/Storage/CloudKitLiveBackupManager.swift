import CloudKit
import Foundation

/// Manages in-progress session backups to CloudKit so recordings survive device loss.
/// Each backup is a compressed CKAsset of RR points, keyed by session ID, overwritten
/// on each incremental save. Throttled to every 5 minutes to respect CloudKit rate limits.
///
/// Separate from CloudKitSyncManager's session sync, with its own record type
/// ("RawBackup"); it shares the sync manager's zone, and the sync manager's
/// zone-creation step is passed in as `ensureZone`.
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
    /// CloudKit upload every minute, forever. A beta log showed
    /// `[CloudKit] ⚠️ Live backup upload failed: Cannot create new type
    /// RawBackup in production schema` repeating every minute for hours.
    private var schemaUnavailable = false

    private let settingsManager: SettingsManager
    private let ensureZone: () async throws -> Void

    init(settingsManager: SettingsManager, ensureZone: @escaping () async throws -> Void) {
        self.settingsManager = settingsManager
        self.ensureZone = ensureZone
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
    /// nothing goes up before onboarding has asked about iCloud.
    func upload(sessionId: UUID, points: [RRPoint], deviceId: String?, force: Bool = false) async {
        guard isUploadDue(pointCount: points.count, force: force) else { return }
        lastUpload = Date()
        do {
            try await ensureZone()
            let record = try await liveBackupRecord(sessionId: sessionId)
            Self.setPlainFields(of: record)
            let compressedData = try Self.compressedPoints(points)
            try await saveWithAsset(record, compressedData: compressedData, sessionId: sessionId)
            debugLog("[CloudKit] Live backup: \(points.count) beats → iCloud (\(compressedData.count)B)")
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

    /// Drained in an autoreleasepool. This fires every ~5 min
    /// through the night and encodes the ENTIRE accumulated buffer (25k+
    /// points by morning), so the transient JSONEncoder tree would otherwise
    /// grow all night and could coincide with the finalize spike. Freed immediately.
    /// Encoded, compressed, then ENCRYPTED.
    ///
    /// Guideline 5.1.3(ii) forbids storing personal health information in
    /// iCloud, and raw RR intervals are exactly that. Compression is not
    /// confidentiality — compressed-only beats upload readable.
    /// Fails closed rather than falling back to plaintext.
    private static func compressedPoints(_ points: [RRPoint]) throws -> Data {
        try autoreleasepool {
            guard CloudPayloadCodec.hasUsableKey else { throw CloudSyncError.encryptionUnavailable }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let compressed = try DataCompression.compress(try encoder.encode(points))
            return try CloudPayloadCodec.encode(compressed)
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
        try await privateDB.save(record)
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
    func delete(sessionId: UUID) async {
        guard settings.iCloudSyncEnabled else { return }

        do {
            try await ensureZone()
            let recordID = CKRecord.ID(recordName: "live_\(sessionId.uuidString)", zoneID: zoneID)
            try await privateDB.deleteRecord(withID: recordID)
            debugLog("[CloudKit] Cleaned up live backup for \(sessionId.uuidString.prefix(8))")
        } catch let error as CKError where error.code == .unknownItem {
            // Already deleted or never uploaded
        } catch {
            debugLog("[CloudKit] Failed to clean up live backup: \(error.localizedDescription)")
        }
    }

    /// Fetch any live backups in CloudKit for recovery after device loss.
    ///
    /// Selected on `captureDate`, which every record carries, so the query
    /// needs that field's queryable index in the production schema. It used to
    /// select on a plaintext beat count, which is no longer written.
    func fetchAll() async -> [LiveBackupSummary] {
        guard settings.iCloudSyncEnabled else { return [] }
        do {
            try await ensureZone()
            let (results, _) = try await privateDB.records(
                matching: recoveryQuery,
                inZoneWith: zoneID,
                resultsLimit: 10
            )
            let backups = results.compactMap { Self.liveBackupSummary(from: $0.1) }
            if !backups.isEmpty {
                debugLog("[CloudKit] Found \(backups.count) live backup(s) in iCloud")
            }
            return backups
        } catch {
            debugLog("[CloudKit] Failed to fetch live backups: \(error.localizedDescription)")
            return []
        }
    }

    private var recoveryQuery: CKQuery {
        CKQuery(recordType: recordType, predicate: NSPredicate(format: "captureDate > %@", NSDate(timeIntervalSince1970: 0)))
    }

    /// Decode one queried record into a summary. Nil when the record is
    /// missing a required field, its asset can't be unsealed, decompressed
    /// or decoded, or it holds no beats. The beat count is the decoded
    /// points' count.
    private static func liveBackupSummary(from result: Result<CKRecord, Error>) -> LiveBackupSummary? {
        guard case let .success(record) = result,
              let sessionIdStr = record["sessionId"] as? String,
              let sessionId = UUID(uuidString: sessionIdStr),
              let captureDate = record["captureDate"] as? Date,
              let asset = record["rrData"] as? CKAsset,
              let fileURL = asset.fileURL else { return nil }
        do {
            let points = try decodePoints(at: fileURL)
            guard !points.isEmpty else { return nil }
            return LiveBackupSummary(sessionId: sessionId, beatCount: points.count, captureDate: captureDate, points: points)
        } catch {
            // Logged at error level, apart from a missing field, so a backup
            // that exists but cannot be read leaves a trace. It is still left
            // out of the recovery list: there are no beats to recover from it.
            debugLog("[CloudKit] Live backup \(sessionIdStr.prefix(8)) is present but unreadable: \(error)",
                     level: .error)
            return nil
        }
    }
    /// Unseal, decompress and decode one live-backup asset.
    ///
    /// The exact inverse of `compressedPoints`, in that order. The live-backup
    /// defect in `CloudPayloadCodec`'s header was these two halves disagreeing.
    private static func decodePoints(at fileURL: URL) throws -> [RRPoint] {
        let raw = try Data(contentsOf: fileURL)
        let jsonData = try DataCompression.decompress(CloudPayloadCodec.decode(raw))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([RRPoint].self, from: jsonData)
    }
}
