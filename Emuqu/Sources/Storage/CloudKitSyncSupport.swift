import CloudKit
import CryptoKit
import Foundation

// Supporting types for CloudKit sync: the timeout error, the notification
// names, the serializer that funnels concurrent syncs into one at a time, the
// separate settings-sync object with its record format, and the sync status
// lines. What a session record carries is in `CloudSessionPayload.swift`.

enum SyncTimeoutError: Error, LocalizedError {
    case timedOut
    case stalled
    var errorDescription: String? {
        switch self {
        case .timedOut: String(localized: "Sync operation timed out — will retry", bundle: LanguageManager.appBundle)
        case .stalled: String(localized: "Sync stalled with no progress — will retry", bundle: LanguageManager.appBundle)
        }
    }
}

extension Notification.Name {
    /// Posted by `CloudKitSyncManager.pullRemoteChanges()` after
    /// a pull archives NEW sessions. `userInfo["sessionIds"]` carries an
    /// `[UUID]` of those sessions. `RRCollector` observes this and re-derives
    /// each one's HK-backed `sleepSnapshot` / `vitalsSnapshot` (stripped from
    /// CloudKit uploads per Guideline 5.1.3), bounded + low priority.
    static let cloudKitSnapshotBackfillNeeded =
        Notification.Name("flowRecoveryCloudKitSessionsNeedSnapshotBackfill")
}

/// Serializes async work across the `CloudKitSyncManager` surface. Each
/// `run { ... }` suspends until the previous invocation finishes, so
/// upload / delete / full-sync calls can't interleave at await points and
/// race on `state` mutations. Replaces the prior
/// `while isSyncOperationInFlight { Task.yield() }` busy-wait, which
/// pinned the main actor under contention.
///
/// The closure runs on the `MainActor` because `CloudKitSyncManager`
/// properties (state, syncState, settings) are all main-actor-isolated.
/// A plain `actor` would force cross-actor hops on every access.
@MainActor
final class SyncSerializer {
    @ObservationIgnored private var previous: Task<Void, Never> = Task {}

    func run(_ body: @escaping @MainActor () async -> Void) async {
        let previousTask = previous
        let newTask = Task { @MainActor [previousTask] in
            _ = await previousTask.value
            await body()
        }
        previous = newTask
        await newTask.value
    }
}

// MARK: - CloudKit Settings Sync
//
// Backs `UserSettings` up to the user's iCloud private DB on every
// settings change (debounced) and provides a one-shot restore that
// pulls the cloud copy back down.
//
// The data loss this guards against:
//   • Settings are stored as a single JSON file at
//     `<AppGroup>/user_settings.json` with `URLFileProtection.complete`.
//   • A Watch-triggered background launch while the device is locked
//     hits `init()` with that file unreadable; if defaults were kept and
//     saved, the next save() would overwrite the real file and the user
//     would re-enter everything from scratch.
// `SettingsManager` distinguishes "file missing" from "file
// locked" and refuses to save over the locked case (see
// `SettingsManager.LoadOutcome`). This sync layer is the second leg:
// even if a save did slip through, the cloud copy is recoverable.
//
// Schema
//   • Zone: "UserSettings" (separate from the HRVSession zone so a
//     sessions-only fault recovery doesn't drag settings along).
//   • Record type: "UserSettings".
//   • Single record with fixed name "primary"; the later edit wins
//     (`modifiedAt` against `localEditedAtKey`).
//   • Fields written: `settingsPayload` (Bytes, the encrypted settings) and
//     `modifiedAt` (Date, for the "last synced" UI). See
//     `CloudSettingsRecord` for why, and for the two legacy fields every
//     push clears.

@Observable

@MainActor
final class CloudKitSettingsSync {

    enum Status: Equatable {
        case idle
        case syncing
        case lastPushed(Date)
        case error(String)
    }

    private(set) var status: Status = .idle

