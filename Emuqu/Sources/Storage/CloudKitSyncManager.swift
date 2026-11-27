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
    /// per session).
    var schemaUnavailable = false
    /// Uploaded sessions the previous pull's listing did not contain. Only a
    /// session missing from two listings in a row is queued again: the query
    /// index updates asynchronously, so one just saved by the push can be
    /// absent from the listing that follows it.
    var missingFromLastListing: Set<UUID> = []
    /// The message behind a sync that stays stopped (schema unavailable, no
    /// usable iCloud account), written into `syncState` when it stops. Kept
    /// apart from `syncState` so the account-change path can tell which error
    /// it may clear; no screen reads it directly.
    private(set) var lastPermanentErrorMessage: String?
    /// Set by `pullRemoteChanges()` when the pull failed for a reason its
    /// internal catch would otherwise swallow with a debug log. Without it the
    /// full-sync body would treat a swallowed pull failure as success: it
    /// would stamp `lastSyncDate` and show "Up to date" while cross-device
    /// restore never works (uploads fine, nothing ever comes down). Checked
    /// in `performFullSyncBody` so a failed pull
    /// surfaces as `.error` and does NOT advance `lastSyncDate`.
    var lastPullErrorMessage: String?
    /// Set by `pushPendingSessions()` (cleared at its start) when a session
    /// could not be prepared for a reason the user can act on
    /// (`CloudSyncError`, e.g. the encryption key being unavailable). Like a
    /// pull error, it ends the full sync as `.error` without advancing
    /// `lastSyncDate`, so nothing reads "Up to date" while no session backs up.
    var lastPushErrorMessage: String?
    /// Set when a deletion could not be written to iCloud during this sync
    /// (`CloudDeletionCoordinator.performUploadDeletion`); it is retried next
    /// sync, and until then the sync is not shown as up to date.
    var lastDeletionErrorMessage: String?

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
    /// genuinely wedged — rather than at a fixed wall-clock deadline, which would
    /// fail healthy syncs that run close to two minutes while still
    /// pushing/pulling records. A sync can take as long as it needs as
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

    let container = CKContainer(identifier: AppConfig.iCloudContainerIdentifier)
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

    /// Sessions this device should have in iCloud and does not: everything
    /// archived or queued, minus what is uploaded, quarantined (shown in
    /// Troubleshooting, `quarantinedCount`) or kept on this device
    /// (`CloudKitSyncState.markLocalOnly`). What the push works through, and
    /// what has to be empty before a sync counts as up to date.
    var outstandingUploadIds: Set<UUID> {
        Set(archive.store.entries.map(\.sessionId))
            .union(state.pendingUploadIds)
            .subtracting(state.uploadedSessionIds)
            .subtracting(state.quarantinedSessionIds)
            .subtracting(state.localOnlySessionIds)
    }

    /// How many sessions still wait to go up (`outstandingUploadIds`).
    var uploadsWaitingCount: Int {
        outstandingUploadIds.count
    }

    /// Whether Settings may say "Up to date": no sync running or failed,
    /// the archive's index loaded (an index that did not load lists none of
    /// the sessions the push should cover), and nothing waiting to go up.
    var isUpToDate: Bool {
        syncState == .idle && archive.hasCompleteIndex && uploadsWaitingCount == 0
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
        archiveKey: archive.encryption,
        ensureZone: { [weak self] in try await self?.ensureZoneExists() ?? () },
        confirmAccount: { [weak self] in await self?.accountGuard.confirmAccount() == .confirmed },
        zoneGone: { [weak self] in _ = await self?.accountGuard.zoneWasDeleted() }
    )

    /// Whether the custom zone has been created
    var zoneCreated: Bool {
        get { UserDefaults.standard.bool(forKey: UserDefaultsKeys.cloudKitZoneCreated) }
        set { UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.cloudKitZoneCreated) }
    }

    let settingsManager: SettingsManager
    let archive: SessionArchive
    /// The settings record's sync, whose zone and stored copy follow this
    /// manager's resets and scrubs.
    let settingsSync: CloudKitSettingsSync

    /// Serializes concurrent sync operations (upload, delete, full sync) so
    /// they can't interleave at await points and race on `state` mutations.
    /// Not a `while inFlight { Task.yield() }` busy-wait, which pins the
    /// main actor under contention.
    let syncSerializer = SyncSerializer()

    /// Token for the `.CKAccountChanged` observer (sign in/out
    /// of iCloud mid-run), kept for the manager's lifetime — the process-long
    /// singleton, so it is never removed. Without an
    /// account-change listener, signing out of
    /// iCloud during a session fails silently — sync just stops working
    /// with no state change the UI could surface.
    @ObservationIgnored private let observers = NotificationTokens()

    private var settings: UserSettings {
        settingsManager.settings
    }

    /// Whether session data may be written to iCloud right now.
    ///
    /// The sync toggle alone is not enough: onboarding asks about iCloud only
    /// on its backup page, and until onboarding is finished the user has not
    /// made that choice, whatever the toggle holds, so nothing is uploaded. Reading
    /// (the pull) is not gated here — it brings the user's own records back
    /// from their own container and writes nothing about them to it. A session
    /// held back by this gate stays pending and goes up with the next sync.
    /// Nothing is uploaded while "Delete All My Data" runs (`PurgeGate`).
    var cloudUploadsAllowed: Bool {
        settings.iCloudSyncEnabled && settings.hasCompletedOnboarding && !PurgeGate.isPurging
    }

    /// Saves an upload's `record`, if uploads are still allowed at the moment
    /// the save starts: sync on, the confirmed account signed in, the schema
    /// available and the task not cancelled. Every upload checks this at its
    /// start too, but preparing one (reading, sealing, a conflict's fetch)
    /// awaits, and sync can be switched off or the account change during
    /// that wait. Checked here, right before the request, nothing starts
    /// after that. A save already sent cannot be called back.
    func saveUpload(_ record: CKRecord) async throws -> CKRecord {
        guard cloudUploadsAllowed, !schemaUnavailable, CloudAccountIdentity.isConfirmed, !Task.isCancelled else {
            throw CloudUploadStopped()
        }
        return try await privateDB.save(record)
    }

    // MARK: - Init

    /// The app's manager is `shared`, whose bookkeeping is at
    /// `resolveSyncStateURL()`. A test builds its own over its archive,
    /// settings and sync-state file, so it neither reads nor rewrites the
    /// app's sync bookkeeping.
    init(
        settingsManager: SettingsManager,
        archive: SessionArchive,
        settingsSync: CloudKitSettingsSync,
        syncStateURL: URL
    ) {
        self.settingsManager = settingsManager
        self.archive = archive
        self.settingsSync = settingsSync
        // Cold-start: keep init lightweight — only
        // construct the URL + empty state container. The disk read of
        // sync_state.json (potentially KB of uploaded-session UUIDs) is
        // deferred to boot(), which fires from `RootView.task` after first
        // frame paints. `CloudKitSyncState` holds its saves until that load,
        // so a CloudKit upload that lands during the boot gap doesn't
        // overwrite the file and trigger a re-upload of every session.
        state = CloudKitSyncState(syncStateURL: syncStateURL)
        observeReuploadSignals()
        observers.add(Self.observeAccountChanges { [weak self] in
            // Unconfirmed at once, before the status check: nothing is read
            // or written until the new account has been checked.
            CloudAccountIdentity.noteAccountChanged()
            Task { @MainActor [weak self] in await self?.accountChange.handle() }
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

    /// Cold-start: post-first-frame catch-up. Loads
    /// the persisted sync state from disk (uploaded-session set, pending
    /// queue, change tokens) and reads `lastSyncDate` from UserDefaults.
    /// Idempotent — subsequent calls short-circuit on `didBootSyncState`.
    @MainActor
    func boot() {
        guard didBootSyncState.setIfClear() else { return }
        state.loadAll()
        lastSyncDate = UserDefaults.standard.object(forKey: UserDefaultsKeys.cloudKitLastSyncDate) as? Date
    }

    @ObservationIgnored private let didBootSyncState = OSAllocatedUnfairLock(initialState: false)

    /// Wipe local sync state (uploaded set, pending queue, change tokens,
    /// the session and settings zone flags, the listing memory). Called by
    /// the user-initiated "Delete All My Data" Settings action, and when sync
    /// stops for another account or deleted iCloud data
    /// (`CloudAccountGuard.stopSync`). Local bookkeeping only — remote
    /// CloudKit records are removed by `deleteAllRemoteData()`, which calls
    /// this on success (the purge flow also calls it directly so local state
    /// resets even when the remote deletion fails).
    func resetLocalSyncState() {
        state.resetAll()
        zoneCreated = false
        missingFromLastListing = []
        settingsSync.forgetZone()
        lastSyncDate = nil
        syncState = .idle
    }

    /// Checks the signed-in account; built on each access.
    var accountGuard: CloudAccountGuard {
        CloudAccountGuard(manager: self)
    }

    /// Whether any sync bookkeeping is held, which an unrecorded account
    /// cannot be assumed to own (`CloudAccountIdentity.verdict`): uploaded
    /// sessions, a created zone or a completed sync. The upload queue is not
    /// counted: it fills while sync is off (re-upload requests after
    /// migrations, folds and edits) and says nothing about any account.
    var hasAccountBookkeeping: Bool {
        !state.uploadedSessionIds.isEmpty || zoneCreated || lastSyncDate != nil
    }

    /// Show why sync stopped or paused (another account, deleted iCloud
    /// data, no usable account): as the sync state Settings reads, and as the
    /// permanent-error line, so the reason stays on screen. Ends any sync the
    /// stuck-sync timer was watching.
    func showSyncStopped(_ message: String) {
        syncState = .error(message)
        lastPermanentErrorMessage = message
        syncingStartedAt = nil
    }

    /// Clear the not-signed-in line wherever it shows, matched in any
    /// language the app ships (`CloudSyncMessages.isNotSignedIn`). Any other
    /// error is not about the account and stays until a sync clears it.
    func clearNotSignedInError() {
        if case let .error(message) = syncState, CloudSyncMessages.isNotSignedIn(message) { syncState = .idle }
        if CloudSyncMessages.isNotSignedIn(lastPermanentErrorMessage) { lastPermanentErrorMessage = nil }
    }

    /// Reacts to `.CKAccountChanged`; built on each access.
    var accountChange: CloudAccountChangeHandler {
        CloudAccountChangeHandler(manager: self)
    }

    // MARK: - Upload Session

    /// Upload a single session to CloudKit. Called after each archive write.
    /// Fire-and-forget — errors are logged, not thrown.
    /// Serialized: waits for any in-flight sync operation to avoid state mutation races.
    ///
    /// Upload eligibility:
    ///   • `.complete` sessions always sync.
    ///   • Workout sessions also sync regardless of state when they
    ///     carry a `WorkoutMetadata` payload — this picks up partials
    ///     reconstructed by `WorkoutRecoveryService` (state may be
    ///     `.complete` with a `partialDataReason`) AND legacy `.failed`
    ///     workouts that still have meaningful captured data. Without
    ///     this, a strap-died-mid-workout session would archive
    ///     locally but never appear on the user's other devices.
    ///
    /// The gate applies only to this direct upload, made right after an
    /// archive write. The batch push (`pendingPushIds`) uploads every
    /// archived entry whatever its state, so a session skipped here still
    /// goes up on the next full sync.
    ///
    /// The consent (`cloudUploadsAllowed`, which also refuses while "Delete
    /// All My Data" runs, `PurgeGate`), the schema pause and the iCloud
    /// account are checked again once the upload's turn in the serializer
    /// comes: sync can be turned off, a purge start, or the account change,
    /// while it waited behind another operation.
    ///
    /// A recording the archive folded into a same-night session
    /// (`SessionArchive.archivedId(of:)`) is uploaded as that session, queued
    /// again first: its iCloud copy predates the merge.
    func uploadSession(_ session: HRVSession) async {
        guard cloudUploadsAllowed else { return }
        // Short-circuit when the CloudKit schema is known not to be in
        // production. Without this, every completed recording triggers a
        // save that's guaranteed to fail with the same error.
        guard !schemaUnavailable else { return }
        guard Self.takesDirectUpload(session) else { return }
        await syncSerializer.run { [self] in
            guard cloudUploadsAllowed, !schemaUnavailable, await accountGuard.confirmAccount() == .confirmed else { return }
            let sessionId = archive.archivedId(of: session.id)
            if sessionId != session.id { state.markRemoved(sessionId) }
            // Skip if already uploaded
            guard !state.uploadedSessionIds.contains(sessionId) else { return }
            await uploadOne(sessionId)
        }
    }

    /// Whether the direct upload takes `session` at all (`uploadSession`): a
    /// complete session, or a workout carrying its metadata in any state, and
    /// never one read out of Apple Health whole, which stays on this device
    /// (the push marks it local-only when it reaches it).
    static func takesDirectUpload(_ session: HRVSession) -> Bool {
        let isWorkoutWithData = session.sessionType == .workout && session.workoutMetadata != nil
        return (session.state == .complete || isWorkoutWithData) && !CloudSessionPayload.isHealthKitSourced(session)
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
    private func uploadOne(_ sessionId: UUID) async {
        do {
            try await ensureZoneExists()
            guard let prepared = try await prepareUploadOffMain(sessionId: sessionId) else {
                debugLog("[CloudKit] Upload skipped — session \(sessionId.uuidString.prefix(8)) no longer in archive")
                return
            }
            let record = prepared.record
            defer { cleanupTempAsset(for: record) }
            try await saveUploadRecord(record, sessionId: sessionId)
        } catch is CloudUploadStopped {
            debugLog("[CloudKit] Upload of \(sessionId.uuidString.prefix(8)) not sent: sync was switched off or the account changed while it was prepared")
        } catch {
            await handleUploadError(error, sessionId: sessionId)
        }
    }

    /// Saves one prepared record. A conflict is resolved here, with the fields
    /// this device tried to write; any other error is rethrown to the caller.
    /// A save that returns once the account is no longer confirmed (sync
    /// stopped meanwhile and reset the bookkeeping, or the account changed)
    /// marks nothing.
    private func saveUploadRecord(_ record: CKRecord, sessionId: UUID) async throws {
        do {
            let saved = try await saveUpload(record)
            guard CloudAccountIdentity.isConfirmed else { return }
            state.markUploaded(sessionId)
            state.noteRecordVersion(saved.recordChangeTag, of: sessionId)
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

    /// Rewrites earlier uploads without their Apple Health readings, built on
    /// each access; its list lives in UserDefaults.
    var healthScrub: CloudHealthScrubCoordinator {
        CloudHealthScrubCoordinator(manager: self)
    }

    /// With iCloud Sync off, records uploaded while it was on still hold the
    /// Apple Health readings earlier builds sent. Rewrite them in place, a
    /// batch each time `performFullSyncIfNeeded` runs with sync off (every
    /// foreground activation; an account check and, once the list is done, an
    /// empty pass), without uploading anything new: the session records
    /// (`CloudHealthScrubCoordinator.scrubInPlace`) and the settings record
    /// (`CloudKitSettingsSync.scrubStoredRecord`). Needs the iCloud account
    /// the records were uploaded to (`CloudAccountGuard.confirmAccount`);
    /// without it nothing is read or written, and a different account found
    /// here resets the bookkeeping before the user turns sync on for it.
    func scrubHealthReadingsWhileSyncOff() async {
        guard settings.hasCompletedOnboarding, !schemaUnavailable else { return }
        var confirmed = false
        await syncSerializer.run { [self] in
            confirmed = await accountGuard.confirmAccount() == .confirmed
            guard confirmed else { return }
            await healthScrub.scrubInPlace()
        }
        guard confirmed else { return }
        await settingsSync.scrubStoredRecord(keepingOutHealthFilledFrom: settings)
    }

    /// The pull subsystem, built on each access; it holds no state of its own.
    var pull: CloudPullCoordinator {
        CloudPullCoordinator(manager: self)
    }

    /// Restores from the Trash that must outrank an iCloud tombstone.
    var trashRestore: TrashRestoreCoordinator {
        TrashRestoreCoordinator(manager: self)
    }

    /// Re-save a record that lost a revision race on the direct upload path.
    ///
    /// Simply marking the record uploaded here would be wrong: CloudKit
    /// reports `.serverRecordChanged` because the save did NOT happen, so the
    /// server would keep its older contents while local state claimed success. This
    /// path is reached by `forceReuploadSession` after a reanalysis — the one
    /// caller whose entire purpose is replacing what the server already holds.
    ///
    /// The batch push's resolution (`resolveConflict`) decides it — a server
    /// tombstone wins unless this is a Trash restore, otherwise this device's
    /// fields go over the server's record, edited-later wins — and the
    /// outcome is then persisted, as this path saves state after every upload.
    private func resolveDirectConflict(
        _ error: CKError, record: CKRecord, sessionId: UUID
    ) async {
        _ = await resolveConflict(error, prepared: PreparedUpload(record: record), sessionId: sessionId)
        await state.saveSyncStateAsync()
    }

    /// The batch push's handling (`handleSaveFailure`), so a deleted zone
    /// stops sync here too instead of queueing a retry, then the queue is
    /// saved as this path saves state after every upload.
    private func handleUploadError(_ error: Error, sessionId: UUID) async {
        _ = await handleSaveFailure(error, sessionId: sessionId)
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
    ///
    /// `stampingEdit: false` is for a rewrite no one asked for (a rescore, a
    /// repair): the copy goes up with the stamp it has. Stamped, a device's
    /// automatic rewrite of a copy it had not yet pulled another device's
    /// edit into would count as newer than that edit and replace it
    /// everywhere. Unstamped it still reaches the devices holding the same
    /// edit, by the record's new version (`CloudKitSessionFreshness.onTie`),
    /// and yields to a newer edit, which the pull then brings here.
    ///
    /// The unmark waits in `syncSerializer`, as `markSessionsForReupload`
    /// does: a push or upload of the same session already in flight, with a
    /// record built before the change, finishes first, and its `markUploaded`
    /// cannot land after the unmark and turn the upload below away.
    func forceReuploadSession(_ session: HRVSession, stampingEdit: Bool = true) async {
        if stampingEdit { await CloudKitSessionFreshness.stampEdit(of: session.id, in: archive) }
        await syncSerializer.run { [self] in
            state.markRemoved(session.id)
            await state.saveSyncStateAsync()
        }
        await uploadSession(session)
    }

    /// `forceReuploadSession` for a rewrite no one asked for (a rescore, a
    /// repair): the copy goes up with the edit stamp it has.
    func reuploadRewrite(_ session: HRVSession) async {
        await forceReuploadSession(session, stampingEdit: false)
    }

    static func resolveSyncStateURL() -> URL {
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
    /// Kept in `observers` with the account-change observer, so a manager
    /// that goes away (a test's, a preview's) takes its registration with it.
    private func observeReuploadSignals() {
        observers.add(NotificationCenter.default.addObserver(
            forName: .flowRecoveryArchiveSessionsNeedReupload,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let ids = note.userInfo?["sessionIds"] as? Set<UUID> else { return }
            Task { [weak self] in await self?.markSessionsForReupload(ids) }
        })
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
    ///
    /// A tombstone is a write to iCloud, so it waits for the same consent as
    /// an upload (`cloudUploadsAllowed`: nothing before onboarding's iCloud
    /// choice) and for the confirmed account. One held back stays in the
    /// archive's deleted list, and the full sync writes it
    /// (`reconcileLocalDeletions`).
    func uploadDeletion(_ sessionId: UUID) async {
        guard cloudUploadsAllowed else { return }

        await syncSerializer.run { [self] in
            guard cloudUploadsAllowed, await accountGuard.confirmAccount() == .confirmed else { return }
            await deletion.performUploadDeletion(sessionId: sessionId)
        }
    }

    // MARK: - Full Sync

    /// Perform a full sync: push pending uploads, then pull remote changes.
    /// Called on app launch and when returning to foreground.
    ///
    /// Runs inside a `LogCorrelation` scope so the push/pull/conflict lines it
    /// emits stay distinguishable from a recording's rather than mixed into
    /// one undifferentiated stream.
    ///
    /// Diagnostic logging on every entry, so a sync that silently stops
    /// shows which of the early-bail conditions is firing. Every call logs
    /// whether it proceeded or why it didn't.
    ///
    /// The sync toggle is read again, with `PurgeGate`, once the sync's turn
    /// in the serializer comes. A sync admitted before "Delete All My Data"
    /// turned sync off and queued behind its remote delete would otherwise
    /// recreate the deleted zone and push the archive back into it.
    func performFullSync() async {
        let correlation = LogCorrelation.begin("sync")
        defer { LogCorrelation.end(correlation) }
        if let reason = fullSyncSkipReason() {
            debugLog("[CloudKit] performFullSync skipped — \(reason)")
            return
        }
        fullSyncsAdmitted += 1
        defer { fullSyncsAdmitted -= 1 }
        debugLog("[CloudKit] performFullSync entering serializer (uploaded=\(state.uploadedSessionIds.count), pending=\(state.pendingUploadIds.count), archive=\(archive.store.entries.count))")
        await syncSerializer.run { [self] in
            guard settings.iCloudSyncEnabled, !PurgeGate.isPurging else {
                debugLog("[CloudKit] performFullSync skipped — sync turned off, or Delete All My Data started, while it waited")
                return
            }
            await performFullSyncBody()
        }
    }

    /// Full syncs admitted past `fullSyncSkipReason` and not yet finished,
    /// waiting in the serializer included. `syncState` turns `.syncing` only
    /// inside the body, so without this two calls arriving together both
    /// passed the "already syncing" check and ran two full syncs back to back.
    @ObservationIgnored private var fullSyncsAdmitted = 0

    /// Why this call does not run a full sync, or nil to run it.
    private func fullSyncSkipReason() -> String? {
        if schemaUnavailable { return "schema unavailable (this launch)" }
        if syncState == .syncing || fullSyncsAdmitted > 0, !recoverFromStuckSync() { return "already syncing" }
        guard settings.iCloudSyncEnabled else {
            syncState = .idle
            return "iCloud Sync setting is OFF"
        }
        return nil
    }

    /// Stuck-state recovery. If the sync in flight has shown no sign of life
    /// — neither its start nor a pushed record, pulled page or processed
    /// remote record (`lastSyncProgressAt`) — for `syncStuckThresholdSec`, it
    /// is hung (network wedge, CloudKit wedge, record save with no timeout).
    /// Force-reset and let the caller proceed. Without this, ONE hung sync
    /// would freeze sync forever, showing "Syncing…" with no progress. A slow sync that keeps
    /// progressing is not stuck, the rule the body's watchdog follows.
    /// Returns false when the in-flight sync is still to be believed (or none
    /// has started its body).
    private func recoverFromStuckSync() -> Bool {
        guard let startedAt = syncingStartedAt,
              Date().timeIntervalSince(max(startedAt, lastSyncProgressAt)) > syncStuckThresholdSec else { return false }
        debugLog("[CloudKit] performFullSync detected stuck syncing state (\(Int(Date().timeIntervalSince(startedAt)))s old, no progress for \(syncStuckThresholdSec)s) — force-reset", level: .warning)
        syncingStartedAt = nil
        syncState = .error(CloudSyncMessages.previousSyncTimedOut)
        return true
    }

    private func performFullSyncBody() async {
        syncState = .syncing
        syncingStartedAt = Date()
        let startedAt = Date()
        debugLog("[CloudKit] Full sync body started")
        let result = await runSyncPhases()
        switch result {
        case let .success(pushed):
            finishSuccessfulSync(pushed: pushed, startedAt: startedAt)
        case .failure(CloudAccountGuard.Halt.stopped):
            debugLog("[CloudKit] Full sync stopped — iCloud sync is off for this account, or the account is no longer the one sync is enabled for")
        case let .failure(error):
            let message = cloudKitErrorMessage(error)
            syncState = .error(message)
            debugLog("[CloudKit] Full sync failed: \(message)")
        }
        endSyncBody()
    }

    /// The body's last step. A run that ended with nothing to show (sync
    /// turned off while it ran, or stopped before a stop notice was set) must
    /// not stay "Syncing…": `fullSyncSkipReason` would turn every later sync
    /// away as already running, and with `syncingStartedAt` cleared nothing
    /// would reset it.
    private func endSyncBody() {
        if syncState == .syncing { syncState = .idle }
        syncingStartedAt = nil
    }

    /// Body-level watchdog. Wraps the whole sync so a wedge
    /// anywhere inside (push, pull, subscription, deletion reconcile) can't
    /// freeze the state machine forever.
    ///
    /// A FIXED wall-clock deadline would fail a slow-but-progressing sync
    /// even while records are still moving. So it is a NO-PROGRESS watchdog:
    /// it fails ONLY if the sync stops advancing for syncStuckThresholdSec, so
    /// a slow sync runs to completion and only a genuine wedge is caught. The
    /// push/pull loops call `noteSyncProgress()` as they advance. When the
    /// watchdog fires it cancels this work, and the phases and their loops stop
    /// at the next record or page, and a save that returns after the watchdog
    /// fired marks nothing, so the stalled sync does not run on alongside the
    /// next one once its wedged call returns.
    ///
    /// The signed-in account is confirmed first
    /// (`CloudAccountGuard.requireConfirmedAccount`): no zone is created and
    /// nothing is re-queued (`healthScrub.dripReupload`), pushed, deleted or
    /// pulled for an account this device's bookkeeping does not belong to.
    /// It is confirmed again before the deletions and before the pull: a sync
    /// stopped partway (the zone found gone, another account found by an
    /// upload or the settings push meanwhile), or an account change, ends
    /// there instead of listing an account that is no longer confirmed.
    /// The body is entered only while the schema is not paused
    /// (`fullSyncSkipReason`), so the scrub's re-marking needs no check of it.
    private func runSyncPhases() async -> Result<Int, Error> {
        await withProgressWatchdog(stuckAfter: syncStuckThresholdSec) {
            try await self.accountGuard.requireConfirmedAccount()
            await self.healthScrub.dripReupload()
            try await self.ensureZoneExists()
            let beforeUploaded = await MainActor.run { self.state.uploadedSessionIds.count }
            await self.pushPendingSessions()
            try Task.checkCancellation()
            try await self.requireSyncStillOn()
            try await self.accountGuard.requireConfirmedAccount()
            await self.deletion.reconcileLocalDeletions()
            try Task.checkCancellation()
            try await self.requireSyncStillOn()
            try await self.accountGuard.requireConfirmedAccount()
            await self.pull.pullRemoteChanges()
            try Self.requirePhaseNotCutShort()
            let afterUploaded = await MainActor.run { self.state.uploadedSessionIds.count }
            return afterUploaded - beforeUploaded
        }
    }

    /// A pull the watchdog or an account change cut short returns without an
    /// error; the sync it ends is not complete, and stamps nothing.
    nonisolated private static func requirePhaseNotCutShort() throws {
        try Task.checkCancellation()
        guard CloudAccountIdentity.isConfirmed else { throw CloudAccountGuard.Halt.stopped }
    }

    /// Ends a sync the user switched off while it ran, before its next
    /// phase: "When OFF: nothing new goes up or comes down" holds for the
    /// sync already under way, not only the next one. It ends as a stop
    /// (`Halt.stopped`), not a failure, so no error banner follows the user
    /// switching sync off.
    private func requireSyncStillOn() async throws {
        guard await MainActor.run(body: { self.cloudUploadsAllowed }) else {
            debugLog("[CloudKit] iCloud sync was switched off during a sync — stopping it", level: .info)
            throw CloudAccountGuard.Halt.stopped
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
    /// failure) would make Settings show "Last Sync: just now" / "Up to date"
    /// on a device where zero records had synced, hiding that sync is broken,
    /// and the `performFullSyncIfNeeded` interval gate would then suppress
    /// retries as if the sync had worked. A push that could not
    /// prepare sessions for a reason the user can act on
    /// (`lastPushErrorMessage`) ends the same way, as does one whose deletions
    /// could not all be written to iCloud (`lastDeletionErrorMessage`). A sync that stopped itself
    /// partway (deleted iCloud data, another account) turned iCloud Sync off
    /// and left its own message; that is kept. One the user turned off while
    /// it ran stamps nothing either; `performFullSyncBody` then leaves
    /// `.syncing`. Nor does one whose bookkeeping could not be written
    /// (`CloudKitSyncState.hasUnsavedBookkeeping`): a relaunch would load the
    /// older files, so the sync is shown as failed and the next one is not
    /// held back by the interval. Nor does one that leaves sessions waiting
    /// to go up (`uploadsWaitingCount`) or ran over an index that did not
    /// load: it is not complete, Settings shows what still waits
    /// (`isUpToDate`), and the next activation syncs again.
    private func finishSuccessfulSync(pushed: Int, startedAt: Date) {
        // Turned off during this run, by `CloudAccountGuard.stopSync` (its
        // message stays) or by the user: nothing is stamped.
        guard settings.iCloudSyncEnabled else { return }
        if !schemaUnavailable {
            apply(Self.completion(
                syncError: lastPullErrorMessage ?? lastPushErrorMessage ?? lastDeletionErrorMessage,
                bookkeepingUnsaved: state.hasUnsavedBookkeeping,
                indexComplete: archive.hasCompleteIndex,
                waitingUploads: uploadsWaitingCount
            ))
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        debugLog("[CloudKit] Full sync done — pushed=\(pushed), totalUploaded=\(state.uploadedSessionIds.count), elapsed=\(String(format: "%.1f", elapsed))s, schemaUnavailable=\(schemaUnavailable), pullError=\(lastPullErrorMessage ?? "none")")
    }

    /// How a full sync that ran every phase ended.
    enum SyncCompletion: Equatable {
        /// Everything it covers is done: `lastSyncDate` is stamped.
        case upToDate
        /// A phase failed in a way the user is shown.
        case failed(String)
        /// It ran, but sessions still wait to go up, or the archive's index
        /// did not load: nothing is stamped.
        case incomplete
    }

    /// The one rule for how a full sync ends: up to date only when no phase
    /// failed, its bookkeeping was saved, the index it pushed from was
    /// complete and no session waits to go up.
    static func completion(syncError: String?, bookkeepingUnsaved: Bool, indexComplete: Bool, waitingUploads: Int) -> SyncCompletion {
        if let syncError { return .failed(syncError) }
        if bookkeepingUnsaved { return .failed(CloudSyncMessages.progressNotSaved) }
        return indexComplete && waitingUploads == 0 ? .upToDate : .incomplete
    }

    private func apply(_ completion: SyncCompletion) {
        switch completion {
        case .upToDate:
            lastSyncDate = Date()
            syncState = .idle
        case let .failed(message):
            debugLog("[CloudKit] Full sync ran but did not complete, not stamped: \(message)", level: .warning)
            syncState = .error(message)
        case .incomplete:
            debugLog("[CloudKit] Full sync ran with \(uploadsWaitingCount) session(s) still waiting to upload (index complete: \(archive.hasCompleteIndex)), not stamped", level: .warning)
            syncState = .idle
        }
    }

    /// Run full sync only when enough time has passed since the last successful sync.
    /// Helps avoid expensive full-history pull churn on every app activation.
    func performFullSyncIfNeeded(minInterval: TimeInterval) async {
        guard settings.iCloudSyncEnabled else {
            debugLog("[CloudKit] performFullSyncIfNeeded skipped — iCloud Sync setting OFF")
            await scrubHealthReadingsWhileSyncOff()
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
