import CloudKit
import Foundation

// Supporting types for CloudKit sync: the timeout error, the notification
// names, the serializer that funnels concurrent syncs into one at a time, and
// the separate settings-sync object.

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
// pulls the cloud copy back down. Lives in this file so we don't need
// to touch `project.pbxproj` to add a new compilation unit.
//
// The loss-of-data hole this guards against:
//   • Settings are stored as a single JSON file at
//     `<AppGroup>/user_settings.json` with `URLFileProtection.complete`.
//   • A Watch-triggered background launch while the device is locked
//     hits `init()`, the load fails silently, defaults are kept, and
//     the next save() overwrites the real file. The user re-inputs
//     everything from scratch.
// `SettingsManager` distinguishes "file missing" from "file
// locked" and refuses to save over the locked case (see
// `SettingsManager.LoadOutcome`). This sync layer is the second leg:
// even if a save did slip through, the cloud copy is recoverable.
//
// Schema
//   • Zone: "UserSettings" (separate from the HRVSession zone so a
//     sessions-only fault recovery doesn't drag settings along).
//   • Record type: "UserSettings".
//   • Single record with fixed name "primary"; last-writer-wins.
//   • Fields written: `settingsPayload` (Bytes, the encrypted settings) and
//     `modifiedAt` (Date, for the "last synced" UI). See
//     `CloudSettingsRecord` for why, and for the two legacy fields every
//     push clears.

@Observable

@MainActor
final class CloudKitSettingsSync {
    static let shared = CloudKitSettingsSync()

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
    private var zoneEnsured = false
    /// Sticky per-launch flag. Set when the UserSettings record type isn't
    /// in production schema yet — same retry-storm protection as
    /// `CloudKitSyncManager.schemaUnavailable`, applied to the settings
    /// sync path. Without this, every `.flowRecoverySettingsChanged`
    /// notification keeps re-arming the debounce → another doomed push.
    private var schemaUnavailable = false

