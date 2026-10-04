import CloudKit
import Combine
import Foundation
import os
import UIKit

/// Manages iCloud sync of HRV sessions via CloudKit private database.
/// Sessions upload after each completed recording. New devices pull all history on first launch.
/// Offline-first — CloudKit is best-effort, never blocks the app.
@Observable
@MainActor
final class CloudKitSyncManager {

    // MARK: - Singleton

    static let shared = CloudKitSyncManager()

    // MARK: - Published State

    private(set) var syncState: SyncState = .idle
    /// Timestamp the syncState entered `.syncing`. Used to detect a
    /// stuck sync — see the "Sync timed out" path in `performFullSync`.
    /// Reset to nil whenever syncState transitions back to .idle or .error.
    private var syncingStartedAt: Date?
    /// Sticky for this app launch: set when CloudKit rejects a save/fetch
    /// because the record type isn't in the production schema yet. Once
    /// this is true, push/pull/delete/live-backup short-circuit until the
    /// app is restarted — without this, a permanent server-side
    /// configuration error spins forever, hammering battery and stalling
    /// the main actor (each retry runs retrieve+decrypt+encode+compress
    /// per session). A beta log showed 100+
    /// "Cannot create new type X in production schema" errors over 5
    /// days against the same backlog of 107 pending sessions.
    var schemaUnavailable = false
    /// Uploaded sessions the previous pull's listing did not contain. Only a
    /// session missing from two listings in a row is queued again: the query
    /// index updates asynchronously, so one just saved by the push can be
    /// absent from the listing that follows it.
    var missingFromLastListing: Set<UUID> = []
    /// Most recent CloudKit error message that user code may want to
    /// surface — typically the schema-promotion error. Decoupled from
    /// `syncState` so transient UI status doesn't clobber it.
    private(set) var lastPermanentErrorMessage: String?
    /// Set by `pullRemoteChanges()` when the pull failed for a reason its
    /// internal catch would otherwise swallow with a debug log. Without it the
    /// full-sync body treated a swallowed pull failure as success: it
    /// stamped `lastSyncDate` and showed "Up to date" while cross-device
    /// restore never worked (the beta-user symptom: uploads fine, nothing
    /// ever comes down). Checked in `performFullSyncBody` so a failed pull
    /// surfaces as `.error` and does NOT advance `lastSyncDate`.
    var lastPullErrorMessage: String?

