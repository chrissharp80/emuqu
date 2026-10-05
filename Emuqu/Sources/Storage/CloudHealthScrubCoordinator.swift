import CloudKit
import Foundation

/// Rewrites the iCloud session records uploaded before the payload left out
/// every Apple Health reading (`CloudSessionPayload`), so no earlier upload
/// keeps one (Guideline 5.1.3(ii)).
///
/// The ids to rewrite are taken once from the uploaded set and kept in a
/// persisted list, drained a bounded batch per sync, so the work never
/// floods a launch:
///   • iCloud Sync on: each id is marked for upload again and the push writes
///     the stripped payload (`dripReupload`).
///   • iCloud Sync off, with an iCloud account available: nothing new may be
///     uploaded, so each record still in iCloud is rewritten in place from its
///     own contents with the Health readings removed, and a session read out
///     of Apple Health whole has its record deleted (`scrubInPlace`). No local
///     session and no record that is not already in iCloud is written.
///
/// Version 4 of the list covers the analysis result's training context,
/// Apple Health's daytime resting heart rate, the sleep-segment label, the
/// SpO₂ penalty, and Apple Watch heart rate in splits, laps and the AI
/// snapshot, which version 3 left in.
///
/// A strong reference: the manager builds a fresh coordinator for each use.
@MainActor
struct CloudHealthScrubCoordinator {
    let manager: CloudKitSyncManager

    static let remainingKey = "FlowRecovery.cloudkit.hkSanitizeReupload.v4.remaining"
    static let initializedKey = "FlowRecovery.cloudkit.hkSanitizeReupload.v4.initialized"
    /// Earlier lists' keys, removed when version 4 starts and by a remote wipe.
    static let legacyKeys = [
        "FlowRecovery.cloudkit.hkSanitizeReupload.v2.remaining",
        "FlowRecovery.cloudkit.hkSanitizeReupload.v2.initialized",
        "FlowRecovery.cloudkit.hkSanitizeReupload.v3.remaining",
        "FlowRecovery.cloudkit.hkSanitizeReupload.v3.initialized"
    ]
    /// Records handled per sync.
    static let batchSize = 10

    private var defaults: UserDefaults { .standard }

    /// What happened to one id of the list.
    enum Outcome: Equatable {
        /// Rewritten, deleted, or nothing to do: the id leaves the list.
        case finished
        /// iCloud could not be reached or refused the save: the id stays and
        /// the pass stops, to be retried on a later sync.
        case retryLater
    }

    // MARK: - The list

    /// The ids still to rewrite, taken from the uploaded set the first time.
    func remainingIds() async -> [String] {
        if !defaults.bool(forKey: Self.initializedKey) {
            await initialize()
        }
        return defaults.stringArray(forKey: Self.remainingKey) ?? []
    }

    /// Clear the list. After a remote wipe it names records that no longer exist.
    func clear() {
        defaults.removeObject(forKey: Self.remainingKey)
        defaults.removeObject(forKey: Self.initializedKey)
        Self.legacyKeys.forEach(defaults.removeObject(forKey:))
    }

    /// Repair v1 damage first: v1 hollowed `uploadedSessionIds` wholesale,
    /// leaving the entire archive looking pending. Only the developer's own
    /// device ever ran a v1 build, and on it every archived session already
    /// existed remotely, so re-marking everything uploaded restores the
    /// truthful state.
    private func initialize() async {
        if defaults.bool(forKey: "FlowRecovery.cloudkit.hkSanitizeReupload.v1.done") {
            for entry in manager.archive.entries { manager.state.markUploaded(entry.sessionId) }
            await manager.state.saveSyncStateAsync()
        }
        let snapshot = manager.state.uploadedSessionIds.map(\.uuidString)
        defaults.set(snapshot, forKey: Self.remainingKey)
        defaults.set(true, forKey: Self.initializedKey)
        Self.legacyKeys.forEach(defaults.removeObject(forKey:))
        debugLog("[CloudKit] Health scrub list initialized — \(snapshot.count) records to rewrite")
    }

    // MARK: - iCloud Sync on