    private let container = CKContainer(identifier: AppConfig.iCloudContainerIdentifier)
    var privateDB: CKDatabase { container.privateCloudDatabase }
    let recordType = "UserSettings"
    let zoneID = CKRecordZone.ID(zoneName: "UserSettings", ownerName: CKCurrentUserDefaultName)
    private let recordName = "primary"

    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var changeObserver: NSObjectProtocol?
    /// One push at a time. The debounced push, the launch push and the Back Up
    /// button each fetch and save the same record; interleaved at their awaits,
    /// the second save lost to the first with `.serverRecordChanged` although
    /// both came from this device.
    private let pushSerializer = SyncSerializer()
    /// Whether this device created the UserSettings zone, kept across
    /// launches: a zone it created that is gone was deleted (Delete All My
    /// Data, or the iCloud settings), and is not created again behind the
    /// user's back. Reset with the rest of the bookkeeping (`forgetZone`).
    static let zoneCreatedKey = "cloudkit.settingsZoneCreated"
    /// When the settings the user edits on this device last changed, as the
    /// record's `modifiedAt` is compared with it: a push replaces only an
    /// older cloud copy. The app's own writes do not move it
    /// (`noteSettingsChange`); a restore sets it to the restored copy's date.
    static let localEditedAtKey = "cloudkit.settingsLocalEditedAt"
    /// A digest of the settings the user edits, as last seen
    /// (`CloudSettingsRecord.editFingerprint`): how a user's edit is told from
    /// the app writing a baseline, a trial date or a launch flag, all of
    /// which post the same settings change. A hash only; the settings
    /// themselves are never put in UserDefaults.
    static let editFingerprintKey = "cloudkit.settingsEditFingerprint"
    /// Sticky per-launch flag. Set when the UserSettings record type isn't
    /// in production schema yet — same retry-storm protection as
    /// `CloudKitSyncManager.schemaUnavailable`, applied to the settings
    /// sync path. Without this, every `.flowRecoverySettingsChanged`
    /// notification keeps re-arming the debounce → another doomed push.
    private var schemaUnavailable = false

    private let settingsManager: SettingsManager
    /// Opens a settings record an older build sealed with the archive key.
    private let archiveKey: EncryptionManager
    /// The session sync, whose account guard and zone this sync defers to.
    /// A provider, resolved when used: the two syncs refer to each other.
    private let sessionSync: @MainActor () -> CloudKitSyncManager

