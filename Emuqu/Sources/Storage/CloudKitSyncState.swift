import Foundation

/// Manages durable sync state for CloudKitSyncManager: which sessions have been
/// uploaded, which are pending retry, and failure counts for backoff.
///
/// Extracted from CloudKitSyncManager to isolate persistence I/O from sync logic.
///
/// No `CKServerChangeToken` is persisted here: `CloudKitSyncManager.pullRemoteChanges()`
/// uses a `CKQuery` + cursor pagination path rather than
/// `CKFetchRecordZoneChangesOperation`.
struct CloudKitSyncState {

    /// Session IDs that have been successfully uploaded to CloudKit
    var uploadedSessionIds: Set<UUID> = []

    /// Session IDs that failed to upload and need retry
    var pendingUploadIds: Set<UUID> = []

    /// Session IDs QUARANTINED from upload because they hit a PERMANENT prep
    /// error (integrity hash mismatch / newer-schema) that retrying can never
    /// fix. Kept OUT of the pending set so they stop re-attempting every sync
    /// (the repeated "prep failed … integrity check failed" log spam), but the
    /// session file on disk is UNTOUCHED — quarantine is reversible via
    /// `clearQuarantine`, and surfaced to the user via
    /// `CloudKitSyncManager.quarantinedCount`. No silent data loss.
    var quarantinedSessionIds: Set<UUID> = []

    /// Consecutive failures per session for exponential backoff
    var uploadFailureCounts: [UUID: Int] = [:]

    private let syncStateURL: URL
    private var pendingQueueURL: URL {
        syncStateURL.deletingLastPathComponent().appendingPathComponent("pending_uploads.json")
    }

    private var quarantineQueueURL: URL {
        syncStateURL.deletingLastPathComponent().appendingPathComponent("quarantined_uploads.json")
    }

    init(syncStateURL: URL) {
        self.syncStateURL = syncStateURL
    }

    // MARK: - Load