    private init() {
        // Listen to the same notification SettingsManager fires on every
        // change. Debounce so a flurry of edits (e.g. user rapidly
        // toggling a row) collapses into one push.
        changeObserver = NotificationCenter.default.addObserver(
            forName: .flowRecoverySettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleDebouncedPush() }
        }
    }

    /// Push the current settings now, without debounce. Called by the
    /// app-launch hook so the cloud copy stays current even when the
    /// user only adjusts settings on one device per session, and by the
    /// "Back Up Settings" button.
    ///
    /// True only when the settings were saved to iCloud. Anything else also
    /// leaves `status` as `.error` with the reason: a push that was skipped
    /// or lost a conflict used to leave `status` unchanged, and the button
    /// reported a backup that never happened.
    @discardableResult
    func pushImmediately() async -> Bool {
        guard let reason = await performPush() else { return true }
        status = .error(reason)
        return false
    }

    /// Pull the cloud copy down and overlay it onto the local settings
    /// file. Returns the modification timestamp from the cloud record
    /// on success so the UI can confirm "Restored from iCloud (April
    /// 27)". Throws when no cloud record exists, or when iCloud is
    /// unreachable.
    func restoreFromCloud() async throws -> Date {
        try await ensureZoneExists()
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        let record: CKRecord
        do {
            record = try await privateDB.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            throw RestoreError.noCloudCopy
        }
        let settingsManager = AppDependencies.current.app.settingsManager
        let data = try CloudSettingsRecord.settingsJSON(from: record)
        try settingsManager.restoreFromJSON(CloudSettingsRecord.restorable(data, keepingProfileOf: settingsManager.settings))
        let modifiedAt = (record["modifiedAt"] as? Date) ?? Date()
        return modifiedAt
    }

    enum RestoreError: LocalizedError {
        case noCloudCopy
        case cloudCopyMalformed
        /// The copy is encrypted with a cloud key this device does not hold,
        /// usually because iCloud Keychain has not delivered it yet.
        case keyNotOnThisDevice

        var errorDescription: String? {
            switch self {
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
    private func scheduleDebouncedPush() {
        guard !schemaUnavailable else { return }
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            await sleepQuietly(2_000_000_000, context: "scheduleDebouncedPush")
            if Task.isCancelled { return }
            await self?.performPush()
        }
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
    /// Returns nil when the settings were saved, otherwise why they were not.
    @discardableResult
    private func performPush() async -> String? {
        if let skipped = pushSkipReason() { return skipped }
        let sealed: Data
        switch sealedLocalSettings() {
        case let .ready(data): sealed = data
        case let .unavailable(reason): return reason
        }
        status = .syncing
        do {
            try await ensureZoneExists()
            try await saveSettingsRecord(sealed)
            status = .lastPushed(Date())
            debugLog("[CloudKitSettings] settings pushed (\(sealed.count) encrypted bytes)")
            return nil
        } catch let error as CKError where error.code == .serverRecordChanged {
            debugLog("[CloudKitSettings] push conflict (server has newer copy); will retry on next change", level: .warning)
            status = .idle
            return String(localized: "Another device updated the backup at the same time", bundle: LanguageManager.appBundle)
        } catch {
            return handlePushFailure(error)
        }
    }

    /// Why nothing may be pushed right now, or nil when a push may go ahead.
    private func pushSkipReason() -> String? {
        let settings = AppDependencies.current.app.settingsManager.settings
        guard settings.iCloudSyncEnabled, settings.hasCompletedOnboarding else {
            return String(localized: "iCloud sync is off", bundle: LanguageManager.appBundle)
        }
        guard !schemaUnavailable else { return Self.schemaPausedMessage }
        return nil
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
        guard let json = AppDependencies.current.app.settingsManager.currentSettingsJSON() else {
            debugLog("[CloudKitSettings] skipping push — local settings file isn't fully loaded yet", level: .warning)
            return .unavailable(String(localized: "Your settings haven't finished loading yet", bundle: LanguageManager.appBundle))
        }
        do {
            return .ready(try CloudSettingsRecord.encryptedSettingsPayload(CloudSettingsRecord.uploadable(json)))
        } catch {
            debugLog("[CloudKitSettings] push skipped — settings could not be encrypted: \(error.localizedDescription)", level: .warning)
            status = .error(error.localizedDescription)
            return .unavailable(error.localizedDescription)
        }
    }

    private func saveSettingsRecord(_ sealed: Data) async throws {
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        let record: CKRecord
        do {
            record = try await privateDB.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: recordType, recordID: recordID)
        }
        CloudSettingsRecord.write(sealed, to: record, modifiedAt: Date())
        try await privateDB.save(record)
    }

    /// A permanent schema error means the CloudKit UserSettings record type
    /// hasn't been promoted to production. Cancel the debounce so we don't
    /// fire again every 2 s on every settings tweak.
    private func handlePushFailure(_ error: Error) -> String {
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
            let json = try CloudSettingsRecord.settingsJSON(from: record)
            let sealed = try CloudSettingsRecord.encryptedSettingsPayload(CloudSettingsRecord.scrubbed(json, markedBy: local))
            CloudSettingsRecord.write(sealed, to: record, modifiedAt: (record[CloudSettingsRecord.modifiedAtField] as? Date) ?? Date())
            try await privateDB.save(record)
            defaults.set(true, forKey: Self.scrubbedKey)
        } catch let error as CKError where CloudHealthScrubCoordinator.meansNoRecord(error) {
            defaults.set(true, forKey: Self.scrubbedKey)
        } catch let error as RestoreError {
            debugLog("[CloudKitSettings] stored record not rewritten: \(error.localizedDescription) — left to the device that wrote it", level: .warning)
            defaults.set(true, forKey: Self.scrubbedKey)
        } catch {
            debugLog("[CloudKitSettings] stored record not rewritten yet: \(error.localizedDescription)", level: .warning)
        }
    }

    /// Saving a zone that already exists succeeds, so any error here is a
    /// real failure and is passed on rather than read as "zone exists".
    private func ensureZoneExists() async throws {
        guard !zoneEnsured else { return }
        try await privateDB.save(CKRecordZone(zoneID: zoneID))
        zoneEnsured = true
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
/// The settings now go through `CloudPayloadCodec`, the same envelope and the
/// same iCloud Keychain key as session payloads, so any device on the Apple
/// ID that can restore a session can restore the settings. `deviceName` is no
/// longer written: nothing read it, and a device name is often the owner's
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

    /// The settings JSON as it may be uploaded: profile values filled from
    /// Apple Health are left out (`UserSettings.withoutHealthFilledProfile`).
    static func uploadable(_ json: Data) throws -> Data {
        try encoder.encode(decoder.decode(UserSettings.self, from: json).withoutHealthFilledProfile())
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

    /// Seal the settings JSON for upload.
    ///
    /// Throws when no cloud key is available rather than falling back to
    /// plaintext — the same fail-closed rule as the session payloads. A
    /// skipped settings backup is retried on the next change; an uploaded
    /// plaintext one cannot be recalled.
    static func encryptedSettingsPayload(_ json: Data) throws -> Data {
        guard CloudPayloadCodec.hasUsableKey else { throw CloudSyncError.encryptionUnavailable }
        return try CloudPayloadCodec.encode(json)
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
    static func settingsJSON(from record: CKRecord) throws -> Data {
        if let legacy = record[legacyJSONField] as? String {
            return Data(legacy.utf8)
        }
        guard let sealed = record[payloadField] as? Data,
              sealed.starts(with: CloudPayloadCodec.magic)
        else {
            throw CloudKitSettingsSync.RestoreError.cloudCopyMalformed
        }
        do {
            return try CloudPayloadCodec.decode(sealed)
        } catch CloudPayloadCodec.CodecError.noMatchingKey {
            throw CloudKitSettingsSync.RestoreError.keyNotOnThisDevice
        }
    }
}

/// Sync status lines shown in Settings → iCloud & Data, in the app language.
/// One definition each: `resumeSyncForAvailableAccount` matches on the
/// not-signed-in line to clear it.
enum CloudSyncMessages {
    static var notSignedIn: String { String(localized: "Not signed into iCloud", bundle: LanguageManager.appBundle) }
    static var noInternet: String { String(localized: "No internet connection", bundle: LanguageManager.appBundle) }
    static var storageFull: String { String(localized: "iCloud storage full", bundle: LanguageManager.appBundle) }
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

// MARK: - What a session carries to iCloud

/// Keeps every reading taken from Apple Health out of the session payloads
/// uploaded to iCloud.
///
/// Guideline 5.1.3(ii): apps "may not store personal health information in
/// iCloud." Every payload is already encrypted on the device before upload
/// (`CloudPayloadCodec`); on top of that, what Apple Health supplied stays
/// behind, not even uploaded as ciphertext. What the app measured itself (the
/// strap's RR series and its analysis) and the scores and figures it computed
/// travel; the readings it took from HealthKit do not:
///   • sessions read out of Apple Health whole (imported or rebuilt workouts,
///     Apple Watch Breathe readings) are not uploaded;
///   • the sleep snapshot, the sleep boundaries and segments, whether the
///     user adjusted them, and the analysis's sleep-segment label, which
///     quotes a segment's clock times;
///   • the vitals snapshot (respiratory rate, wrist temperature, SpO₂, sleep
///     heart-rate dip);
///   • VO2max and the list of recent workouts, in the session's training
///     snapshot and in the analysis result's copy of it;
///   • Apple Health's daytime resting heart rate the analysis compares the
///     night against (the nocturnal dip computed from it stays);
///   • the explanatory text of the score breakdown's Sleep and Vitals rows
///     and the numbers it quotes (`facts`), and the SpO₂ penalty line and
///     flag, which say that SpO₂ was below 95% (the sub-scores and the
///     composite stay);
///   • heart-rate-recovery samples computed from Apple Watch heart rate or
///     read from HealthKit;
///   • the heart rate on each per-second workout row filled from Apple Health
///     (`healthKitHROffsets`); for a workout recorded with Apple Watch heart
///     rate, also the per-split and per-lap heart rate and the AI snapshot's
///     current and peak heart rate, which are that wrist heart rate.
/// Load figures (ATL, CTL, TSB, TRIMP), zone times and the other scores
/// computed from these readings travel.
/// A device that pulls the session re-derives the sleep and vitals snapshots
/// from its own HealthKit store (`cloudKitSnapshotBackfillNeeded`) and shows
/// the rest as unavailable. A device that already holds the session keeps its
/// own copies of these fields when a newer iCloud copy replaces it
/// (`restoringLocalOnlyFields`).
enum CloudSessionPayload {
    /// The device ids `ImportedWorkoutBuilder.Source.appleHealth` and
    /// `.appleHealthSamples` stamp on a session built from Apple Health data.
    static let healthKitDeviceIds: Set<String> = ["healthkit-import", "healthkit-rebuild"]

    /// The device id `WorkoutRecorder` stamps on a workout whose heart rate
    /// came from Apple Watch (`makeStartProvenance`).
    static let appleWatchDeviceId = "apple-watch"

    /// Keys of a workout's AI snapshot (`HRVSession.aiContext`) that hold a
    /// heart-rate reading.
    static let heartRateContextKeys: Set<String> = ["hr", "peak_hr"]

    /// Score-breakdown rows whose explanatory text quotes HealthKit readings.
    static let healthKitFactorLabels: Set<String> = ["Sleep", "Vitals"]

    /// Whether the whole session came out of Apple Health, so none of it may
    /// be uploaded.
    static func isHealthKitSourced(_ session: HRVSession) -> Bool {
        if session.sessionType == .breathe { return true }
        guard let deviceId = session.deviceProvenance?.deviceId else { return false }
        return healthKitDeviceIds.contains(deviceId)
    }

    /// Whether the session's heart rate is Apple Watch wrist heart rate.
    static func hasAppleWatchHeartRate(_ session: HRVSession) -> Bool {
        session.deviceProvenance?.deviceId == appleWatchDeviceId
    }

    /// The session as it may be uploaded: every HealthKit reading removed,
    /// and the auto-window comparison, which only means something on the
    /// device where the window was picked.
    static func uploadable(_ session: HRVSession) -> HRVSession {
        let watchHR = hasAppleWatchHeartRate(session)
        var payload = session
        payload.sleepSnapshot = nil
        payload.vitalsSnapshot = nil
        payload.sleepStartMs = nil
        payload.sleepEndMs = nil
        payload.sleepSegments = nil
        payload.sleepUserAdjusted = nil
        payload.trainingSnapshot = session.trainingSnapshot.map(trainingWithoutHealthKitReadings)
        payload.analysisResult = session.analysisResult.map(analysisWithoutHealthKitReadings)
        payload.scoreBreakdown = session.scoreBreakdown.map(breakdownWithoutHealthKitReadings)
        payload.workoutMetadata = session.workoutMetadata.map { workoutWithoutHealthKitReadings($0, watchHR: watchHR) }
        if watchHR { payload.aiContext = session.aiContext?.filter { !heartRateContextKeys.contains($0.key) } }
        payload.autoWindowResult = nil
        payload.autoWindowScore = nil
        return payload
    }

    /// Put back into `merged`, a newer iCloud copy, the HealthKit readings this
    /// device holds and the upload left out. A field the iCloud copy does carry
    /// (a record written before these were stripped) is kept as it came.
    static func restoringLocalOnlyFields(into merged: inout HRVSession, from local: HRVSession) {
        merged.vitalsSnapshot = merged.vitalsSnapshot ?? local.vitalsSnapshot
        merged.trainingSnapshot = restoring(merged.trainingSnapshot, from: local.trainingSnapshot)
        merged.analysisResult = merged.analysisResult.map { restoring($0, from: local.analysisResult) }
        merged.scoreBreakdown = restoring(merged.scoreBreakdown, from: local.scoreBreakdown)
        merged.aiContext = restoringHeartRateContext(merged.aiContext, from: local.aiContext)
        if let metadata = merged.workoutMetadata {
            merged.workoutMetadata = restoring(metadata, from: local.workoutMetadata)
        }
    }

    // MARK: Stripping

    private static func trainingWithoutHealthKitReadings(_ context: TrainingContext) -> TrainingContext {
        TrainingContext(
            atl: context.atl, ctl: context.ctl, tsb: context.tsb,
            yesterdayTrimp: context.yesterdayTrimp, vo2Max: nil,
            daysSinceHardWorkout: context.daysSinceHardWorkout, recentWorkouts: nil
        )
    }

    private static func analysisWithoutHealthKitReadings(_ result: HRVAnalysisResult) -> HRVAnalysisResult {
        var stripped = result
        if let metrics = result.ansMetrics, metrics.daytimeRestingHR != nil {
            stripped = result.withANSMetrics(metrics.withDaytimeRestingHR(nil))
        }
        stripped.trainingContext = result.trainingContext.map(trainingWithoutHealthKitReadings)
        stripped.analysisSegmentLabel = nil
        return stripped
    }

    private static func breakdownWithoutHealthKitReadings(
        _ breakdown: RecoveryScoreCalculator.ScoreBreakdown
    ) -> RecoveryScoreCalculator.ScoreBreakdown {
        let factors = breakdown.factors.map { factor in
            healthKitFactorLabels.contains(factor.label) ? withDetail("", facts: nil, on: factor) : factor
        }
        return RecoveryScoreCalculator.ScoreBreakdown(
            compositeScore: breakdown.compositeScore, tier: breakdown.tier, factors: factors,
            penalties: penaltiesWithoutSpO2(breakdown), spo2PenaltyApplied: false,
            scoringVersion: breakdown.scoringVersion
        )
    }

    /// The penalty lines without the SpO₂ one. Scoring lists it first
    /// (`computeBreakdown`); a record scored before the lines were localized
    /// is matched by its English text instead.
    private static func penaltiesWithoutSpO2(_ breakdown: RecoveryScoreCalculator.ScoreBreakdown) -> [String] {
        var lines = breakdown.penalties
        guard breakdown.spo2PenaltyApplied, !lines.isEmpty else { return lines }
        let english = lines.firstIndex { ScoreBreakdownCopy.listsEnglishSpO2Penalty([$0]) }
        lines.remove(at: english ?? lines.startIndex)
        return lines
    }

    private static func workoutWithoutHealthKitReadings(_ metadata: WorkoutMetadata, watchHR: Bool) -> WorkoutMetadata {
        var stripped = metadata
        stripped.hrrSamples = strapMeasured(metadata.hrrSamples)
        stripped.samples = withoutHealthKitHR(metadata)
        guard watchHR else { return stripped }
        stripped.splits = metadata.splits?.map { $0.withAverageHR(nil) }
        stripped.laps = metadata.laps?.map { $0.withHeartRate(average: nil, max: nil) }
        return stripped
    }

    /// Only the samples computed from the strap's own RR stream; nil when none.
    private static func strapMeasured(_ samples: [HRRSample]?) -> [HRRSample]? {
        let strap = (samples ?? []).filter { $0.provenance == .strap }
        return strap.isEmpty ? nil : strap
    }

    /// The per-second samples with the heart rate cleared on each row
    /// `healthKitHROffsets` lists: Apple Watch wrist HR read from Apple Health.
    private static func withoutHealthKitHR(_ metadata: WorkoutMetadata?) -> [WorkoutSample]? {
        guard let samples = metadata?.samples else { return nil }
        let offsets = Set(metadata?.healthKitHROffsets ?? [])
        guard !offsets.isEmpty else { return samples }
        return samples.map { offsets.contains($0.offsetSec) ? $0.withHeartRate(nil) : $0 }
    }

    /// The factor with its line and the numbers the line quotes replaced.
    private static func withDetail(
        _ detail: String, facts: ScoreFactorFacts?, on factor: RecoveryScoreCalculator.ScoreFactor
    ) -> RecoveryScoreCalculator.ScoreFactor {
        RecoveryScoreCalculator.ScoreFactor(
            label: factor.label, detail: detail, score: factor.score, weight: factor.weight, impact: factor.impact,
            facts: facts
        )
    }

    // MARK: Restoring

    /// The local VO2max and recent-workout list on the iCloud copy's load
    /// figures. The snapshot is frozen at waking, so a missing iCloud copy
    /// keeps the local one.
    private static func restoring(_ remote: TrainingContext?, from local: TrainingContext?) -> TrainingContext? {
        guard let remote else { return local }
        guard let local, remote.vo2Max == nil, remote.recentWorkouts == nil else { return remote }
        return TrainingContext(
            atl: remote.atl, ctl: remote.ctl, tsb: remote.tsb,
            yesterdayTrimp: remote.yesterdayTrimp, vo2Max: local.vo2Max,
            daysSinceHardWorkout: remote.daysSinceHardWorkout, recentWorkouts: local.recentWorkouts
        )
    }

    /// The local training context, and, when both copies are the same
    /// analysis, the local daytime resting heart rate and sleep-segment label.
    private static func restoring(_ remote: HRVAnalysisResult, from local: HRVAnalysisResult?) -> HRVAnalysisResult {
        guard let local else { return remote }
        var merged = remote
        merged.trainingContext = restoring(remote.trainingContext, from: local.trainingContext)
        guard remote.analysisDate == local.analysisDate, remote.windowStart == local.windowStart else { return merged }
        merged.analysisSegmentLabel = remote.analysisSegmentLabel ?? local.analysisSegmentLabel
        if let metrics = remote.ansMetrics, metrics.daytimeRestingHR == nil,
           let held = local.ansMetrics?.daytimeRestingHR {
            merged = merged.withANSMetrics(metrics.withDaytimeRestingHR(held))
        }
        return merged
    }

    /// The local text of each row the upload emptied, with the numbers it
    /// quotes, when the row's sub-score is the one that text explains, and the
    /// local SpO₂ penalty line and flag when the composite is the one they
    /// explain.
    private static func restoring(
        _ remote: RecoveryScoreCalculator.ScoreBreakdown?, from local: RecoveryScoreCalculator.ScoreBreakdown?
    ) -> RecoveryScoreCalculator.ScoreBreakdown? {
        guard let remote, let local else { return remote }
        let factors = remote.factors.map { factor in
            guard factor.detail.isEmpty,
                  let held = local.factors.first(where: { $0.label == factor.label && $0.score == factor.score })
            else { return factor }
            return withDetail(held.detail, facts: held.facts, on: factor)
        }
        let heldSpO2 = local.spo2PenaltyApplied && !remote.spo2PenaltyApplied && local.compositeScore == remote.compositeScore
        return RecoveryScoreCalculator.ScoreBreakdown(
            compositeScore: remote.compositeScore, tier: remote.tier, factors: factors,
            penalties: heldSpO2 ? local.penalties : remote.penalties,
            spo2PenaltyApplied: heldSpO2 || remote.spo2PenaltyApplied,
            scoringVersion: remote.scoringVersion
        )
    }

    /// The local heart-rate entries of the AI snapshot the iCloud copy lacks.
    private static func restoringHeartRateContext(_ remote: [String: String]?, from local: [String: String]?) -> [String: String]? {
        guard var remote, let local else { return remote }
        for key in heartRateContextKeys where remote[key] == nil {
            remote[key] = local[key]
        }
        return remote
    }

    private static func restoring(_ remote: WorkoutMetadata, from local: WorkoutMetadata?) -> WorkoutMetadata {
        var metadata = remote
        metadata.hrrSamples = restoring(remote.hrrSamples, from: local?.hrrSamples)
        // A copy written before these rows were marked carries no list:
        // this device's list keeps the next upload from sending them.
        metadata.healthKitHROffsets = remote.healthKitHROffsets ?? local?.healthKitHROffsets
        metadata.samples = restoringHealthKitHR(metadata, from: local)
        metadata.splits = restoringHR(remote.splits, from: local?.splits)
        metadata.laps = restoringHR(remote.laps, from: local?.laps)
        return metadata
    }

    /// The iCloud copy's per-second samples with this device's heart rate put
    /// back on each row the upload cleared (listed in `healthKitHROffsets`).
    /// A row the iCloud copy still carries a heart rate for keeps it.
    private static func restoringHealthKitHR(_ remote: WorkoutMetadata, from local: WorkoutMetadata?) -> [WorkoutSample]? {
        guard let samples = remote.samples else { return nil }
        let offsets = Set(remote.healthKitHROffsets ?? [])
        guard !offsets.isEmpty, let localSamples = local?.samples else { return samples }
        let localHR = Dictionary(localSamples.map { ($0.offsetSec, $0.heartRate) }, uniquingKeysWith: { first, _ in first })
        return samples.map { row in
            guard row.heartRate == nil, offsets.contains(row.offsetSec), let held = localHR[row.offsetSec] ?? nil
            else { return row }
            return row.withHeartRate(held)
        }
    }

    /// The iCloud copy's splits with this device's heart rate on each split
    /// the upload cleared.
    private static func restoringHR(_ remote: [Split]?, from local: [Split]?) -> [Split]? {
        guard let remote, let local else { return remote }
        return remote.map { split in
            guard split.averageHR == nil,
                  let held = local.first(where: { $0.index == split.index && $0.durationSeconds == split.durationSeconds })
            else { return split }
            return split.withAverageHR(held.averageHR)
        }
    }

    /// The iCloud copy's laps with this device's heart rate on each lap the
    /// upload cleared.
    private static func restoringHR(_ remote: [Lap]?, from local: [Lap]?) -> [Lap]? {
        guard let remote, let local else { return remote }
        return remote.map { lap in
            guard lap.averageHR == nil, lap.maxHR == nil,
                  let held = local.first(where: { $0.index == lap.index && $0.startOffsetSec == lap.startOffsetSec })
            else { return lap }
            return lap.withHeartRate(average: held.averageHR, max: held.maxHR)
        }
    }

    /// The iCloud copy's strap samples plus the local Watch and HealthKit
    /// ones, unless the iCloud copy already carries those.
    private static func restoring(_ remote: [HRRSample]?, from local: [HRRSample]?) -> [HRRSample]? {
        let remoteSamples = remote ?? []
        guard remoteSamples.allSatisfy({ $0.provenance == .strap }) else { return remote }
        let combined = remoteSamples + (local ?? []).filter { $0.provenance != .strap }
        return combined.isEmpty ? nil : combined
    }
}

// MARK: - Copies with one reading replaced

extension HRVAnalysisResult {
    /// This result with `ansMetrics` replaced and every other field kept.
    func withANSMetrics(_ metrics: ANSMetrics?) -> HRVAnalysisResult {
        HRVAnalysisResult(
            windowStart: windowStart, windowEnd: windowEnd, timeDomain: timeDomain,
            frequencyDomain: frequencyDomain, nonlinear: nonlinear, ansMetrics: metrics,
            artifactPercentage: artifactPercentage, cleanBeatCount: cleanBeatCount, analysisDate: analysisDate,
            windowStartMs: windowStartMs, windowEndMs: windowEndMs, windowMeanHR: windowMeanHR,
            windowHRStability: windowHRStability, windowSelectionReason: windowSelectionReason,
            windowRelativePosition: windowRelativePosition, isConsolidated: isConsolidated,
            isOrganizedRecovery: isOrganizedRecovery, windowClassification: windowClassification,
            organizedRecoveryZones: organizedRecoveryZones, peakCapacity: peakCapacity,
            trainingContext: trainingContext, analysisSegmentLabel: analysisSegmentLabel, isReanalysis: isReanalysis,
            overnightNadirHR: overnightNadirHR, overnightNadirTimeMs: overnightNadirTimeMs,
            overnightMinHR: overnightMinHR, overnightMaxHR: overnightMaxHR, overnightMeanHR: overnightMeanHR
        )
    }
}

extension ANSMetrics {
    /// These metrics with the daytime resting heart rate replaced. The dip
    /// computed from it is kept.
    func withDaytimeRestingHR(_ heartRate: Double?) -> ANSMetrics {
        ANSMetrics(
            stressIndex: stressIndex, pnsIndex: pnsIndex, snsIndex: snsIndex, readinessScore: readinessScore,
            respirationRate: respirationRate, nocturnalHRDip: nocturnalHRDip,
            daytimeRestingHR: heartRate, nocturnalMedianHR: nocturnalMedianHR
        )
    }
}

extension Split {
    func withAverageHR(_ heartRate: Double?) -> Split {
        Split(
            index: index, distanceMeters: distanceMeters, durationSeconds: durationSeconds, averageHR: heartRate,
            averagePaceSecPerKm: averagePaceSecPerKm, elevationGainMeters: elevationGainMeters, averageAlpha1: averageAlpha1
        )
    }
}

extension Lap {
    func withHeartRate(average: Double?, max: Double?) -> Lap {
        Lap(
            index: index, startOffsetSec: startOffsetSec, endOffsetSec: endOffsetSec, distanceMeters: distanceMeters,
            averageHR: average, maxHR: max, averagePaceSecPerKm: averagePaceSecPerKm
        )
    }
}