    init(
        settingsManager: SettingsManager,
        archiveKey: EncryptionManager,
        sessionSync: @escaping @MainActor () -> CloudKitSyncManager
    ) {
        self.settingsManager = settingsManager
        self.archiveKey = archiveKey
        self.sessionSync = sessionSync
        // The settings as they are now are the starting point: a change made
        // before this object listened, or a field a new build added, is not an
        // edit made now.
        takeEditFingerprint(stampingAChange: false)
        // Listen to the same notification SettingsManager fires on every
        // change. Debounce so a flurry of edits (e.g. user rapidly
        // toggling a row) collapses into one push.
        changeObserver = NotificationCenter.default.addObserver(
            forName: .flowRecoverySettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.noteSettingsChange()
                self?.scheduleDebouncedPush()
            }
        }
    }

    /// A settings change was posted: the edit time moves to now only when a
    /// setting the user edits changed (`CloudSettingsRecord.editFingerprint`).
    /// The app's own writes (the HRV baselines, the trial start, the
    /// launch-task flags, the sync switch) post the same change and leave it
    /// alone, so a device that only scored a night does not count as edited
    /// later than one where the user changed a setting.
    private func noteSettingsChange() {
        takeEditFingerprint(stampingAChange: true)
    }

    /// Store the current settings' edit fingerprint and, with
    /// `stampingAChange`, set the edit time to now when it differs from the
    /// stored one. A device's first fingerprint is a starting point, never
    /// an edit. Nothing is taken while the settings file is not loaded.
    private func takeEditFingerprint(stampingAChange: Bool) {
        guard let json = settingsManager.currentSettingsJSON() else { return }
        let fingerprint: String
        do {
            fingerprint = try CloudSettingsRecord.editFingerprint(json)
        } catch {
            debugLog("[CloudKitSettings] settings edit fingerprint not taken: \(error.localizedDescription)", level: .warning)
            return
        }
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: Self.editFingerprintKey)
        guard previous != fingerprint else { return }
        defaults.set(fingerprint, forKey: Self.editFingerprintKey)
        if stampingAChange, previous != nil { defaults.set(Date(), forKey: Self.localEditedAtKey) }
    }

    /// Forget the zone: after a remote wipe or an account change, the next
    /// push creates it again for the account sync is then enabled for.
    func forgetZone() {
        UserDefaults.standard.removeObject(forKey: Self.zoneCreatedKey)
    }

    /// The settings now on this device are the copy restored from iCloud,
    /// edited at `editedAt`: that is their edit time, and their fingerprint is
    /// the starting point, so the restore itself (and the trial date it
    /// adopts) is not taken for an edit made on this device now.
    private func noteRestored(editedAt: Date?) {
        takeEditFingerprint(stampingAChange: false)
        if let editedAt { UserDefaults.standard.set(editedAt, forKey: Self.localEditedAtKey) }
    }

    /// Push the current settings now, without debounce. Called by the
    /// app-launch hook so the cloud copy stays current even when the
    /// user only adjusts settings on one device per session, and by the
    /// "Back Up Settings" button.
    ///
    /// The launch push replaces the cloud copy only when this device's
    /// settings were changed after it was (`localEditedAtKey`): a device
    /// with older settings launching replaced the copy the user had just
    /// edited elsewhere, and a later restore brought back the stale values.
    /// The button passes `replacingNewerCloudCopy`: the user asked for this
    /// device's settings to be the backup.
    ///
    /// True only when the settings were saved to iCloud. Anything else also
    /// leaves `status` as `.error` with the reason, including a push that was
    /// skipped or lost a conflict, so the button never reports a backup that
    /// did not happen. A newer cloud copy left in place is not an error.
    @discardableResult
    func pushImmediately(replacingNewerCloudCopy: Bool = false) async -> Bool {
        switch await performPush(replacingNewerCloudCopy: replacingNewerCloudCopy) {
        case .pushed:
            return true
        case .keptNewerCloudCopy:
            status = .idle
            return false
        case let .skipped(reason), let .failed(reason):
            status = .error(reason)
            return false
        }
    }

    /// Pull the cloud copy down and overlay it onto the local settings
    /// file. Returns the modification timestamp from the cloud record
    /// on success so the UI can confirm "Restored from iCloud (April
    /// 27)". Throws when no cloud record exists, or when iCloud is
    /// unreachable.
    ///
    /// Reads only from the iCloud account sync is enabled for
    /// (`CloudAccountGuard.confirmAccount`): another Apple ID's settings are
    /// never restored onto this device. Creates no zone: a missing zone holds
    /// no copy. The restored settings take the copy's edit date
    /// (`noteRestored`).
    func restoreFromCloud() async throws -> Date {
        try await requireConfirmedAccount()
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        let record: CKRecord
        do {
            record = try await privateDB.record(for: recordID)
        } catch let error as CKError where CloudHealthScrubCoordinator.meansNoRecord(error) {
            throw RestoreError.noCloudCopy
        }
        let data = try CloudSettingsRecord.settingsJSON(from: record, archiveKey: archiveKey)
        try settingsManager.restoreFromJSON(CloudSettingsRecord.restorable(data, keepingProfileOf: settingsManager.settings))
        let editedAt = record[CloudSettingsRecord.modifiedAtField] as? Date
        noteRestored(editedAt: editedAt)
        return editedAt ?? Date()
    }

    /// Returns once the signed-in account is the one sync is enabled for;
    /// throws `RestoreError.accountNotConfirmed` with the reason otherwise.
    private func requireConfirmedAccount() async throws {
        switch await sessionSync().accountGuard.confirmAccount() {
        case .confirmed:
            return
        case let .unavailable(message):
            throw RestoreError.accountNotConfirmed(message)
        case .stopped, .differentAccount:
            throw RestoreError.accountNotConfirmed(Self.syncOffMessage)
        }
    }

    /// Why nothing goes to or comes from iCloud while sync is off: the
    /// app's own reason when it turned sync off, else the plain line.
    private static var syncOffMessage: String {
        CloudAccountIdentity.stopReason?.message ?? String(localized: "iCloud sync is off", bundle: LanguageManager.appBundle)
    }

    enum RestoreError: LocalizedError, Equatable {
        case noCloudCopy
        case cloudCopyMalformed
        /// The copy is encrypted with a cloud key this device does not hold,
        /// usually because iCloud Keychain has not delivered it yet.
        case keyNotOnThisDevice
        /// The signed-in iCloud account is not, or could not be confirmed
        /// as, the one sync is enabled for; the message says why.
        case accountNotConfirmed(String)

        var errorDescription: String? {
            switch self {
            case let .accountNotConfirmed(message):
                message
            case .noCloudCopy:
                String(localized: "No iCloud backup found. Settings haven't been backed up yet from this Apple ID.", bundle: LanguageManager.appBundle)
            case .cloudCopyMalformed:
                String(localized: "The iCloud backup couldn't be read.", bundle: LanguageManager.appBundle)
            case .keyNotOnThisDevice:
                String(
                    localized: "Your iCloud settings backup is encrypted with a key that hasn't reached this device yet. Check that iCloud Keychain is on, then try again later.",
                    bundle: LanguageManager.appBundle
                )
            }
        }
    }

    /// 2-second debounce. Long enough to coalesce rapid edits in the
    /// settings UI, short enough that the user can change something
    /// and tap "Sync now" without seeing a stale state.
    ///
    /// A push that fails (a conflict, settings not loaded yet) shows its reason
    /// in `status`; one skipped because sync is off or onboarding is not done
    /// leaves `status` alone, since that is not a failure. Either way the
    /// next settings change or the launch push tries again.
    private func scheduleDebouncedPush() {
        guard !schemaUnavailable else { return }
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            await sleepQuietly(2_000_000_000, context: "scheduleDebouncedPush")
            if Task.isCancelled { return }
            guard let self, case let .failed(reason) = await self.performPush() else { return }
            self.status = .error(reason)
        }
    }

    /// What a push did.
    private enum PushOutcome {
        case pushed
        /// Not saved: iCloud holds settings edited after this device's.
        case keptNewerCloudCopy
        /// Not attempted: sync off, onboarding unfinished, or schema paused.
        case skipped(String)
        /// Attempted and not saved.
        case failed(String)
    }

    /// Runs `pushNow` behind any push already in flight.
    private func performPush(replacingNewerCloudCopy: Bool = false) async -> PushOutcome {
        var outcome = PushOutcome.skipped("")
        await pushSerializer.run { [self] in
            outcome = await pushNow(replacingNewerCloudCopy: replacingNewerCloudCopy)
        }
        return outcome
    }

    /// On `.serverRecordChanged`, another device wrote a newer record between
    /// our fetch and save. Last-writer-wins for settings is fine — re-fetch on
    /// the next change and overwrite then. No retry here, so we don't fight
    /// the other device.
    ///
    /// A local load failure (e.g. file protection blocking) MUST skip the
    /// push — pushing the in-memory defaults would clobber the cloud copy with
    /// whatever placeholder values the app booted with.
    ///
    /// Nothing is pushed before onboarding finishes. Birthday, sex and weight
    /// are typed on the profile page, which comes before the page where the
    /// user decides whether to use iCloud at all; each of those edits posts a
    /// settings change, and without this guard the debounce uploaded them
    /// before the user had been asked. Finishing onboarding is itself a
    /// settings change, so the first push follows it without a separate hook.
    ///
    /// Nothing is written to an iCloud account other than the one sync is
    /// enabled for (`CloudAccountGuard.confirmAccount`), and a zone found gone
    /// is a deletion the user made: sync stops for them to opt in again
    /// (`CloudAccountGuard.zoneWasDeleted`) instead of the zone being created
    /// again.
    ///
    /// Callers go through `performPush`, which serializes pushes.
    private func pushNow(replacingNewerCloudCopy: Bool) async -> PushOutcome {
        if let skipped = pushSkipReason() { return .skipped(skipped) }
        do {
            try await requireConfirmedAccount()
        } catch {
            return .skipped(error.localizedDescription)
        }
        switch sealedLocalSettings() {
        case let .ready(sealed):
            status = .syncing
            return await save(sealed, replacingNewerCloudCopy: replacingNewerCloudCopy)
        case let .unavailable(reason):
            return .failed(reason)
        }
    }

    /// `pushNow`'s save of the sealed settings, and what each failure means.
    private func save(_ sealed: Data, replacingNewerCloudCopy: Bool) async -> PushOutcome {
        do {
            try await ensureZoneExists()
            guard try await saveSettingsRecord(sealed, replacingNewer: replacingNewerCloudCopy) else {
                debugLog("[CloudKitSettings] iCloud holds settings edited after this device's — left in place")
                status = .idle
                return .keptNewerCloudCopy
            }
            status = .lastPushed(Date())
            debugLog("[CloudKitSettings] settings pushed (\(sealed.count) encrypted bytes)")
            return .pushed
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            return await zoneWasDeleted(error)
        } catch let error as CKError where error.code == .serverRecordChanged {
            debugLog("[CloudKitSettings] push conflict (server has newer copy); will retry on next change", level: .warning)
            status = .idle
            return .failed(String(localized: "Another device updated the backup at the same time", bundle: LanguageManager.appBundle))
        } catch {
            return .failed(handlePushFailure(error))
        }
    }

    /// The settings zone this device created is gone: the user deleted the
    /// app's iCloud data. Not recreated; sync stops for the user to opt in
    /// again (`CloudAccountGuard.zoneWasDeleted`), and the push reports why.
    private func zoneWasDeleted(_ error: CKError) async -> PushOutcome {
        debugLog("[CloudKitSettings] settings zone gone (\(error.code.rawValue)) — not recreated", level: .warning)
        status = .idle
        let message = await sessionSync().accountGuard.zoneWasDeleted()
        return .failed(message ?? Self.syncOffMessage)
    }

    /// Why nothing may be pushed right now, or nil when a push may go ahead.
    /// Read when a push starts and again right before each iCloud write, so
    /// sync turned off while the push waits on the network writes nothing.
    private func pushSkipReason() -> String? {
        let settings = settingsManager.settings
        guard settings.iCloudSyncEnabled, settings.hasCompletedOnboarding, !PurgeGate.isPurging else {
            return String(localized: "iCloud sync is off", bundle: LanguageManager.appBundle)
        }
        guard !schemaUnavailable else { return Self.schemaPausedMessage }
        return nil
    }

    /// Thrown right before an iCloud write once a push may no longer go
    /// ahead (`pushSkipReason`).
    private struct PushNoLongerAllowed: Error {
        let reason: String
    }

    private func requirePushStillAllowed() throws {
        if let reason = pushSkipReason() { throw PushNoLongerAllowed(reason: reason) }
    }

    private static var schemaPausedMessage: String {
        String(localized: "iCloud settings backup is paused until the app restarts", bundle: LanguageManager.appBundle)
    }

    private enum SealedSettings {
        case ready(Data)
        case unavailable(String)
    }

    /// The local settings, encrypted for upload, or why there is nothing
    /// safe to push: the file isn't fully loaded (pushing defaults would
    /// clobber the cloud copy), or no cloud key is available. The second is
    /// fail-closed — no key means no push, never a plaintext one.
    private func sealedLocalSettings() -> SealedSettings {
        guard let json = settingsManager.currentSettingsJSON() else {
            debugLog("[CloudKitSettings] skipping push — local settings file isn't fully loaded yet", level: .warning)
            return .unavailable(String(localized: "Your settings haven't finished loading yet", bundle: LanguageManager.appBundle))
        }
        do {
            return .ready(try CloudPayloadCodec.sealForUpload(CloudSettingsRecord.uploadable(json)))
        } catch {
            debugLog("[CloudKitSettings] push skipped — settings could not be encrypted: \(error.localizedDescription)", level: .warning)
            status = .error(error.localizedDescription)
            return .unavailable(error.localizedDescription)
        }
    }

    /// Save the sealed settings over the cloud copy, dated with this device's
    /// last settings change. False, with nothing written, when the cloud copy
    /// was edited after that change (`CloudSettingsRecord.cloudCopyIsNewer`)
    /// and `replacingNewer` is false. A replacing push dates the copy now.
    private func saveSettingsRecord(_ sealed: Data, replacingNewer: Bool) async throws -> Bool {
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        let record: CKRecord
        do {
            record = try await privateDB.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: recordType, recordID: recordID)
        }
        let localEditedAt = UserDefaults.standard.object(forKey: Self.localEditedAtKey) as? Date
        let cloudEditedAt = record[CloudSettingsRecord.modifiedAtField] as? Date
        if !replacingNewer, CloudSettingsRecord.cloudCopyIsNewer(cloudEditedAt: cloudEditedAt, localEditedAt: localEditedAt) {
            return false
        }
        let editedAt = replacingNewer ? Date() : (localEditedAt ?? Date())
        CloudSettingsRecord.write(sealed, to: record, modifiedAt: editedAt)
        try requirePushStillAllowed()
        _ = try await privateDB.save(record)
        if replacingNewer { UserDefaults.standard.set(editedAt, forKey: Self.localEditedAtKey) }
        return true
    }

    /// A permanent schema error means the CloudKit UserSettings record type
    /// hasn't been promoted to production. Cancel the debounce so we don't
    /// fire again every 2 s on every settings tweak.
    private func handlePushFailure(_ error: Error) -> String {
        if let stopped = error as? PushNoLongerAllowed {
            status = .idle
            return stopped.reason
        }
        guard !CloudKitSyncManager.isPermanentSchemaError(error) else {
            schemaUnavailable = true
            debounceTask?.cancel()
            debugLog("[CloudKitSettings] push failed — schema not in production, suspending settings sync this launch", level: .error)
            status = .error(Self.schemaPausedMessage)
            return Self.schemaPausedMessage
        }
        debugLog("[CloudKitSettings] push failed: \(error.localizedDescription)", level: .warning)
        status = .error(error.localizedDescription)
        return error.localizedDescription
    }

    /// Set once the settings record an earlier build uploaded has been
    /// rewritten with iCloud Sync off, or found not to exist.
    static let scrubbedKey = "FlowRecovery.cloudkit.settingsHealthScrub.v1.done"

    /// With iCloud Sync off, rewrite once the settings record uploaded while
    /// it was on: a plaintext copy an older build wrote is sealed and cleared,
    /// and the profile values filled from Apple Health are removed
    /// (`CloudSettingsRecord.scrubbed`). The record keeps its contents and its
    /// edit date otherwise; nothing is written when there is no record. The
    /// caller has checked that an iCloud account is available. A record this
    /// device cannot read (another device's key, or damage) is left to the
    /// device that wrote it.
    func scrubStoredRecord(keepingOutHealthFilledFrom local: UserSettings) async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.scrubbedKey), !schemaUnavailable else { return }
        do {
            let record = try await privateDB.record(for: CKRecord.ID(recordName: recordName, zoneID: zoneID))
            let json = try CloudSettingsRecord.settingsJSON(from: record, archiveKey: archiveKey)
            let sealed = try CloudPayloadCodec.sealForUpload(CloudSettingsRecord.scrubbed(json, markedBy: local))
            CloudSettingsRecord.write(sealed, to: record, modifiedAt: (record[CloudSettingsRecord.modifiedAtField] as? Date) ?? Date())
            _ = try await privateDB.save(record)
            defaults.set(true, forKey: Self.scrubbedKey)
        } catch let error as CKError where CloudHealthScrubCoordinator.meansNoRecord(error) {
            defaults.set(true, forKey: Self.scrubbedKey)
        } catch let error as RestoreError {
            noteUnrewritableRecord(error)
        } catch {
            debugLog("[CloudKitSettings] stored record not rewritten yet: \(error.localizedDescription)", level: .warning)
        }
    }

    /// A record that is damaged is left to the device that wrote it, and the
    /// scrub is done here. One sealed with a key iCloud Keychain has not
    /// delivered yet stays pending, so the scrub runs once the key arrives
    /// instead of never.
    private func noteUnrewritableRecord(_ error: RestoreError) {
        guard error != .keyNotOnThisDevice else {
            debugLog("[CloudKitSettings] stored record not rewritten yet: \(error.localizedDescription) — retried once the key arrives", level: .warning)
            return
        }
        debugLog("[CloudKitSettings] stored record not rewritten: \(error.localizedDescription) — left to the device that wrote it", level: .warning)
        UserDefaults.standard.set(true, forKey: Self.scrubbedKey)
    }

    /// Saving a zone that already exists succeeds, so any error here is a
    /// real failure and is passed on rather than read as "zone exists". Once
    /// created it is not saved again (`zoneCreatedKey`): a save into a zone
    /// that is gone then fails with `.zoneNotFound`, which `pushNow` reads as
    /// the user's deletion.
    ///
    /// A device without the flag that has synced sessions (a build from
    /// before the flag was kept, which created this zone with every push)
    /// creates it only while the session zone is still in iCloud. Both are
    /// gone when the user deleted the app's iCloud data, and that throws
    /// `.zoneNotFound` like a save into a deleted zone, rather than bringing
    /// the zone and the settings back.
    private func ensureZoneExists() async throws {
        guard !UserDefaults.standard.bool(forKey: Self.zoneCreatedKey) else { return }
        let sessionSync = sessionSync()
        if sessionSync.zoneCreated || sessionSync.lastSyncDate != nil {
            guard try await zoneExists(sessionSync.zoneID) else { throw CKError(.zoneNotFound) }
        }
        try requirePushStillAllowed()
        _ = try await privateDB.save(CKRecordZone(zoneID: zoneID))
        UserDefaults.standard.set(true, forKey: Self.zoneCreatedKey)
    }

    /// Whether `zoneID` is in the private database; any failure other than
    /// the zone being missing is thrown.
    private func zoneExists(_ zoneID: CKRecordZone.ID) async throws -> Bool {
        do {
            _ = try await privateDB.recordZone(for: zoneID)
            return true
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            return false
        }
    }
}