    mutating func loadAll() {
        loadSyncState()
        loadPendingQueue()
        loadQuarantineQueue()
        // Clean up any change-token blob left over from an earlier revision —
        // the field is gone, so wipe the UserDefaults value so it doesn't
        // accumulate as orphan bytes on legacy installs.
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.cloudKitChangeToken)
    }

    private mutating func loadSyncState() {
        guard FileManager.default.fileExists(atPath: syncStateURL.path) else { return }
        do {
            let data = try Data(contentsOf: syncStateURL)
            let uuidStrings = try JSONDecoder().decode([String].self, from: data)
            uploadedSessionIds = Set(uuidStrings.compactMap { UUID(uuidString: $0) })
            debugLog("[CloudKit] Loaded sync state: \(uploadedSessionIds.count) uploaded sessions")
        } catch {
            debugLog("[CloudKit] Failed to load sync state: \(error)")
        }
    }

    private mutating func loadPendingQueue() {
        guard FileManager.default.fileExists(atPath: pendingQueueURL.path) else { return }
        do {
            let data = try Data(contentsOf: pendingQueueURL)
            let uuidStrings = try JSONDecoder().decode([String].self, from: data)
            pendingUploadIds = Set(uuidStrings.compactMap { UUID(uuidString: $0) })
            debugLog("[CloudKit] Loaded pending queue: \(pendingUploadIds.count) sessions awaiting retry")
        } catch {
            debugLog("[CloudKit] Failed to load pending queue: \(error)")
        }
    }

    private mutating func loadQuarantineQueue() {
        guard FileManager.default.fileExists(atPath: quarantineQueueURL.path) else { return }
        do {
            let data = try Data(contentsOf: quarantineQueueURL)
            let uuidStrings = try JSONDecoder().decode([String].self, from: data)
            quarantinedSessionIds = Set(uuidStrings.compactMap { UUID(uuidString: $0) })
            if !quarantinedSessionIds.isEmpty {
                debugLog("[CloudKit] Loaded quarantine: \(quarantinedSessionIds.count) corrupt session(s) held back from sync")
            }
        } catch {
            debugLog("[CloudKit] Failed to load quarantine queue: \(error)")
        }
    }

    // MARK: - Save
    //
    // Both saves are offered in async (preferred) and sync flavors. The async
    // variants snapshot the relevant IDs on the calling actor and hop to a
    // background thread for the JSON encode + atomic write. The sync variants
    // remain for callers that are already off the main thread.

    func saveSyncState() {
        Self.writeUUIDsSync(uploadedSessionIds, to: syncStateURL, label: "sync state")
    }

    func saveSyncStateAsync() async {
        let snapshot = uploadedSessionIds
        let url = syncStateURL
        await Task.detached(priority: .utility) {
            Self.writeUUIDsSync(snapshot, to: url, label: "sync state")
        }.value
    }

    func savePendingQueue() {
        Self.writeUUIDsSync(pendingUploadIds, to: pendingQueueURL, label: "pending queue")
    }

    func savePendingQueueAsync() async {
        let snapshot = pendingUploadIds
        let url = pendingQueueURL
        await Task.detached(priority: .utility) {
            Self.writeUUIDsSync(snapshot, to: url, label: "pending queue")
        }.value
    }

    func saveQuarantineQueue() {
        Self.writeUUIDsSync(quarantinedSessionIds, to: quarantineQueueURL, label: "quarantine queue")
    }

    func saveQuarantineQueueAsync() async {
        let snapshot = quarantinedSessionIds
        let url = quarantineQueueURL
        await Task.detached(priority: .utility) {
            Self.writeUUIDsSync(snapshot, to: url, label: "quarantine queue")
        }.value
    }

    private static func writeUUIDsSync(_ ids: Set<UUID>, to url: URL, label: String) {
        do {
            let uuidStrings = ids.map { $0.uuidString }
            let data = try JSONEncoder().encode(uuidStrings)
            try data.write(to: url, options: .atomic)
        } catch {
            debugLog("[CloudKit] Failed to save \(label): \(error)")
        }
    }

    // MARK: - Mutation Helpers

    mutating func markUploaded(_ sessionId: UUID) {
        _ = uploadedSessionIds.insert(sessionId)
        _ = pendingUploadIds.remove(sessionId)
        uploadFailureCounts.removeValue(forKey: sessionId)
    }

    mutating func markFailed(_ sessionId: UUID) {
        _ = pendingUploadIds.insert(sessionId)
        uploadFailureCounts[sessionId, default: 0] += 1
    }

    /// Clear a session's accumulated failure count so it retries promptly (no
    /// backoff) on the next cycle — used after a self-repair fixes a previously
    /// permanent failure so the long prior backoff doesn't delay the now-good upload.
    mutating func clearFailureCount(_ sessionId: UUID) {
        uploadFailureCounts.removeValue(forKey: sessionId)
    }

    /// Quarantine a session whose upload prep hit a PERMANENT error (corrupt
    /// file / newer schema). Removes it from the retry set so it stops spamming
    /// the sync every cycle; the file on disk is left intact (reversible).
    mutating func markQuarantined(_ sessionId: UUID) {
        _ = quarantinedSessionIds.insert(sessionId)
        _ = pendingUploadIds.remove(sessionId)
        uploadFailureCounts.removeValue(forKey: sessionId)
    }

    /// Reversible un-quarantine so the session is re-attempted next sync (e.g. a
    /// user "retry" action, or after the file is repaired). Pass nil to clear all.
    mutating func clearQuarantine(_ sessionId: UUID? = nil) {
        if let sessionId {
            _ = quarantinedSessionIds.remove(sessionId)
        } else {
            quarantinedSessionIds.removeAll()
        }
    }

    mutating func markRemoved(_ sessionId: UUID) {
        _ = uploadedSessionIds.remove(sessionId)
    }

    /// The session no longer exists — deleted on this device or another. Unlike
    /// `markRemoved`, which means "upload it again", nothing about it is left
    /// to push: a pending id for a deleted session would be retried, fail to
    /// retrieve, and be retried again on every cycle.
    mutating func markDeleted(_ sessionId: UUID) {
        _ = uploadedSessionIds.remove(sessionId)
        _ = pendingUploadIds.remove(sessionId)
        uploadFailureCounts.removeValue(forKey: sessionId)
    }

    /// Wipe all in-memory and on-disk sync state. Called by the user-initiated
    /// "Delete All My Data" Settings action. Does NOT touch remote CloudKit
    /// records — `CloudKitSyncManager.deleteAllRemoteData()` handles those
    /// (it deletes the custom zones, then calls back into this reset).
    mutating func resetAll() {
        uploadedSessionIds.removeAll()
        pendingUploadIds.removeAll()
        quarantinedSessionIds.removeAll()
        uploadFailureCounts.removeAll()
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.cloudKitChangeToken)
        let fm = FileManager.default
        _ = attempt("CloudKitSyncState.remove") { try fm.removeItem(at: syncStateURL) }
        _ = attempt("CloudKitSyncState.remove") { try fm.removeItem(at: pendingQueueURL) }
        _ = attempt("CloudKitSyncState.remove") { try fm.removeItem(at: quarantineQueueURL) }
    }
}
