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

    /// Session IDs that stay on this device because they were read out of
    /// Apple Health whole (`CloudSessionPayload.isHealthKitSourced`). Kept out
    /// of every push, so each is examined once rather than on every cycle.
    var localOnlySessionIds: Set<UUID> = []

    /// Consecutive failures per session for exponential backoff. In memory
    /// only: a relaunch starts every session's backoff over.
    var uploadFailureCounts: [UUID: Int] = [:]

    /// The server record version (`CKRecord.recordChangeTag`) each session's
    /// copy here matches: set when this device saves the record or imports
    /// it. Two copies stamped in the same second are told apart by it
    /// (`CloudKitSessionFreshness.onTie`). Written with the uploaded set.
    private(set) var recordVersions: [UUID: String] = [:]

    /// False until `loadAll` has read the files (or `resetAll` emptied
    /// them). The saves wait for it: written before then, the near-empty
    /// in-memory sets replaced `sync_state.json`, and the load that followed
    /// re-pushed the whole archive.
    private(set) var isLoaded = false

    /// Ids taken out of the uploaded / pending sets before `loadAll`. The
    /// merge with the files must not put them back: a re-upload request
    /// (`markRemoved`) made during launch migrations would otherwise be
    /// re-marked uploaded from `sync_state.json` and never pushed.
    private var uploadedRemovedBeforeLoad: Set<UUID> = []
    private var pendingRemovedBeforeLoad: Set<UUID> = []

    private let syncStateURL: URL
    private var pendingQueueURL: URL {
        syncStateURL.deletingLastPathComponent().appendingPathComponent("pending_uploads.json")
    }

    private var quarantineQueueURL: URL {
        syncStateURL.deletingLastPathComponent().appendingPathComponent("quarantined_uploads.json")
    }

    private var localOnlyURL: URL {
        syncStateURL.deletingLastPathComponent().appendingPathComponent("local_only_sessions.json")
    }

    private var recordVersionsURL: URL {
        syncStateURL.deletingLastPathComponent().appendingPathComponent("record_versions.json")
    }

    init(syncStateURL: URL) {
        self.syncStateURL = syncStateURL
    }

    // MARK: - Load

    /// Merges what is on disk into the in-memory sets, so a mark made before
    /// the load (an upload, a re-upload request, a deletion) is kept rather
    /// than replaced: ids added before the load stay, and ids removed before
    /// it are not read back from the files.
    mutating func loadAll() {
        loadSyncState()
        loadPendingQueue()
        loadQuarantineQueue()
        localOnlySessionIds.formUnion(Self.readUUIDs(at: localOnlyURL, label: "local-only list"))
        recordVersions.merge(Self.readVersions(at: recordVersionsURL)) { current, _ in current }
        isLoaded = true
        uploadedRemovedBeforeLoad.removeAll()
        pendingRemovedBeforeLoad.removeAll()
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
            uploadedSessionIds.formUnion(Set(uuidStrings.compactMap { UUID(uuidString: $0) }).subtracting(uploadedRemovedBeforeLoad))
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
            pendingUploadIds.formUnion(Set(uuidStrings.compactMap { UUID(uuidString: $0) }).subtracting(pendingRemovedBeforeLoad))
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
            quarantinedSessionIds.formUnion(uuidStrings.compactMap { UUID(uuidString: $0) })
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
        guard isLoaded else { return Self.logSkippedSave("sync state") }
        Self.writeUUIDsSync(uploadedSessionIds, to: syncStateURL, label: "sync state")
        Self.writeVersionsSync(recordVersions, to: recordVersionsURL)
    }

    func saveSyncStateAsync() async {
        guard isLoaded else { return Self.logSkippedSave("sync state") }
        let snapshot = uploadedSessionIds
        let versions = recordVersions
        let url = syncStateURL
        let versionsURL = recordVersionsURL
        await Task.detached(priority: .utility) {
            Self.writeUUIDsSync(snapshot, to: url, label: "sync state")
            Self.writeVersionsSync(versions, to: versionsURL)
        }.value
    }

    func savePendingQueue() {
        guard isLoaded else { return Self.logSkippedSave("pending queue") }
        Self.writeUUIDsSync(pendingUploadIds, to: pendingQueueURL, label: "pending queue")
    }

    func savePendingQueueAsync() async {
        guard isLoaded else { return Self.logSkippedSave("pending queue") }
        let snapshot = pendingUploadIds
        let url = pendingQueueURL
        await Task.detached(priority: .utility) {
            Self.writeUUIDsSync(snapshot, to: url, label: "pending queue")
        }.value
    }

    func saveQuarantineQueue() {
        guard isLoaded else { return Self.logSkippedSave("quarantine queue") }
        Self.writeUUIDsSync(quarantinedSessionIds, to: quarantineQueueURL, label: "quarantine queue")
    }

    func saveQuarantineQueueAsync() async {
        guard isLoaded else { return Self.logSkippedSave("quarantine queue") }
        let snapshot = quarantinedSessionIds
        let url = quarantineQueueURL
        await Task.detached(priority: .utility) {
            Self.writeUUIDsSync(snapshot, to: url, label: "quarantine queue")
        }.value
    }

    func saveLocalOnlyAsync() async {
        guard isLoaded else { return Self.logSkippedSave("local-only list") }
        let snapshot = localOnlySessionIds
        let url = localOnlyURL
        await Task.detached(priority: .utility) {
            Self.writeUUIDsSync(snapshot, to: url, label: "local-only list")
        }.value
    }

    /// The ids stored at `url`; empty, with the failure logged, when the file
    /// is missing or unreadable.
    private static func readUUIDs(at url: URL, label: String) -> Set<UUID> {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let uuidStrings = try JSONDecoder().decode([String].self, from: Data(contentsOf: url))
            return Set(uuidStrings.compactMap(UUID.init(uuidString:)))
        } catch {
            debugLog("[CloudKit] Failed to load \(label): \(error)")
            return []
        }
    }

    /// The versions stored at `url`; empty, with the failure logged, when the
    /// file is missing or unreadable. Every session then counts as one whose
    /// version is not known (`CloudKitSessionFreshness.onTie`).
    private static func readVersions(at url: URL) -> [UUID: String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            return keyedByUUID(try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url)))
        } catch {
            debugLog("[CloudKit] Failed to load record versions: \(error)")
            return [:]
        }
    }

    /// The stored map with its keys parsed; a key that is not a UUID is
    /// dropped, and of two spellings of one UUID the first is kept.
    private static func keyedByUUID(_ stored: [String: String]) -> [UUID: String] {
        let pairs = stored.compactMap { idString, version in UUID(uuidString: idString).map { ($0, version) } }
        return Dictionary(pairs) { first, _ in first }
    }

    private static func writeVersionsSync(_ versions: [UUID: String], to url: URL) {
        do {
            let stored = Dictionary(uniqueKeysWithValues: versions.map { ($0.key.uuidString, $0.value) })
            try JSONEncoder().encode(stored).write(to: url, options: .atomic)
        } catch {
            debugLog("[CloudKit] Failed to save record versions: \(error)")
        }
    }

    /// The marks stay in memory and are written by the first save after
    /// `loadAll` merges them with the files.
    private static func logSkippedSave(_ label: String) {
        debugLog("[CloudKit] \(label) save held until the sync state has loaded")
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
        removePending(sessionId)
        uploadFailureCounts.removeValue(forKey: sessionId)
    }

    /// Out of the uploaded set, and kept out of the load's merge.
    private mutating func removeUploaded(_ sessionId: UUID) {
        _ = uploadedSessionIds.remove(sessionId)
        if !isLoaded { uploadedRemovedBeforeLoad.insert(sessionId) }
    }

    /// Out of the pending set, and kept out of the load's merge.
    private mutating func removePending(_ sessionId: UUID) {
        _ = pendingUploadIds.remove(sessionId)
        if !isLoaded { pendingRemovedBeforeLoad.insert(sessionId) }
    }

    /// The server version this device's copy now matches, after it saved the
    /// record or imported it. A save or fetch that returned no change tag
    /// leaves the version as it was.
    mutating func noteRecordVersion(_ version: String?, of sessionId: UUID) {
        guard let version else { return }
        recordVersions[sessionId] = version
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
        removePending(sessionId)
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

    /// "Upload it again." Pending as well as not-uploaded: the pull re-marks
    /// any session that exists both here and in iCloud as uploaded, which is
    /// right for one this device never changed and wrong for one it did — the
    /// pending flag is how the pull tells the two apart, and without it edits
    /// queued behind the 25-per-cycle push limit never left the device.
    mutating func markRemoved(_ sessionId: UUID) {
        removeUploaded(sessionId)
        _ = pendingUploadIds.insert(sessionId)
    }

    /// The session stays on this device: nothing about it is pushed, and it
    /// does not count as uploaded.
    mutating func markLocalOnly(_ sessionId: UUID) {
        _ = localOnlySessionIds.insert(sessionId)
        removeUploaded(sessionId)
        removePending(sessionId)
        uploadFailureCounts.removeValue(forKey: sessionId)
    }

    /// The session no longer exists — deleted on this device or another. Unlike
    /// `markRemoved`, which means "upload it again", nothing about it is left
    /// to push: a pending id for a deleted session would be retried, fail to
    /// retrieve, and be retried again on every cycle.
    mutating func markDeleted(_ sessionId: UUID) {
        removeUploaded(sessionId)
        removePending(sessionId)
        uploadFailureCounts.removeValue(forKey: sessionId)
        recordVersions.removeValue(forKey: sessionId)
    }

    /// Wipe all in-memory and on-disk sync state. Called by the user-initiated
    /// "Delete All My Data" Settings action. Does NOT touch remote CloudKit
    /// records — `CloudKitSyncManager.deleteAllRemoteData()` handles those
    /// (it deletes the custom zones, then calls back into this reset).
    mutating func resetAll() {
        isLoaded = true
        uploadedSessionIds.removeAll()
        pendingUploadIds.removeAll()
        quarantinedSessionIds.removeAll()
        localOnlySessionIds.removeAll()
        uploadFailureCounts.removeAll()
        recordVersions.removeAll()
        uploadedRemovedBeforeLoad.removeAll()
        pendingRemovedBeforeLoad.removeAll()
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.cloudKitChangeToken)
        let fm = FileManager.default
        _ = attempt("CloudKitSyncState.remove") { try fm.removeItem(at: syncStateURL) }
        _ = attempt("CloudKitSyncState.remove") { try fm.removeItem(at: pendingQueueURL) }
        _ = attempt("CloudKitSyncState.remove") { try fm.removeItem(at: quarantineQueueURL) }
        _ = attempt("CloudKitSyncState.remove") { try fm.removeItem(at: localOnlyURL) }
        _ = attempt("CloudKitSyncState.remove") { try fm.removeItem(at: recordVersionsURL) }
    }
}