// MARK: - Settings record format

/// How `UserSettings` is laid out in its CloudKit record.
///
/// ## Why the settings are encrypted
///
/// App Review Guideline 5.1.3(ii): apps "may not store personal health
/// information in iCloud." The settings are health information: birthday,
/// biological sex, body weight, resting and maximum heart rate, lactate
/// threshold, the VO2max override, HRV baselines, and the free-text reason
/// for a training break. They also hold a home address, email recipients and
/// the avatar photo. Earlier builds wrote all of it as a readable JSON string
/// in `settingsJSON`, alongside the device's name in `deviceName`.
///
/// Birthday, biological sex and body weight filled from Apple Health are not
/// uploaded at all (`uploadable`); a restore keeps this device's own values
/// for them (`restorable`).
///
/// The settings go through `CloudPayloadCodec`, the same envelope and the
/// same iCloud Keychain key as session payloads, so any device on the Apple
/// ID that can restore a session can restore the settings. `deviceName` is
/// not written: nothing reads it, and a device name is often the owner's
/// name.
///
/// ## Old records
///
/// Records written by earlier builds carry only `settingsJSON`, and they must
/// still restore. Every push from this build clears both legacy fields in the
/// same save that writes `settingsPayload`, so a record never holds the new
/// payload and a plaintext copy written by this build.
///
/// A record CAN hold both when a device on an older build pushes after this
/// one: that build writes `settingsJSON` and leaves `settingsPayload` alone.
/// Because this build always clears `settingsJSON`, its presence means the
/// newest write came from an older build, so the reader prefers it. The next
/// push from this build encrypts it and clears it again.
enum CloudSettingsRecord {
    static let payloadField = "settingsPayload"
    static let legacyJSONField = "settingsJSON"
    static let legacyDeviceNameField = "deviceName"
    static let modifiedAtField = "modifiedAt"