    /// Mark the next batch for upload again, so the push overwrites each
    /// record with the stripped payload. Only records still believed to be in
    /// iCloud are marked; anything else is already pending (it uploads
    /// stripped) or deleted.
    func dripReupload() async {
        var remaining = await remainingIds()
        guard !remaining.isEmpty else { return }
        var marked = 0
        while marked < Self.batchSize, !remaining.isEmpty {
            let idString = remaining.removeFirst()
            guard let id = UUID(uuidString: idString), manager.state.uploadedSessionIds.contains(id) else { continue }
            manager.state.markRemoved(id)
            marked += 1
        }
        defaults.set(remaining, forKey: Self.remainingKey)
        if marked > 0 {
            await manager.state.saveSyncStateAsync()
            debugLog("[CloudKit] Health scrub: re-marked \(marked) for upload, \(remaining.count) remaining")
        }
    }

    // MARK: - iCloud Sync off

    /// Rewrite the next batch in place. The caller has checked that an iCloud
    /// account is available.
    func scrubInPlace() async {
        var remaining = await remainingIds()
        var handled = 0
        while handled < Self.batchSize, let idString = remaining.first {
            guard await scrub(idString) == .finished else { break }
            remaining.removeFirst()
            handled += 1
        }
        defaults.set(remaining, forKey: Self.remainingKey)
        if handled > 0 {
            debugLog("[CloudKit] Health scrub (sync off): \(handled) records handled, \(remaining.count) remaining")
        }
    }

    /// Fetch one record and rewrite it. A record no longer in iCloud needs
    /// nothing.
    private func scrub(_ idString: String) async -> Outcome {
        guard let id = UUID(uuidString: idString), manager.state.uploadedSessionIds.contains(id) else { return .finished }
        let recordID = CKRecord.ID(recordName: idString, zoneID: manager.zoneID)
        do {
            let record = try await manager.privateDB.record(for: recordID)
            return try await rewrite(record, sessionId: id)
        } catch let error as CKError where Self.meansNoRecord(error) {
            return .finished
        } catch {
            debugLog("[CloudKit] Health scrub: \(idString.prefix(8)) not rewritten yet: \(error.localizedDescription)", level: .warning)
            return .retryLater
        }
    }

    /// Replace the record's payload with its own contents stripped, or delete
    /// it when the session came out of Apple Health whole. The record keeps
    /// its edit stamp, so no device takes it for a newer copy.
    private func rewrite(_ record: CKRecord, sessionId: UUID) async throws -> Outcome {
        guard (record["isDeleted"] as? Int64 ?? 0) == 0,
              let session = await Self.storedSession(in: record) else { return .finished }
        if CloudSessionPayload.isHealthKitSourced(session) {
            try await manager.privateDB.deleteRecord(withID: record.recordID)
            manager.state.markLocalOnly(sessionId)
            await manager.state.saveLocalOnlyAsync()
            await manager.state.saveSyncStateAsync()
            return .finished
        }
        record["sessionData"] = try await Task.detached(priority: .utility) {
            try CloudKitSyncManager.sessionAsset(for: session)
        }.value
        defer { manager.cleanupTempAsset(for: record) }
        // A save that loses to another device's newer save throws
        // `.serverRecordChanged`; the id stays listed and the next pass
        // fetches that newer copy.
        try await manager.privateDB.save(record)
        return .finished
    }

    /// The session a record holds; nil, logged, when this device cannot read
    /// it (sealed with another device's key, or damaged). The device that
    /// wrote it rewrites it.
    private static func storedSession(in record: CKRecord) async -> HRVSession? {
        guard let assetURL = (record["sessionData"] as? CKAsset)?.fileURL else { return nil }
        do {
            return try await Task.detached(priority: .utility) {
                try CloudPullCoordinator.decodeSessionAsset(at: assetURL)
            }.value
        } catch {
            debugLog("[CloudKit] Health scrub: \(record.recordID.recordName.prefix(8)) is unreadable here (\(error.localizedDescription)) — left to the device that wrote it", level: .warning)
            return nil
        }
    }

    /// The record, or the whole zone, is not in iCloud.
    static func meansNoRecord(_ error: CKError) -> Bool {
        [.unknownItem, .zoneNotFound, .userDeletedZone].contains(error.code)
    }
}