    /// Detect CloudKit errors that won't resolve without server-side action
    /// (schema promotion, container changes). Recognizing these stops the
    /// retry storm against an unfixable error.
    ///
    /// Patterns:
    ///   • "Cannot create new type <RecordType> in production schema" — the
    ///     record type was added in Development but not promoted to
    ///     Production. Every save fails forever until the developer
    ///     promotes the schema in the CloudKit Dashboard.
    ///   • "Did not find record type: <RecordType>" — same root cause, pull
    ///     side.
    ///   • "Field … not marked indexable / queryable / sortable" — index
    ///     missing in Production. Real CloudKit messages for
    ///     the pull path's `CKQuery` say "is not marked queryable" and
    ///     "is not marked sortable" — matching on "indexable" alone
    ///     let those slip past the breaker, so a production container
    ///     missing the `startDate` index failed the pull silently forever
    ///     while Settings showed "Up to date".
    ///
    /// All of these reach the device as `CKError.serverRejectedRequest`, but
    /// we also match by message text so a future code change in the
    /// CloudKit SDK doesn't silently break the detection.
    static func isPermanentSchemaError(_ error: Error) -> Bool {
        if let ckError = error as? CKError, let partial = ckError.partialErrorsByItemID {
            for (_, inner) in partial where isPermanentSchemaError(inner) {
                return true
            }
        }
        let text = (error as NSError).localizedDescription
        let messageMatches = text.contains("Cannot create new type")
            || text.contains("Did not find record type")
            || text.contains("not marked indexable")
            || text.contains("not marked queryable")
            || text.contains("not marked sortable")
        guard messageMatches else { return false }
        if let ckError = error as? CKError {
            return ckError.code == .serverRejectedRequest
                || ckError.code == .invalidArguments
                || ckError.code == .unknownItem
        }
        return true
    }
    /// Hard ceiling on how long a sync body can run before the watchdog
    /// resets it. 120s covers a legitimate full sync of a few hundred
    /// records on a slow network; anything beyond that is hung.
    private let syncStuckThresholdSec: TimeInterval = 120
    /// Timestamp of the last observed sync PROGRESS (a pushed record, a pulled
    /// page, a processed remote record). The body watchdog (`withProgressWatchdog`)
    /// fails the sync only when this goes stale by `syncStuckThresholdSec` — i.e.
    /// genuinely wedged — instead of a fixed wall-clock deadline that guillotined
    /// slow-but-progressing syncs. Field log: successful syncs ran
    /// 95–118s against a 120s cap, and 3 of 9 tipped over and "failed" while
    /// still pushing/pulling records. A sync can take as long as it needs as
    /// long as it keeps moving.
    var lastSyncProgressAt: Date = .distantPast
    func noteSyncProgress() { lastSyncProgressAt = Date() }
    // There is no per-call timeout; the "stuck at .syncing forever"
    // protection is the BODY-level timeout above (`syncStuckThresholdSec`).
    /// Incremented each time pullRemoteChanges() archives new sessions.
    /// Observers (e.g. MainTabView) can trigger a session refresh on change.
    var pullVersion: Int = 0
    private(set) var lastSyncDate: Date? {
        didSet {
            if let date = lastSyncDate {
                UserDefaults.standard.set(date, forKey: UserDefaultsKeys.cloudKitLastSyncDate)
            } else {
                UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.cloudKitLastSyncDate)
            }
        }
    }

    enum SyncState: Equatable {
        case idle
        case syncing
        case error(String)
    }

    // MARK: - CloudKit Configuration

    private let container = CKContainer(identifier: AppConfig.iCloudContainerIdentifier)
    var privateDB: CKDatabase { container.privateCloudDatabase }
    let recordType = "HRVSession"
    let zoneID = CKRecordZone.ID(zoneName: "HRVSessions", ownerName: CKCurrentUserDefaultName)

    // MARK: - Local State

    var state: CloudKitSyncState

    // MARK: - Public State Accessors (for UI status indicators)

    /// Has this session been uploaded to iCloud? O(1) set lookup.
    func isUploaded(_ sessionId: UUID) -> Bool {
        state.uploadedSessionIds.contains(sessionId)
    }

    /// Is this session currently queued for a retry upload?
    func isPendingRetry(_ sessionId: UUID) -> Bool {
        state.pendingUploadIds.contains(sessionId)
    }

    /// Count of sessions whose upload has failed and is awaiting retry.
    /// Used by the dashboard to show "N syncs pending" status.
    var pendingUploadCount: Int {
        state.pendingUploadIds.count
    }

    /// Count of sessions QUARANTINED from sync due to a permanent prep failure
    /// (corrupt file / newer schema). Non-zero means data exists locally that
    /// cannot sync — surface it (Settings/Troubleshooting) so the user knows,
    /// rather than silently dropping it. Reversible via `retryQuarantined()`.
    var quarantinedCount: Int {
        state.quarantinedSessionIds.count
    }

    /// The quarantined session IDs (for a Settings list / diagnostics).
    var quarantinedSessionIds: [UUID] {
        Array(state.quarantinedSessionIds)
    }

    /// User-initiated un-quarantine: clear the hold so the session(s) are
    /// re-attempted next sync (e.g. after the file is repaired, or to force a
    /// retry). Pass nil to clear all. Persists immediately.
    func retryQuarantined(_ sessionId: UUID? = nil) {
        state.clearQuarantine(sessionId)
        state.saveQuarantineQueue()
    }

    /// Total synced session count (for Settings summary).
    var uploadedCount: Int {
        state.uploadedSessionIds.count
    }

    /// Whether iCloud sync is enabled in user settings. It does not check the
    /// iCloud account or the container; failures there surface through
    /// `syncState`. Used to decide whether to show sync status UI or grey it out.
    var isCloudKitAvailable: Bool {
        settingsManager.settings.iCloudSyncEnabled
    }
    @ObservationIgnored private(set) lazy var liveBackup = CloudKitLiveBackupManager(
        settingsManager: settingsManager,
        ensureZone: { [weak self] in try await self?.ensureZoneExists() ?? () }
    )

    /// Whether the custom zone has been created
    var zoneCreated: Bool {
        get { UserDefaults.standard.bool(forKey: UserDefaultsKeys.cloudKitZoneCreated) }
        set { UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.cloudKitZoneCreated) }
    }

    private let settingsManager: SettingsManager
    let archive: SessionArchive

    /// Serializes concurrent sync operations (upload, delete, full sync) so
    /// they can't interleave at await points and race on `state` mutations.
    /// Not a `while inFlight { Task.yield() }` busy-wait, which pins the
    /// main actor under contention.
    let syncSerializer = SyncSerializer()

    /// Token for the `.CKAccountChanged` observer (sign in/out
    /// of iCloud mid-run). Stored so `deinit` can remove it. Without an
    /// account-change listener, signing out of
    /// iCloud during a session failed silently — sync just stopped working
    /// with no state change the UI could surface.
    @ObservationIgnored private let observers = NotificationTokens()

    private var settings: UserSettings {
        settingsManager.settings
    }

    /// Whether session data may be written to iCloud right now.
    ///
    /// The sync toggle alone is not enough: it defaults to on, and onboarding
    /// asks about iCloud only on its backup page. Until onboarding is finished
    /// the user has not made that choice, so nothing is uploaded. Reading
    /// (the pull) is not gated here — it brings the user's own records back
    /// from their own container and writes nothing about them to it. A session
    /// held back by this gate stays pending and goes up with the next sync.
    var cloudUploadsAllowed: Bool {
        settings.iCloudSyncEnabled && settings.hasCompletedOnboarding
    }

    // MARK: - Init

    private init(
        settingsManager: SettingsManager = AppDependencies.current.app.settingsManager,
        archive: SessionArchive = AppDependencies.current.storage.sessionArchive
    ) {
        self.settingsManager = settingsManager
        self.archive = archive
        // Cold-start: keep init lightweight — only
        // construct the URL + empty state container. The disk read of
        // sync_state.json (potentially KB of uploaded-session UUIDs) is
        // deferred to boot(), which fires from `RootView.task` after first
        // frame paints. `CloudKitSyncState` holds its saves until that load,
        // so a CloudKit upload that lands during the boot gap doesn't
        // overwrite the file and trigger a re-upload of every session.
        state = CloudKitSyncState(syncStateURL: Self.resolveSyncStateURL())
        observeReuploadSignals()
        observers.add(Self.observeAccountChanges { [weak self] in
            Task { @MainActor [weak self] in await self?.handleAccountChange() }
        })
    }

    /// React to iCloud account changes (sign out / switch Apple ID
    /// mid-run). Without this, a signed-out account silently breaks sync with no
    /// UI feedback. On fire we re-check the container account status and surface
    /// a signed-out state via the existing error fields the UI already reads.
    private static func observeAccountChanges(_ handler: @escaping @Sendable () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { _ in handler() }
    }

    deinit { observers.removeAll() }

    /// Re-check the CloudKit account status after `.CKAccountChanged` and
    /// reflect it in sync state. A signed-out / restricted account surfaces
    /// as `.error` (read by the same UI as every other sync error) rather
    /// than failing silently; a recovered `.available` account clears the
    /// account-related error and triggers a fresh sync so the new Apple ID's
    /// data pulls down.
    ///
    /// `.temporarilyUnavailable` is transient (iCloud briefly unreachable) so
    /// it stamps no permanent error — the next sync retries. It is handled
    /// explicitly because it's a KNOWN case: `@unknown default` covers only
    /// future/unknown values, so leaving it out tripped "switch must be
    /// exhaustive" (a warning under Swift 5, a hard error under stricter
    /// concurrency settings).
    private func handleAccountChange() async {
        let status: CKAccountStatus
        do {
            status = try await container.accountStatus()
        } catch {
            debugLog("[CloudKit] Account change: status check failed: \(error.localizedDescription)", level: .warning)
            return
        }
        switch status {
        case .available:
            await resumeSyncForAvailableAccount()
        case .noAccount, .restricted, .couldNotDetermine:
            pauseSyncForUnusableAccount(status)
        case .temporarilyUnavailable:
            debugLog("[CloudKit] Account change: iCloud temporarily unavailable — will retry on next sync", level: .warning)
        @unknown default:
            break
        }
    }

    /// Clear any stale account-related error so the UI stops showing
    /// "Not signed into iCloud", then refresh. Deliberately does NOT wipe
    /// local sync bookkeeping: `.CKAccountChanged` also fires on a transient
    /// drop/reconnect of the SAME account, and `resetLocalSyncState()` would
    /// force a full re-push of the entire archive every time — exactly the
    /// launch/foreground hammering this app avoids. The pull re-marks remote
    /// records as uploaded and queues anything the remote listing is missing
    /// (`reuploadSessionsMissingFromCloud`), so a normal `performFullSync()`
    /// reconciles a switched account without the brute-force reset.
    private func resumeSyncForAvailableAccount() async {
        debugLog("[CloudKit] Account change: iCloud account available — refreshing sync")
        if case .error = syncState { syncState = .idle }
        if lastPermanentErrorMessage == CloudSyncMessages.notSignedIn {
            lastPermanentErrorMessage = nil
        }
        await performFullSync()
    }

    /// Surface via the same `syncState`/error path the rest of the UI reads,
    /// and stamp the permanent-error field so Settings shows why sync stopped
    /// instead of silently no-op'ing.
    private func pauseSyncForUnusableAccount(_ status: CKAccountStatus) {
        let message = CloudSyncMessages.notSignedIn
        debugLog("[CloudKit] Account change: no usable iCloud account (\(status.rawValue)) — pausing sync", level: .warning)
        syncState = .error(message)
        lastPermanentErrorMessage = message
        syncingStartedAt = nil
    }

    /// Cold-start: post-first-frame catch-up. Loads
    /// the persisted sync state from disk (uploaded-session set, pending
    /// queue, change tokens) and reads `lastSyncDate` from UserDefaults.
    /// Idempotent — subsequent calls short-circuit on `didBootSyncState`.
    @MainActor
    func boot() {
        guard !didBootSyncState.withLock({ $0 }) else { return }
        didBootSyncState.withLock { $0 = true }
        state.loadAll()
        lastSyncDate = UserDefaults.standard.object(forKey: UserDefaultsKeys.cloudKitLastSyncDate) as? Date
    }

    @ObservationIgnored private let didBootSyncState = OSAllocatedUnfairLock(initialState: false)

    /// Wipe local sync state (uploaded set, pending queue, change tokens,
    /// zone-created flag). Called by the user-initiated "Delete All My Data"
    /// Settings action. Local bookkeeping only — remote CloudKit records
    /// are removed by `deleteAllRemoteData()`, which calls this on success
    /// (the purge flow also calls it directly so local state resets even
    /// when the remote deletion fails).
    func resetLocalSyncState() {
        state.resetAll()
        zoneCreated = false
        lastSyncDate = nil
        syncState = .idle
    }

    // MARK: - Upload Session

    /// Upload a single session to CloudKit. Called after each archive write.
    /// Fire-and-forget — errors are logged, not thrown.
    /// Serialized: waits for any in-flight sync operation to avoid state mutation races.
    ///
    /// Upload eligibility:
    ///   • `.complete` sessions always sync (the original gate).
    ///   • Workout sessions also sync regardless of state when they
    ///     carry a `WorkoutMetadata` payload — this picks up partials
    ///     reconstructed by `WorkoutRecoveryService` (state may be
    ///     `.complete` with a `partialDataReason`) AND legacy `.failed`
    ///     workouts that still have meaningful captured data. Without
    ///     this, a strap-died-mid-workout session would archive
    ///     locally but never appear on the user's other devices —
    ///     "I do not see it in iCloud" was the symptom that motivated
    ///     this behaviour.
    ///
    /// The gate applies only to this direct upload, made right after an
    /// archive write. The batch push (`pendingPushBatch`) uploads every
    /// archived entry whatever its state, so a session skipped here still
    /// goes up on the next full sync.
    func uploadSession(_ session: HRVSession) async {
        guard cloudUploadsAllowed else { return }
        // Short-circuit when the CloudKit schema is known not to be in
        // production. Without this, every completed recording triggers a
        // save that's guaranteed to fail with the same error.
        guard !schemaUnavailable else { return }
        let isWorkoutWithData = session.sessionType == .workout && session.workoutMetadata != nil
        guard session.state == .complete || isWorkoutWithData else { return }
        await syncSerializer.run { [self] in
            // Skip if already uploaded
            guard !state.uploadedSessionIds.contains(session.id) else { return }
            await uploadOne(session)
        }
    }

    /// Routes through the SANITIZED off-main builder
    /// (`buildSessionRecord` via `prepareUploadOffMain`) rather than a
    /// separate record builder: a second builder drifts from the
    /// Guideline 5.1.3 HK-snapshot strip, so every FRESH recording
    /// uploads HealthKit-derived sleep/vitals data to iCloud while the batch
    /// push path strips it — the exact duplication-causes-drift bug class.
    /// Side benefit: the 1.5 MB encode+compress runs off the main actor.
    /// `prepareUploadOffMain` retrieves the just-archived copy by id
    /// (uploadSession is documented as "called after each archive write"),
    /// which is the same or fresher data than the in-memory parameter.
    private func uploadOne(_ session: HRVSession) async {
        do {
            try await ensureZoneExists()
            guard let prepared = try await prepareUploadOffMain(sessionId: session.id) else {
                debugLog("[CloudKit] Upload skipped — session \(session.id.uuidString.prefix(8)) no longer in archive")
                return
            }
            let record = prepared.record
            defer { cleanupTempAsset(for: record) }
            try await saveUploadRecord(record, sessionId: session.id)
        } catch {
            await handleUploadError(error, sessionId: session.id)
        }
    }

    /// Saves one prepared record. A conflict is resolved here, with the fields
    /// this device tried to write; any other error is rethrown to the caller.
    private func saveUploadRecord(_ record: CKRecord, sessionId: UUID) async throws {
        do {
            try await privateDB.save(record)
            state.markUploaded(sessionId)
            trashRestore.clear(sessionId)
            await state.saveSyncStateAsync()
        } catch let error as CKError where error.code == .serverRecordChanged {
            await resolveDirectConflict(error, record: record, sessionId: sessionId)
        }
    }

    /// The deletion subsystem, built on each access; it holds no state of its own.
    var deletion: CloudDeletionCoordinator {
        CloudDeletionCoordinator(manager: self)
    }

    /// Forwarders so existing call sites did not change in the same commit as
    /// the move. Behaviour lives in `CloudDeletionCoordinator`.
    func deleteAllRemoteData() async -> Bool {
        await deletion.deleteAllRemoteData()
    }

    func clearSanitizeDripState() {
        deletion.clearSanitizeDripState()
    }

    /// Whether an error means the zone is already gone — used by tests and by
    /// callers deciding whether a delete needs retrying.
    static func isZoneAlreadyGoneError(_ error: Error) -> Bool {
        CloudDeletionCoordinator.isZoneAlreadyGoneError(error)
    }

    /// The pull subsystem, built on each access; it holds no state of its own.
    var pull: CloudPullCoordinator {
        CloudPullCoordinator(manager: self)
    }

    /// Restores from the Trash that must outrank an iCloud tombstone.
    var trashRestore: TrashRestoreCoordinator {
        TrashRestoreCoordinator(manager: self)
    }

    /// Fetch remote changes and merge them locally.
    ///
    /// Forwarder so the one existing call site did not have to change in the
    /// same commit as the move. The behaviour lives in `CloudPullCoordinator`.
    func pullRemoteChanges() async {
        await pull.pullRemoteChanges()
    }

    /// "Record to insert already exists": a fresh CKRecord has no change tag,
    /// so every re-upload of a synced session lands here. The data is on the
    /// server, so it is marked uploaded rather than queued for retry, as the
    /// batch push does.
    /// Re-save a record that lost a revision race on the direct upload path.
    ///
    /// Simply marking the record uploaded here would be wrong: CloudKit
    /// reports `.serverRecordChanged` because the save did NOT happen, so the
    /// server would keep its older contents while local state claimed success. This
    /// path is reached by `forceReuploadSession` after a reanalysis — the one
    /// caller whose entire purpose is replacing what the server already holds.
    ///
    /// The error carries the server's record; re-applying this device's fields
    /// onto it preserves the change tag, which is what makes the save succeed.
    private func resolveDirectConflict(
        _ error: CKError, record: CKRecord, sessionId: UUID
    ) async {
        guard let serverRecord = error.serverRecord else {
            debugLog("[CloudKit] Conflict with no server record for \(sessionId.uuidString.prefix(8)); will retry",
                     level: .error)
            state.markFailed(sessionId)
            await state.saveSyncStateAsync()
            return
        }
        if (serverRecord["isDeleted"] as? Int64 ?? 0) == 1, !trashRestore.isRestored(sessionId) {
            pull.applyDeletionMetDuringUpload(sessionId)
            return
        }
        await saveOverServerRecord(serverRecord, from: record, sessionId: sessionId)
    }

    /// This device's copy wins unless the server's was edited more recently:
    /// every field is written over the server's record, saved with its change tag.
    private func saveOverServerRecord(_ serverRecord: CKRecord, from record: CKRecord, sessionId: UUID) async {
        guard CloudKitSessionFreshness.overwrite(
            serverRecord, with: record, restoring: trashRestore.isRestored(sessionId), yieldingIn: &state
        ) else {
            return await state.saveSyncStateAsync()
        }
        trashRestore.markIfReplacingTombstone(serverRecord, sessionId: sessionId)
        do {
            try await privateDB.save(serverRecord)
            state.markUploaded(sessionId)
            trashRestore.clear(sessionId)
        } catch {
            CloudKitSessionFreshness.noteSaveFailure(error)
            debugLog("[CloudKit] Conflict resolution failed for \(sessionId.uuidString.prefix(8)): \(error)",
                     level: .error)
            state.markFailed(sessionId)
        }
        await state.saveSyncStateAsync()
    }

    private func handleUploadError(_ error: Error, sessionId: UUID) async {
        CloudKitSessionFreshness.noteSaveFailure(error, uploading: sessionId)
        if Self.isPermanentSchemaError(error) {
            flagSchemaUnavailable(reason: error.localizedDescription)
            return
        }
        state.markFailed(sessionId)
        await state.savePendingQueueAsync()
    }

    /// Mark the CloudKit container as unavailable for the rest of this
    /// app launch. The next launch re-evaluates, so a schema promoted in the
    /// meantime is picked up then. The message says only what the user can
    /// see and do; the CloudKit reason goes to the log.
    func flagSchemaUnavailable(reason: String) {
        guard !schemaUnavailable else { return }
        schemaUnavailable = true
        lastPermanentErrorMessage = String(
            localized: "iCloud sync is paused for now. It will try again the next time the app starts.",
            bundle: LanguageManager.appBundle
        )
        syncState = .error(lastPermanentErrorMessage ?? reason)
        debugLog("[CloudKit] Schema unavailable — pausing sync for this app launch. CK error: \(reason)", level: .error)
    }

    /// Force re-upload a session that was previously uploaded (e.g., after a repair).
    /// Stamps the edit, so devices holding the session take this copy, and unmarks it.
    func forceReuploadSession(_ session: HRVSession) async {
        await CloudKitSessionFreshness.stampEdit(of: session.id, in: archive)
        state.markRemoved(session.id)
        await state.saveSyncStateAsync()
        await uploadSession(session)
    }

    private static func resolveSyncStateURL() -> URL {
        let fm = FileManager.default
        if let containerURL = fm.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupIdentifier) {
            return containerURL.appendingPathComponent(AppConfig.archiveDirectoryName).appendingPathComponent("sync_state.json")
        }
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            return docs.appendingPathComponent(AppConfig.archiveDirectoryName).appendingPathComponent("sync_state.json")
        }
        return fm.temporaryDirectory.appendingPathComponent("sync_state.json")
    }

    /// Pick up local-migration signals (e.g. `relinkSameNightSessions` has
    /// rewritten session files in place — their CloudKit copies are now stale
    /// and must be cleared from the uploaded-set so the next sync pushes the
    /// fixed versions).
    private func observeReuploadSignals() {
        NotificationCenter.default.addObserver(
            forName: .flowRecoveryArchiveSessionsNeedReupload,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let ids = note.userInfo?["sessionIds"] as? Set<UUID> else { return }
            Task { [weak self] in await self?.markSessionsForReupload(ids) }
        }
    }

    /// Mark a batch of sessions as needing re-upload. Called after migrations
    /// that rewrite a session file in place (e.g. `relinkSameNightSessions`) —
    /// the local copy is now out of sync with what CloudKit holds and will
    /// silently diverge across devices until these sessions are re-uploaded.
    /// The sessions themselves aren't uploaded here; the next sync pass picks
    /// them up via the normal `pushPendingSessions` path.
    func markSessionsForReupload(_ ids: Set<UUID>) async {
        guard !ids.isEmpty else { return }
        await syncSerializer.run { [self] in
            for id in ids { state.markRemoved(id) }
            await state.saveSyncStateAsync()
            debugLog("[CloudKit] Marked \(ids.count) sessions for re-upload after local migration")
        }
    }

    /// Upload a soft-delete flag for a session. Called when Archive.delete() runs.
    func uploadDeletion(_ sessionId: UUID) async {
        guard settings.iCloudSyncEnabled else { return }

        await syncSerializer.run { [self] in
            await deletion.performUploadDeletion(sessionId: sessionId)
        }
    }

    // MARK: - Full Sync

    /// Perform a full sync: push pending uploads, then pull remote changes.
    /// Called on app launch and when returning to foreground.
    ///
    /// Runs inside a `LogCorrelation` scope so the push/pull/conflict lines it
    /// emits stay distinguishable from a recording's, which is the overlap that
    /// made the "21 days since I had a cloud sync" report so slow to diagnose —
    /// both flows were logging into one undifferentiated stream.
    ///
    /// Diagnostic logging on every entry. A user reported
    /// "21 days since I had a cloud sync" but no error showed in the debug
    /// log, which meant we couldn't tell which of the early-bail conditions
    /// was firing. Every call logs whether it proceeded or why it didn't.
    func performFullSync() async {
        let correlation = LogCorrelation.begin("sync")
        defer { LogCorrelation.end(correlation) }
        if schemaUnavailable {
            debugLog("[CloudKit] performFullSync skipped — schema unavailable (this launch)")
            return
        }
        if syncState == .syncing, !recoverFromStuckSync() {
            debugLog("[CloudKit] performFullSync skipped — already syncing")
            return
        }
        guard settings.iCloudSyncEnabled else {
            debugLog("[CloudKit] performFullSync skipped — iCloud Sync setting is OFF")
            syncState = .idle
            return
        }
        debugLog("[CloudKit] performFullSync entering serializer (uploaded=\(state.uploadedSessionIds.count), pending=\(state.pendingUploadIds.count), archive=\(archive.entries.count))")
        await syncSerializer.run { [self] in
            await performFullSyncBody()
        }
    }

    /// Stuck-state recovery. If `syncState` was last entered more
    /// than `syncStuckThresholdSec` ago, the previous sync is hung (network
    /// wedge, CloudKit wedge, record save with no timeout). Force-reset and
    /// let the caller proceed. Without this, ONE hung sync froze sync forever
    /// — the user saw "Syncing…" with no progress and 28 days since the last
    /// successful sync. Returns false when the in-flight sync is still young
    /// enough to be believed.
    private func recoverFromStuckSync() -> Bool {
        guard let startedAt = syncingStartedAt,
              Date().timeIntervalSince(startedAt) > syncStuckThresholdSec else { return false }
        debugLog("[CloudKit] performFullSync detected stuck syncing state (\(Int(Date().timeIntervalSince(startedAt)))s old) — force-reset", level: .warning)
        syncingStartedAt = nil
        syncState = .error(CloudSyncMessages.previousSyncTimedOut)
        return true
    }

    /// Sanitized re-upload drip (Guideline 5.1.3). Records uploaded by
    /// older builds contain the HK-derived `sleepSnapshot` /
    /// `vitalsSnapshot` that `buildSessionRecord` strips, so the
    /// cloud copies must be overwritten. The v1 implementation marked
    /// EVERY uploaded session pending in one shot — on a real archive
    /// that meant the push path ran flat-out 25-record cycles (each
    /// record: decrypt + re-encode + compress + a network save with a
    /// 15 s per-call timeout) for cycle after cycle, saturating the
    /// device right at foreground time. Field report: a
    /// workout took 1–3 minutes to start during the storm. It was also
    /// self-defeating: the pull step re-marks every remotely-existing
    /// record as uploaded, cancelling most of the backlog before it
    /// could re-push. v2 drips: at most `hkSanitizeDripPerCycle` ids
    /// are re-marked per sync body, tracked in a persisted remaining
    /// list, so each cycle's extra work is bounded to seconds.
    static let hkSanitizeRemainingKey = "FlowRecovery.cloudkit.hkSanitizeReupload.v2.remaining"
    static let hkSanitizeInitializedKey = "FlowRecovery.cloudkit.hkSanitizeReupload.v2.initialized"
    private static let hkSanitizeDripPerCycle = 10

    /// Re-mark a small batch of previously-uploaded sessions so the push
    /// step (capped + off-main prep) overwrites their cloud records with
    /// the sanitized payload. Bounded per cycle; rare per-id misses (a
    /// push failure racing the pull's re-mark) are accepted — they leave
    /// one old record behind rather than risking another storm.
    private func dripSanitizeReupload() async {
        guard !schemaUnavailable else { return }
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Self.hkSanitizeInitializedKey) {
            await initializeSanitizeDrip(defaults)
        }
        var remaining = defaults.stringArray(forKey: Self.hkSanitizeRemainingKey) ?? []
        guard !remaining.isEmpty else { return }
        let marked = takeDripBatch(from: &remaining)
        defaults.set(remaining, forKey: Self.hkSanitizeRemainingKey)
        if marked > 0 {
            await state.saveSyncStateAsync()
            debugLog("[CloudKit] Sanitize drip: re-marked \(marked) for sanitized re-upload, \(remaining.count) remaining")
        }
    }

    /// Re-mark up to `hkSanitizeDripPerCycle` ids from the front of the
    /// remaining list, consuming them. Only records still believed to be in
    /// the cloud are re-marked; anything else is already pending (uploads
    /// sanitized) or deleted (tombstoned) and needs nothing from this drip.
    private func takeDripBatch(from remaining: inout [String]) -> Int {
        var marked = 0
        while marked < Self.hkSanitizeDripPerCycle, !remaining.isEmpty {
            let idString = remaining.removeFirst()
            guard let id = UUID(uuidString: idString),
                  state.uploadedSessionIds.contains(id) else { continue }
            state.markRemoved(id)
            marked += 1
        }
        return marked
    }

    /// Repair v1 damage first: v1 hollowed `uploadedSessionIds`
    /// wholesale, leaving the entire archive looking pending —
    /// that's the 25-per-cycle push storm. Only the developer's
    /// own device ever ran a v1 build, and on it every archived
    /// session already existed remotely, so re-marking everything
    /// uploaded restores the truthful state; the drip then
    /// re-uploads each record sanitized at a bounded pace anyway.
    private func initializeSanitizeDrip(_ defaults: UserDefaults) async {
        if defaults.bool(forKey: "FlowRecovery.cloudkit.hkSanitizeReupload.v1.done") {
            for entry in archive.entries { state.markUploaded(entry.sessionId) }
            await state.saveSyncStateAsync()
            debugLog("[CloudKit] Sanitize drip: repaired v1 mass re-mark — uploaded set restored from archive index")
        }
        let snapshot = state.uploadedSessionIds.map(\.uuidString)
        defaults.set(snapshot, forKey: Self.hkSanitizeRemainingKey)
        defaults.set(true, forKey: Self.hkSanitizeInitializedKey)
        debugLog("[CloudKit] Sanitize drip initialized — \(snapshot.count) records to re-upload sanitized over coming syncs")
    }

    private func performFullSyncBody() async {
        syncState = .syncing
        syncingStartedAt = Date()
        let startedAt = Date()
        debugLog("[CloudKit] Full sync body started")
        await dripSanitizeReupload()
        let result = await runSyncPhases()
        switch result {
        case let .success(pushed):
            finishSuccessfulSync(pushed: pushed, startedAt: startedAt)
        case let .failure(error):
            let message = cloudKitErrorMessage(error)
            syncState = .error(message)
            debugLog("[CloudKit] Full sync failed: \(message)")
        }
        syncingStartedAt = nil
    }

    /// Body-level watchdog. Wraps the whole sync so a wedge
    /// anywhere inside (push, pull, subscription, deletion reconcile) can't
    /// freeze the state machine forever.
    ///
    /// A FIXED wall-clock deadline would fail a slow-but-progressing sync
    /// at 120s even while records were still moving (field log: successful
    /// syncs ran 95–118s, 3 of 9 tipped over and "failed"). So it is a
    /// NO-PROGRESS watchdog:
    /// it fails ONLY if the sync stops advancing for syncStuckThresholdSec, so
    /// a slow sync runs to completion and only a genuine wedge is caught. The
    /// push/pull loops call `noteSyncProgress()` as they advance. When the
    /// watchdog fires it cancels this work, and the phases and their loops stop
    /// at the next record or page, so the stalled sync does not run on
    /// alongside the next one once its wedged call returns.
    private func runSyncPhases() async -> Result<Int, Error> {
        await withProgressWatchdog(stuckAfter: syncStuckThresholdSec) {
            try await self.ensureZoneExists()
            let beforeUploaded = await MainActor.run { self.state.uploadedSessionIds.count }
            await self.pushPendingSessions()
            try Task.checkCancellation()
            await self.deletion.reconcileLocalDeletions()
            try Task.checkCancellation()
            await self.pullRemoteChanges()
            let afterUploaded = await MainActor.run { self.state.uploadedSessionIds.count }
            return afterUploaded - beforeUploaded
        }
    }

    /// Preserve the schema-unavailable error message instead of resetting to
    /// `.idle`. The body completes "successfully" when every step
    /// short-circuits on `schemaUnavailable`, but the user still needs to see
    /// why sync isn't happening — `syncState` already carries the schema error
    /// from `flagSchemaUnavailable`, so leave it and don't advance
    /// `lastSyncDate`.
    ///
    /// Only stamp `lastSyncDate` when records could actually
    /// move. Stamping it while `schemaUnavailable` (or after a swallowed pull
    /// failure) made Settings show "Last Sync: just now" / "Up to date" on a
    /// device where zero records had synced — the beta user had no way to see
    /// sync was broken, and the `performFullSyncIfNeeded` interval gate then
    /// suppressed retries as if the sync had worked.
    private func finishSuccessfulSync(pushed: Int, startedAt: Date) {
        if !schemaUnavailable {
            if let pullError = lastPullErrorMessage {
                syncState = .error(pullError)
            } else {
                lastSyncDate = Date()
                syncState = .idle
            }
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        debugLog("[CloudKit] Full sync done — pushed=\(pushed), totalUploaded=\(state.uploadedSessionIds.count), elapsed=\(String(format: "%.1f", elapsed))s, schemaUnavailable=\(schemaUnavailable), pullError=\(lastPullErrorMessage ?? "none")")
    }

    /// Run full sync only when enough time has passed since the last successful sync.
    /// Helps avoid expensive full-history pull churn on every app activation.
    func performFullSyncIfNeeded(minInterval: TimeInterval) async {
        guard settings.iCloudSyncEnabled else {
            debugLog("[CloudKit] performFullSyncIfNeeded skipped — iCloud Sync setting OFF")
            return
        }
        guard syncState != .syncing else {
            debugLog("[CloudKit] performFullSyncIfNeeded skipped — already syncing")
            return
        }
        if let last = lastSyncDate, Date().timeIntervalSince(last) < minInterval {
            debugLog("[CloudKit] performFullSyncIfNeeded skipped — last sync \(Int(Date().timeIntervalSince(last)))s ago < minInterval \(Int(minInterval))s")
            return
        }
        debugLog("[CloudKit] performFullSyncIfNeeded triggering full sync (lastSyncDate=\(lastSyncDate.map { "\(Int(Date().timeIntervalSince($0)))s ago" } ?? "never"))")
        await performFullSync()
    }
}