    /// Whether the cloud copy, edited at `cloudEditedAt`, is newer than this
    /// device's settings, last changed at `localEditedAt`. A copy with no
    /// date is never newer. Settings this device has no change time for
    /// (changed before the time was kept) are older than any dated copy: the
    /// cloud copy may hold an edit made elsewhere, and unknown is not newer.
    static func cloudCopyIsNewer(cloudEditedAt: Date?, localEditedAt: Date?) -> Bool {
        guard let cloudEditedAt else { return false }
        guard let localEditedAt else { return true }
        return cloudEditedAt > localEditedAt
    }

    /// The settings JSON as it may be uploaded: profile values filled from
    /// Apple Health are left out (`UserSettings.withoutHealthFilledProfile`).
    static func uploadable(_ json: Data) throws -> Data {
        try encoder.encode(decoder.decode(UserSettings.self, from: json).withoutHealthFilledProfile())
    }

    /// Uploaded settings the app writes itself rather than the user: the
    /// schema version, the HRV baselines the analysis keeps, the synced copy
    /// of the trial start, the sync switch (which the app also turns off),
    /// and the onboarding and launch-task progress flags.
    static let appWrittenFields: Set<String> = [
        "schemaVersion", "baselineRMSSD", "baselineHR", "trialStartDate", "iCloudSyncEnabled",
        "hasCompletedOnboarding", "hasFixedTempAsymmetry", "hasRunScoreHistoryRecompute",
        "hasAcknowledgedScoreArchitectureChange"
    ]

