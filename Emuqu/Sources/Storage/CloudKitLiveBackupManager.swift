import CloudKit
import Foundation

/// Manages in-progress session backups to CloudKit so recordings survive device loss.
/// Each backup is a compressed CKAsset of RR points, keyed by session ID, overwritten
/// on each incremental save. Throttled to every 5 minutes to respect CloudKit rate limits.
///
/// Fully independent of CloudKitSyncManager, with its own record type ("RawBackup")
/// and no interaction with the main session sync flow.
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
    /// CloudKit upload every minute, forever. Terence's beta log:
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
    func upload(sessionId: UUID, points: [RRPoint], deviceId: String?, force: Bool = false) async {
        guard settings.iCloudSyncEnabled else { return }
        guard !points.isEmpty else { return }
        guard !schemaUnavailable else { return }
        if !force, let last = lastUpload, Date().timeIntervalSince(last) < uploadInterval { return }
        lastUpload = Date()
        do {
            try await ensureZone()
            let record = try await liveBackupRecord(sessionId: sessionId)
            record["beatCount"] = points.count as CKRecordValue
            record["captureDate"] = Date() as CKRecordValue
            if let deviceId {
                record["deviceId"] = deviceId as CKRecordValue
            }
            let compressedData = try Self.compressedPoints(points)
            try await saveWithAsset(record, compressedData: compressedData, sessionId: sessionId)
            debugLog("[CloudKit] Live backup: \(points.count) beats → iCloud (\(compressedData.count)B)")
        } catch {
            handleUploadFailure(error)
        }
    }

    /// The existing live-backup record for this session, or a fresh one.
    private func liveBackupRecord(sessionId: UUID) async throws -> CKRecord {
        let recordID = CKRecord.ID(recordName: "live_\(sessionId.uuidString)", zoneID: zoneID)
        do {
            return try await privateDB.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            let record = CKRecord(recordType: recordType, recordID: recordID)
            record["sessionId"] = sessionId.uuidString as CKRecordValue
            return record
        }
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
    func fetchAll() async -> [LiveBackupSummary] {
        guard settings.iCloudSyncEnabled else { return [] }
        do {
            try await ensureZone()
            let query = CKQuery(recordType: recordType, predicate: NSPredicate(format: "beatCount > %d", 0))
            let (results, _) = try await privateDB.records(
                matching: query,
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

    /// Decode one queried record into a summary. Nil when the record is
    /// missing a required field or its asset won't decompress.
    private static func liveBackupSummary(from result: Result<CKRecord, Error>) -> LiveBackupSummary? {
        guard case let .success(record) = result,
              let sessionIdStr = record["sessionId"] as? String,
              let sessionId = UUID(uuidString: sessionIdStr),
              let beatCount = record["beatCount"] as? Int,
              let captureDate = record["captureDate"] as? Date,
              let asset = record["rrData"] as? CKAsset,
              let fileURL = asset.fileURL else { return nil }
        do {
            let points = try decodePoints(at: fileURL)
            return LiveBackupSummary(sessionId: sessionId, beatCount: beatCount, captureDate: captureDate, points: points)
        } catch {
            // Distinguished on purpose: a backup that exists but cannot be read
            // is not the same as no backup, and returning nil for both made an
            // unreadable one vanish from the recovery list.
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