    /// A SHA-256 digest, in hex, of the settings as the user edits them: the
    /// uploadable JSON (`uploadable`) without `appWrittenFields`, with sorted
    /// keys. Two settings JSONs with the same digest differ at most in what
    /// the app writes or what never leaves the device.
    static func editFingerprint(_ json: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: uploadable(json)) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        let edited = object.filter { !appWrittenFields.contains($0.key) }
        let canonical = try JSONSerialization.data(withJSONObject: edited, options: [.sortedKeys])
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }

    /// A stored settings JSON as it may stay in iCloud: the profile values
    /// filled from Apple Health removed. A record written before the markers
    /// existed carries none, so a field this device marks as filled from
    /// Apple Health counts as filled in the record too when both hold the
    /// same value.
    static func scrubbed(_ json: Data, markedBy local: UserSettings) throws -> Data {
        var stored = try decoder.decode(UserSettings.self, from: json)
        stored.profileFieldsFromHealth.formUnion(local.profileFieldsFromHealth.filter { field in
            switch field {
            case .birthday: stored.birthday == local.birthday
            case .biologicalSex: stored.biologicalSex == local.biologicalSex
            case .bodyWeight: stored.bodyWeightKg == local.bodyWeightKg
            }
        })
        return try encoder.encode(stored.withoutHealthFilledProfile())
    }

    /// Restored settings JSON with this device's own values for the profile
    /// fields the backup left out (`UserSettings.keepingHealthFilledProfile`).
    static func restorable(_ json: Data, keepingProfileOf local: UserSettings) throws -> Data {
        try encoder.encode(decoder.decode(UserSettings.self, from: json).keepingHealthFilledProfile(of: local))
    }

    /// The date strategy `SettingsManager` writes and reads settings with.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Put a sealed payload on the record and remove what older builds wrote
    /// in the clear. Assigning nil deletes the field's value on save.
    static func write(_ sealed: Data, to record: CKRecord, modifiedAt: Date) {
        record[payloadField] = sealed as CKRecordValue
        record[modifiedAtField] = modifiedAt as CKRecordValue
        record[legacyJSONField] = nil
        record[legacyDeviceNameField] = nil
    }

    /// The settings JSON a record holds, from whichever field has it.
    ///
    /// The encrypted field must carry the `CloudPayloadCodec` envelope.
    /// `CloudPayloadCodec.decode` passes unrecognised bytes through unchanged,
    /// which suits its session callers, but this field has only ever been
    /// written encrypted, so anything else is damage, not an old format.
    static func settingsJSON(from record: CKRecord, archiveKey: EncryptionManager) throws -> Data {
        if let legacy = record[legacyJSONField] as? String {
            return Data(legacy.utf8)
        }
        guard let sealed = record[payloadField] as? Data,
              sealed.starts(with: CloudPayloadCodec.magic)
        else {
            throw CloudKitSettingsSync.RestoreError.cloudCopyMalformed
        }
        do {
            return try CloudPayloadCodec.decode(sealed, archiveKey: archiveKey)
        } catch CloudPayloadCodec.CodecError.noMatchingKey {
            throw CloudKitSettingsSync.RestoreError.keyNotOnThisDevice
        }
    }
}

/// Sync status lines shown in Settings → iCloud & Data, in the app language.
/// One definition each: `CloudKitSyncManager.clearNotSignedInError` matches on the
/// not-signed-in line to clear it, through `isNotSignedIn`.
enum CloudSyncMessages {
    static var notSignedIn: String { String(localized: "Not signed into iCloud", bundle: LanguageManager.appBundle) }

    /// Whether `message` is the not-signed-in line in the current app
    /// language or in any language the app ships. A stored line keeps the
    /// language it was made in, so an in-app language change in between must
    /// not stop it from being recognised.
    static func isNotSignedIn(_ message: String?) -> Bool {
        guard let message else { return false }
        if message == notSignedIn { return true }
        return Bundle.main.localizations.contains { code in
            guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
                  let bundle = Bundle(path: path) else { return false }
            return message == String(localized: "Not signed into iCloud", bundle: bundle)
        }
    }
    static var noInternet: String { String(localized: "No internet connection", bundle: LanguageManager.appBundle) }
    static var storageFull: String { String(localized: "iCloud storage full", bundle: LanguageManager.appBundle) }
    /// The sync ran, but this device could not save its record of what was
    /// uploaded; the next sync runs again rather than waiting its interval.
    static var progressNotSaved: String {
        String(localized: "Sync progress could not be saved on this device — retrying", bundle: LanguageManager.appBundle)
    }
    /// A deletion could not be written to iCloud; the next sync retries it.
    static var deletionsPending: String {
        String(localized: "Some deleted sessions are still in iCloud — retrying", bundle: LanguageManager.appBundle)
    }
    /// Sessions this device has not got into iCloud yet; the next sync
    /// tries them again.
    static func uploadsWaiting(_ count: Int) -> String {
        String(localized: "\(count) sessions still pending retry. iCloud may be unreachable.", bundle: LanguageManager.appBundle)
    }
    /// The archive's index did not load this launch, so sync cannot tell
    /// which sessions still need to go up.
    static var historyNotReadable: String {
        String(localized: "Your history on this iPhone can't be read yet. Sync will try again.", bundle: LanguageManager.appBundle)
    }
    /// Sessions on this iPhone sealed with a key it does not hold
    /// (`SessionArchive.sealedWithAnotherKeyCount`): restored from a backup
    /// without the previous phone's Keychain. They are kept, and iCloud
    /// brings back any that were synced there.
    static var historyFromAnotherPhone: String {
        String(localized: "History from your previous iPhone can't be opened on this one. If iCloud Keychain and iCloud Sync were on there, turn both on here to bring it back. Those readings are kept on this iPhone.", bundle: LanguageManager.appBundle)
    }
    static var previousSyncTimedOut: String {
        String(localized: "Previous sync timed out — retrying", bundle: LanguageManager.appBundle)
    }

    static func rateLimited(retryAfter: Double?) -> String {
        guard let retryAfter, retryAfter.isFinite else {
            return String(localized: "Rate limited", bundle: LanguageManager.appBundle)
        }
        return String(localized: "Rate limited, retry in \(Int(retryAfter)) s", bundle: LanguageManager.appBundle)
    }
}
