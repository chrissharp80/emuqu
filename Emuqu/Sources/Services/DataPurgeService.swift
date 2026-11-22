import Foundation
import UserNotifications

/// Fans out a "Delete All My Data" request across every store the app writes
/// to: remote CloudKit records (the app's private-DB zones), local archive,
/// raw RR backups, CloudKit sync state (local), Keychain API keys, AI
/// conversation/facts stores, and the disclaimer-acceptance flag.
///
/// Notes:
/// - Remote deletion (GDPR Art. 17 / App Store): the purge
///   awaits `CloudKitSyncManager.deleteAllRemoteData()`, which deletes
///   the app's custom CloudKit zones ("HRVSessions" — sessions + live
///   backups — and "UserSettings") from the user's private database. It can
///   fail offline or signed-out of iCloud; the local wipe proceeds anyway
///   (the user asked for deletion regardless) and the report tells the user
///   to run the purge again with connectivity to clear iCloud.
/// - HealthKit samples written by the app are not deleted automatically. The
///   user can remove them in the Health app (picture → Privacy → Apps and Services → Emuqu).
@MainActor
enum DataPurgeService {
    /// Where a purge sweeps files and preferences. `.device` is this app's
    /// own containers and suites. Tests pass temporary ones, so running them
    /// does not wipe the test host's files and preferences.
    @MainActor
    struct PurgeScope {
        /// The App Group container: the archive, the raw backups and the
        /// stores shared with the watch app.
        let appGroupContainer: URL?
        /// Application Support, Documents, Caches and tmp.
        let sandboxRoots: [URL]
        /// The preference suites, with an error for each that cannot be opened.
        let defaultsDomains: @MainActor (inout [String]) -> [(name: String, store: UserDefaults)]

        /// tmp is included: exports are written there before the share sheet
        /// (chat transcripts, GPX/TCX/CSV with precise GPS, PDF reports, the
        /// debug log).
        static var device: PurgeScope {
            let fileManager = FileManager.default
            let sandbox = [FileManager.SearchPathDirectory.applicationSupportDirectory, .documentDirectory, .cachesDirectory]
                .compactMap { fileManager.urls(for: $0, in: .userDomainMask).first }
            return PurgeScope(
                appGroupContainer: fileManager.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupIdentifier),
                sandboxRoots: sandbox + [fileManager.temporaryDirectory],
                defaultsDomains: { errors in deviceDefaultsDomains(errors: &errors) }
            )
        }
    }

    struct Report {
        let remoteDeleted: Bool
        let archiveDeleted: Bool
        let backupsDeleted: Bool
        let cloudSyncStateReset: Bool
        let keychainCleared: Bool
        let conversationsCleared: Bool
        let userFactsCleared: Bool
        let disclaimerReset: Bool
        /// The settings file read back after the reset holds the fresh-install
        /// profile (age, body weight, heart-rate markers, FTP, sleep schedule).
        let profileReset: Bool
        let assistantDisclaimerReset: Bool
        let debugLogCleared: Bool
        let crashLogsCleared: Bool
        let unitsPreferenceReset: Bool
        let breadcrumbsCleared: Bool
        /// How many top-level files/directories the container sweep removed.
        /// The sweep runs before the named steps, so this counts their stores
        /// too (the archive, raw backups, breadcrumbs, the debug log …) and is
        /// non-zero for anyone with data; it is not a count of stores that no
        /// named step owns.
        let residualFilesRemoved: Int
        /// The same figure for `UserDefaults` keys. The container sweep covers
        /// only files; preferences are a separate storage class and were the
        /// half of "delete everything" nothing swept.
        let residualDefaultsRemoved: Int
        let errors: [String]

        var summary: String {
            (outcomeLines + errorLines + Self.footerLines).joined(separator: "\n")
        }

        /// What each step did, then the restart and Apple Health notes: the
        /// result as the page shows it in ordinary text.
        var outcomeText: String {
            (outcomeLines + Self.footerLines).joined(separator: "\n")
        }

        /// The steps that failed, one per line; nil when every step succeeded.
        var problemText: String? {
            errors.isEmpty ? nil : errors.map { "- \($0)" }.joined(separator: "\n")
        }

        /// One line per step, in the app's language: "<step>: <outcome>".
        private var outcomeLines: [String] {
            let b = LanguageManager.appBundle
            return [remoteLine] + stepLines(b) + [
                String(localized: "Everything else on disk: \(residualFilesRemoved) item(s) removed by the container sweep", bundle: b),
                String(localized: "Everything else in app preferences: \(residualDefaultsRemoved) key(s) removed", bundle: b)
            ]
        }

        private var remoteLine: String {
            let b = LanguageManager.appBundle
            let outcome = remoteDeleted
                ? String(localized: "deleted (sessions, live backups, settings backup)", bundle: b)
                : String(localized: "NOT deleted — run this again with internet + iCloud signed in", bundle: b)
            return Self.line(String(localized: "iCloud records", bundle: b), outcome)
        }

        private func stepLines(_ b: Bundle) -> [String] {
            let (removed, cleared, reset) = (Outcome.removed, Outcome.cleared, Outcome.reset)
            return [
                Self.step(String(localized: "Local sessions", bundle: b), archiveDeleted, removed),
                Self.step(String(localized: "Raw backups", bundle: b), backupsDeleted, removed),
                Self.step(String(localized: "iCloud sync state", bundle: b), cloudSyncStateReset, reset),
                Self.step(String(localized: "AI provider keys", bundle: b), keychainCleared, removed),
                Self.step(String(localized: "AI conversation history", bundle: b), conversationsCleared, cleared),
                Self.step(String(localized: "AI memory facts", bundle: b), userFactsCleared, cleared),
                Self.step(String(localized: "Profile", bundle: b), profileReset, reset),
                Self.step(String(localized: "Disclaimer acceptance", bundle: b), disclaimerReset, reset),
                Self.step(String(localized: "AI assistant disclaimer", bundle: b), assistantDisclaimerReset, reset),
                Self.step(String(localized: "Debug log", bundle: b), debugLogCleared, cleared),
                Self.step(String(localized: "Crash logs", bundle: b), crashLogsCleared, cleared),
                Self.step(String(localized: "Units preference", bundle: b), unitsPreferenceReset, reset),
                Self.step(String(localized: "Get Me Back trails (GPS breadcrumbs)", bundle: b), breadcrumbsCleared, removed)
            ]
        }

        /// What a step that succeeded did.
        private enum Outcome {
            case removed, cleared, reset

            var text: String {
                let b = LanguageManager.appBundle
                return switch self {
                case .removed: String(localized: "removed", bundle: b, comment: "Delete All My Data step outcome")
                case .cleared: String(localized: "cleared", bundle: b, comment: "Delete All My Data step outcome")
                case .reset: String(localized: "reset", bundle: b, comment: "Delete All My Data step outcome")
                }
            }
        }

        private static func step(_ label: String, _ succeeded: Bool, _ outcome: Outcome) -> String {
            let status = succeeded
                ? outcome.text
                : String(localized: "ERROR", bundle: LanguageManager.appBundle, comment: "Delete All My Data step outcome")
            return line(label, status)
        }

        private static func line(_ label: String, _ status: String) -> String {
            String(localized: "\(label): \(status)", bundle: LanguageManager.appBundle)
        }

        private var errorLines: [String] {
            errors.isEmpty ? [] : ["", String(localized: "Errors:", bundle: LanguageManager.appBundle)] + errors.map { "- \($0)" }
        }

        private static var footerLines: [String] {
            let bundle = LanguageManager.appBundle
            return [
                "",
                String(localized: "Close Emuqu and open it again to start from the beginning.", bundle: bundle),
                "",
                String(localized: "Note: Apple Health samples written by this app are NOT removed automatically — remove them in the Health app: tap your picture, then Privacy, then Apps and Services, then Emuqu.", bundle: bundle)
            ]
        }
    }

    /// Deletes and recreates one App Group directory. Returns whether the
    /// wipe succeeded, appending a user-facing reason to `errors` when not.
    ///
    /// Shared by steps 1 and 2 of `purgeAllUserData`, which are otherwise
    /// the same 15-line block twice.
    ///
    /// `reportMissingContainer` preserves an asymmetry that is easy to
    /// "tidy away" into a behaviour change: the
    /// archive step reports an unavailable App Group container as an error,
    /// the backups step silently returns false. `Report.errors` is surfaced
    /// to the user and asserted by `DataPurgeServiceTests`, so the two steps
    /// keep their existing voices rather than being unified.
    private static func resetAppGroupDirectory(
        named name: String,
        in container: URL?,
        label: String,
        reportMissingContainer: Bool,
        errors: inout [String]
    ) -> Bool {
        let fm = FileManager.default
        guard let containerURL = container else {
            if reportMissingContainer {
                errors.append(String(localized: "\(label): app group container unavailable", bundle: LanguageManager.appBundle))
            }
            return false
        }
        let dir = containerURL.appendingPathComponent(name)
        do {
            if fm.fileExists(atPath: dir.path) {
                try fm.removeItem(at: dir)
            }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return true
        } catch {
            errors.append("\(label): \(error.localizedDescription)")
            return false
        }
    }

    /// Why a purge did not run, or stopped before the local wipe.
    enum Refusal: Error, LocalizedError {
        /// A recording is under way, or a reading is waiting to be accepted
        /// (see `isRecordingInProgress`). Nothing was deleted.
        case recordingInProgress
        /// A recording started while the iCloud copy was being deleted. iCloud
        /// sync was already off and the remote deletion had run, but nothing on
        /// this device was deleted: the recording would have written its beats
        /// back into the emptied backups.
        case recordingStartedDuringDelete

        var errorDescription: String? {
            switch self {
            case .recordingInProgress:
                String(localized: "Stop the recording in progress, or accept or discard the reading that is waiting for review, first. Otherwise its data would be saved again after the delete.", bundle: LanguageManager.appBundle)
            case .recordingStartedDuringDelete:
                String(localized: "A recording started while your data was being deleted, so nothing on this device was deleted. iCloud sync is now off. Stop the recording, then run Delete All My Data again.", bundle: LanguageManager.appBundle)
            }
        }
    }

    /// Whether a recording is under way: a quick reading, an overnight
    /// stream (also while it is paused or its stopped night is being
    /// analysed), a recording on the strap, or a workout (also while it is
    /// paused or being finalised). A purge while one runs is undone by it:
    /// the recording still holds its beats in memory and writes them back to
    /// the emptied backups, and its session is archived when it stops. A
    /// reading waiting for the user to accept or discard it counts too:
    /// accepting it after the purge would archive the pre-purge session.
    static func isRecordingInProgress(collector: RRCollector?, workout: WorkoutRecorder?) -> Bool {
        if let collector, collectorIsRecording(collector) { return true }
        if let workout, workoutIsRecording(workout) { return true }
        return false
    }

    private static func collectorIsRecording(_ collector: RRCollector) -> Bool {
        if collector.isCollecting || collector.isOvernightStreaming || collector.isPaused
            || collector.isRecordingOnDevice || collector.needsAcceptance {
            return true
        }
        return switch collector.recordingPhase {
        case .streaming, .overnightStreaming, .deviceRecording, .paused, .analyzing, .awaitingAcceptance: true
        case .idle: false
        }
    }

    /// `.recording` covers a paused workout too: pausing keeps the phase.
    private static func workoutIsRecording(_ workout: WorkoutRecorder) -> Bool {
        switch workout.phase {
        case .recording, .finalizing: true
        case .idle, .finished, .failed: false
        }
    }

    /// The running app's answer: `RRCollector.current` and the app's workout
    /// recorder, held by `recorderBox`.
    private static func appIsRecording(recorderBox: @MainActor () -> RecorderBox) -> Bool {
        isRecordingInProgress(collector: RRCollector.current, workout: recorderBox().recorder)
    }

    /// Executes the full purge. Best-effort: each step runs independently and
    /// failures are collected into the report rather than aborting the rest.
    /// Async because the remote CloudKit deletion is awaited (it's serialized
    /// behind any in-flight sync, so it can take a few seconds).
    ///
    /// Throws `Refusal.recordingInProgress`, before deleting anything, while
    /// a recording is under way. `recordingInProgress` answers that: nil
    /// asks `isRecordingInProgress` about the running collector
    /// (`RRCollector.current`) and the app's workout recorder
    /// (`appIsRecording`); tests pass their own answer. It is asked again
    /// once the remote deletion has returned: a recording started during that
    /// wait throws `Refusal.recordingStartedDuringDelete` and the device is
    /// not wiped.
    ///
    /// The whole purge holds `PurgeGate`: it first waits for the archive
    /// writes already under way to finish, and from then on every archive
    /// write (a rescore, an acceptance, a CloudKit pull, a migration) and
    /// every CloudKit upload or full sync is refused until it returns. iCloud
    /// sync is switched off before the remote deletion starts, so a sync
    /// queued behind that deletion finds it off and does not upload the
    /// archive back into the emptied iCloud.
    ///
    /// `stores` are the services every step beyond the named ones clears or
    /// reads back; production passes the composition root's
    /// (`AppDependencies.purgeStores`), tests their own.
    ///
    /// `deleteRemote` is a test seam: unit tests inject a stub so the suite
    /// never fires a REAL zone deletion against whatever iCloud account the
    /// simulator happens to be signed into. Production callers leave it nil,
    /// which routes to `cloudSync.deleteAllRemoteData()`. `scope` is the
    /// other one: production leaves it `.device`; tests sweep temporary
    /// directories and a throwaway preference suite. `baselineTracker` is a
    /// third: nil resets the running collector's tracker
    /// (`RRCollector.current`), and tests pass one on a temporary file.
    ///
    /// The sweep runs FIRST, before the named steps. Those steps recreate
    /// the empty archive/backup directories and rewrite settings from live
    /// in-memory state; sweeping afterwards would delete what they had just
    /// put back.
    static func purgeAllUserData(
        archive: SessionArchive,
        rawBackup: RawRRBackup,
        cloudSync: CloudKitSyncManager,
        settingsManager: SettingsManager,
        stores: Stores,
        baselineTracker: BaselineTracker? = nil,
        recordingInProgress: (@MainActor () -> Bool)? = nil,
        deleteRemote: (() async -> Bool)? = nil,
        scope: PurgeScope = .device
    ) async throws(Refusal) -> Report {
        let isRecording: @MainActor () -> Bool = { recordingInProgress?() ?? appIsRecording(recorderBox: stores.recorderBox) }
        guard !isRecording() else { throw Refusal.recordingInProgress }
        await PurgeGate.beginPurge()
        defer { PurgeGate.endPurge() }
        settingsManager.settings.iCloudSyncEnabled = false
        var errors: [String] = []
        let remoteDeleted = await purgeRemote(cloudSync: cloudSync, deleteRemote: deleteRemote, errors: &errors)
        guard !isRecording() else { throw Refusal.recordingStartedDuringDelete }
        let sweptFiles = sweepAndForget(archive: archive, rawBackup: rawBackup, scope: scope, liveSettingsFile: settingsManager.settingsURL, errors: &errors)
        let sweptDefaults = sweepAllDefaults(scope: scope, errors: &errors)
        let directories = purgeDirectories(settingsManager: settingsManager, cloudSync: cloudSync, stores: stores, scope: scope, errors: &errors)
        resetBaseline(baselineTracker ?? RRCollector.current?.baselineTracker)
        let fallible = purgeFallibleStores(stores.device, errors: &errors)
        let profileReset = readBackProfile(settingsManager: settingsManager, errors: &errors)
        let left = readBackClearedStores(settingsManager: settingsManager, cloudSync: cloudSync, stores: stores)
        return report(
            remoteDeleted: remoteDeleted, swept: (sweptFiles, sweptDefaults), directories: directories,
            steps: (fallible, profileReset, left), errors: errors
        )
    }

    /// The page's report from what each step returned.
    private static func report(
        remoteDeleted: Bool, swept: (files: Int, defaults: Int),
        directories: (archive: Bool, backups: Bool, keychainCleared: Bool),
        steps: (fallible: FallibleSteps, profileReset: Bool, left: ReadBack), errors: [String]
    ) -> Report {
        let left = steps.left
        return Report(
            remoteDeleted: remoteDeleted, archiveDeleted: directories.archive,
            backupsDeleted: directories.backups, cloudSyncStateReset: left.cloudSyncStateReset,
            keychainCleared: directories.keychainCleared, conversationsCleared: left.conversationsCleared,
            userFactsCleared: left.userFactsCleared, disclaimerReset: left.disclaimerReset,
            profileReset: steps.profileReset, assistantDisclaimerReset: left.assistantDisclaimerReset,
            debugLogCleared: steps.fallible.debugLogCleared, crashLogsCleared: steps.fallible.crashLogsCleared,
            unitsPreferenceReset: left.unitsPreferenceReset, breadcrumbsCleared: left.breadcrumbsCleared,
            residualFilesRemoved: swept.files, residualDefaultsRemoved: swept.defaults, errors: errors
        )
    }

    /// The steps whose store calls report no failure of their own, each read
    /// back from the store after every step ran, so the page shows "ERROR"
    /// for a store that still holds data instead of assuming success. Where
    /// the store persists, what it persisted is read, not its memory.
    private struct ReadBack {
        let cloudSyncStateReset: Bool
        let conversationsCleared: Bool
        let userFactsCleared: Bool
        let disclaimerReset: Bool
        let assistantDisclaimerReset: Bool
        let unitsPreferenceReset: Bool
        let breadcrumbsCleared: Bool
    }

    /// The breadcrumb, conversation and facts checks are queued behind each
    /// store's pending clear, erase or write, so they see its result. The
    /// conversation and facts are read from their files: a file that cannot
    /// be read or decoded is not reported as cleared. Both disclaimer flags
    /// and the units preference are read from `UserDefaults`, where they are
    /// stored; the assistant's flag must also be off in the view model, which
    /// gates on its own copy.
    private static func readBackClearedStores(
        settingsManager: SettingsManager, cloudSync: CloudKitSyncManager, stores: Stores
    ) -> ReadBack {
        let assistant = stores.assistant
        let facts = assistant.userFactsStore()
        let breadcrumbs = stores.location.breadcrumbStore()
        return ReadBack(
            cloudSyncStateReset: cloudSync.lastSyncDate == nil && !cloudSync.zoneCreated,
            conversationsCleared: assistant.conversationStore().isEmptyOnDisk(),
            userFactsCleared: facts.facts.isEmpty && facts.persistedFacts()?.isEmpty == true,
            disclaimerReset: !settingsManager.hasAcceptedDisclaimer,
            assistantDisclaimerReset: !UserDefaults.standard.bool(forKey: AssistantViewModel.disclaimerKey)
                && !assistant.assistantViewModel().hasAcceptedDisclaimer,
            unitsPreferenceReset: UnitsPreferenceStore.current == .auto,
            breadcrumbsCleared: !breadcrumbs.hasActiveTrail() && !breadcrumbs.hasArchiveFile()
        )
    }

    /// What `purgeLocalStores` resets the settings to: a fresh install's,
    /// with iCloud sync left off.
    private static var purgedSettings: UserSettings {
        var settings = UserSettings()
        settings.iCloudSyncEnabled = false
        return settings
    }

    /// The "Profile" line: the reset is an asynchronous write whose failure
    /// the settings manager only logs, so the pending write is flushed here
    /// and the file read back. It must hold `purgedSettings`; a write, read or
    /// decode error, or any other profile on disk, is reported.
    private static func readBackProfile(settingsManager: SettingsManager, errors: inout [String]) -> Bool {
        let label = String(localized: "Profile", bundle: LanguageManager.appBundle)
        do {
            guard try settingsManager.flushedFileHolds(purgedSettings) else {
                let detail = String(localized: "the saved settings still hold an earlier profile", bundle: LanguageManager.appBundle)
                errors.append(String(localized: "\(label): \(detail)", bundle: LanguageManager.appBundle))
                return false
            }
            return true
        } catch {
            errors.append(String(localized: "\(label): \(error.localizedDescription)", bundle: LanguageManager.appBundle))
            return false
        }
    }

    /// The personal baseline (up to 90 nights of HRV and heart rate) is held
    /// in memory by the collector's tracker for the life of the process. Its
    /// file went with the sweep, but the next night's `update` would have
    /// written every remembered night back, so the tracker itself is reset;
    /// `reset()` saves the empty baseline. No tracker (no collector, as in a
    /// preview): nothing is held in memory.
    private static func resetBaseline(_ tracker: BaselineTracker?) {
        tracker?.reset()
    }

    /// Sweeps every container, then resets what still pointed into it: the
    /// archive's and raw backup's in-memory indexes list the deleted files
    /// until reset, and every screen showing the archive is told it changed.
    private static func sweepAndForget(
        archive: SessionArchive, rawBackup: RawRRBackup, scope: PurgeScope, liveSettingsFile: URL, errors: inout [String]
    ) -> Int {
        let sweptFiles = sweepAllContainers(scope: scope, liveSettingsFile: liveSettingsFile, errors: &errors)
        archive.resetInMemoryStateAfterPurge()
        rawBackup.resetInMemoryStateAfterPurge()
        NotificationCenter.default.post(name: .flowRecoveryArchiveChanged, object: nil)
        return sweptFiles
    }

    // MARK: - Container sweep

    /// Everything the enumerated steps above are allowed to leave behind.
    ///
    /// ## Why this exists
    ///
    /// A hand-maintained list of stores to delete drifts: it can only ever be
    /// as complete as the last person to remember to update it, and a store
    /// missing from it survives the purge. Stores outside `HRVArchive/` and
    /// `RRBackup/` hold data as sensitive as the archive, for example:
    ///
    ///   * `saved_routes.json`   — route trackpoints and geocoded road names
    ///                             (PRECISE LOCATION)
    ///   * `email_contacts.json` — contact names, addresses and notes
    ///   * `user_settings.json`  — age, body weight, resting HR, max HR, LTHR,
    ///                             FTP, sleep schedule
    ///   * `Assistant/artifacts.json`, `UIStateCache.json`,
    ///     `TrainingMetricsCache.json`, `beat_consistency_priors.json`
    ///
    /// Tests that assert on `Report` fields cannot see a store absent from
    /// the `Report` either.
    ///
    /// The named steps above still run (they own
    /// UserDefaults keys, the Keychain and in-memory state, which a file sweep
    /// cannot reach, and their per-step reporting is what the user reads). This
    /// sweep then removes everything else in every container that this
    /// function does not keep. A future store is covered on the day it is
    /// written.
    ///
    /// `DataPurgeServiceTests.testSweepRemovesAnUnknownFileFromEveryContainer`
    /// writes a sentinel into each root and asserts it is gone — a test that
    /// fails for stores nobody has thought of yet.
    ///
    /// `"entitlement"` does not belong here: no code in the app writes such a
    /// file. `EntitlementAnchor` stores the record in the Keychain with a
    /// `UserDefaults` cache in front of it, never on disk, so an entry here
    /// would read as protection and provide none. The intent — a wipe is not
    /// a refund — lives where the data actually is, in `defaultsKeepList`
    /// below.
    ///
    /// The one file kept is the settings file the live `SettingsManager`
    /// reads and writes (`SettingsManager.settingsURL`), in its own root only.
    /// The singleton rewrites it from in-memory state on the next mutation, so
    /// deleting it would be a race, not a wipe: `purgeLocalStores` calls
    /// `resetToDefaults()` instead, and `readBackProfile` checks the result on
    /// disk. Any other `user_settings.json` — the Documents original an older
    /// build's migration copied into the App Group and left behind — holds
    /// the same profile and is removed like everything else.
    private static func keptEntries(in root: URL, liveSettingsFile: URL) -> Set<String> {
        let settingsRoot = liveSettingsFile.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        guard root.resolvingSymlinksInPath().standardizedFileURL.path == settingsRoot.path else { return [] }
        return [liveSettingsFile.lastPathComponent]
    }

    /// Roots a full wipe is responsible for, each with the entries it keeps
    /// (`keptEntries(in:liveSettingsFile:)`). The App Group container also keeps its
    /// `Library/`: iOS keeps the group suite's preferences plist (swept key by
    /// key by `sweepAllDefaults`, while `UserDefaults` still holds it in
    /// memory) and its own caches there, and the app writes nothing into it.
    static func purgeRoots(_ scope: PurgeScope, liveSettingsFile: URL) -> [(url: URL, kept: Set<String>)] {
        var roots: [(url: URL, kept: Set<String>)] = []
        if let group = scope.appGroupContainer {
            roots.append((group, keptEntries(in: group, liveSettingsFile: liveSettingsFile).union(["Library"])))
        }
        roots += scope.sandboxRoots.map { (url: $0, kept: keptEntries(in: $0, liveSettingsFile: liveSettingsFile)) }
        return roots
    }

    /// Delete every file and directory in every root that is not kept.
    /// Returns how many entries were removed (see `Report.residualFilesRemoved`).
    private static func sweepAllContainers(scope: PurgeScope, liveSettingsFile: URL, errors: inout [String]) -> Int {
        var removed = 0
        for root in purgeRoots(scope, liveSettingsFile: liveSettingsFile) {
            removed += sweep(root: root.url, keeping: root.kept, errors: &errors)
        }
        return removed
    }

    /// A root that does not exist holds nothing and is skipped. One that
    /// exists but cannot be listed is reported: its files are still there.
    private static func sweep(root: URL, keeping kept: Set<String>, errors: inout [String]) -> Int {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else { return 0 }
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [])
        } catch {
            errors.append(String(localized: "Could not list \(root.lastPathComponent): \(error.localizedDescription)", bundle: LanguageManager.appBundle))
            return 0
        }
        var removed = 0
        for entry in entries where !kept.contains(entry.lastPathComponent) {
            do {
                try fileManager.removeItem(at: entry)
                removed += 1
            } catch {
                errors.append(String(localized: "Could not remove \(entry.lastPathComponent): \(error.localizedDescription)", bundle: LanguageManager.appBundle))
            }
        }
        return removed
    }

    /// Reset the two archive directories and then every non-file store the
    /// sweep cannot reach — UserDefaults keys, the Keychain, in-memory caches.
    private static func purgeDirectories(
        settingsManager: SettingsManager,
        cloudSync: CloudKitSyncManager,
        stores: Stores,
        scope: PurgeScope,
        errors: inout [String]
    ) -> (archive: Bool, backups: Bool, keychainCleared: Bool) {
        let archive = resetAppGroupDirectory(
            named: AppConfig.archiveDirectoryName, in: scope.appGroupContainer,
            label: String(localized: "Local sessions", bundle: LanguageManager.appBundle),
            reportMissingContainer: true, errors: &errors
        )
        let backups = resetAppGroupDirectory(
            named: AppConfig.backupDirectoryName, in: scope.appGroupContainer,
            label: String(localized: "Raw backups", bundle: LanguageManager.appBundle),
            reportMissingContainer: false, errors: &errors
        )
        let keychainCleared = purgeLocalStores(cloudSync: cloudSync, settingsManager: settingsManager, stores: stores)
        cancelMorningNotifications(stores.device.morningNotificationScheduler)
        purgeHealthCaches(stores, errors: &errors)
        return (archive, backups, keychainCleared)
    }

    /// The purge steps that can individually fail and be reported as such.
    private struct FallibleSteps {
        let debugLogCleared: Bool
        let crashLogsCleared: Bool
    }

    private static func purgeFallibleStores(_ device: Stores.Device, errors: inout [String]) -> FallibleSteps {
        let debugLogCleared = purgeDebugLog(device.debugLogger, errors: &errors)
        let crashLogsCleared = purgeCrashLogs(device.crashLogManager, errors: &errors)
        // The archive and raw backups are gone, so any pending re-encryption
        // entries point at files that no longer exist.
        PendingEncryptionLedger.clearAll()
        return FallibleSteps(debugLogCleared: debugLogCleared, crashLogsCleared: crashLogsCleared)
    }

    /// Step 0, deliberately FIRST. `deleteAllRemoteData` runs through the sync
    /// serializer, so awaiting it here drains any in-flight push/pull before
    /// the local wipe (otherwise a mid-flight pull could re-archive remote
    /// sessions into the freshly cleared archive directory). A sync queued
    /// behind it runs after it with iCloud sync already off and `PurgeGate`
    /// closed (`purgeAllUserData`), so it uploads nothing. On success it
    /// also resets local sync state and clears the sanitize-drip bookkeeping.
    /// On failure the local wipe proceeds regardless — the user asked for
    /// deletion — and the report tells them to retry with connectivity.
    private static func purgeRemote(
        cloudSync: CloudKitSyncManager, deleteRemote: (() async -> Bool)?, errors: inout [String]
    ) async -> Bool {
        let remoteDeleted: Bool
        if let deleteRemote {
            remoteDeleted = await deleteRemote()
        } else {
            remoteDeleted = await cloudSync.deleteAllRemoteData()
        }
        if !remoteDeleted {
            errors.append(String(localized: "iCloud: remote deletion failed — check internet + iCloud sign-in, then run Delete All My Data again", bundle: LanguageManager.appBundle))
        }
        return remoteDeleted
    }

    /// Every local store that erases without reporting failure.
    ///
    /// Workout GPS-track backups (WorkoutBackup/) are a separate directory
    /// from the RR backups and are not cleared with them. They hold raw GPS
    /// tracks (precise location), so a full wipe must clear them too —
    /// otherwise location data survived "Delete All My Data" (GDPR/CCPA
    /// erasure gap).
    ///
    /// CloudKit local sync state is already reset by `deleteAllRemoteData`
    /// when the remote wipe succeeded; calling again is an idempotent no-op,
    /// and it's the only reset when the remote deletion failed.
    ///
    /// The disclaimer flag lives on SettingsManager (UserDefaults-backed), not
    /// on the Codable settings struct, because it must be device-local. The AI
    /// assistant's separate flag lives under a different UserDefaults key
    /// because the AI view model owns its own acceptance gate; clearing the
    /// main disclaimer alone left users in the inconsistent "agreed to AI, did
    /// not re-agree to Health" state.
    ///
    /// Units preference lived under `UserDefaults["fitness.unitsPreference"]`
    /// rather than the Codable settings struct; resetting it brings it back to
    /// `.auto`, which matches a fresh install.
    ///
    /// Get Me Back GPS breadcrumb trails — the active trail
    /// (`Breadcrumbs/active.json`) AND the archived trails
    /// (`Breadcrumbs/archive.json`), which include auto-imported workout
    /// tracks. These hold precise location history and are NOT covered by the
    /// archive/backup wipes; skipping them leaves the full breadcrumb history
    /// on disk after "Delete All My Data" (GDPR/CCPA erasure gap).
    ///
    /// iCloud sync is left OFF, not at the fresh-install default of on. The
    /// user has just asked for their iCloud copy to be deleted; defaulting sync
    /// back on would start rebuilding it as soon as they finished onboarding
    /// again, unless they noticed the pre-set toggle. Onboarding's backup page
    /// shows the switch off, and turning it on there is their choice. (The
    /// purge already turned it off before the remote deletion; the reset to
    /// defaults would turn it back on.)
    private static func purgeLocalStores(cloudSync: CloudKitSyncManager, settingsManager: SettingsManager, stores: Stores) -> Bool {
        stores.device.workoutTrackBackup().purgeAll()
        cloudSync.resetLocalSyncState()
        let keychainCleared = stores.assistant.apiKeyStore().removeAllKeys()
        // The view model too, not only its store: the turns on screen stayed in
        // memory, and the next message saved the whole old chat back to disk.
        stores.assistant.assistantViewModel().clearConversation()
        stores.assistant.conversationStore().clear()
        stores.assistant.userFactsStore().clear()
        // Not `hasAcceptedDisclaimer = false` alone: that resets one flag
        // and leaves the whole biometric profile (age, body weight, resting
        // HR, max HR, LTHR, FTP, sleep schedule) in place through an erasure
        // request.
        settingsManager.resetToDefaults()
        settingsManager.settings.iCloudSyncEnabled = false
        UserDefaults.standard.removeObject(forKey: AssistantViewModel.disclaimerKey)
        UnitsPreferenceStore.current = .auto
        stores.location.breadcrumbStore().clear()
        stores.location.breadcrumbStore().eraseArchive()
        forgetInMemoryStores(stores)
        return keychainCleared
    }

    /// Resetting the settings turns the daily report off, but the repeating request
    /// iOS holds stays scheduled until it is removed, and a delivered
    /// morning push can still show a score on the lock screen.
    private static func cancelMorningNotifications(_ scheduler: @MainActor () -> MorningNotificationScheduler) {
        scheduler().cancelAll()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    /// Their files went with the sweep; without this the routes, contacts,
    /// to-dos, the Get Me Back trail, the prefetched facts (last HRV, sleep,
    /// workout, location) and the cached location stayed in memory, readable
    /// by the assistant and written back to disk by the next add, rename or
    /// fix. The road context (street and postcode), the weather snapshot and
    /// the nearby-places cache hold the precise location too, each with the
    /// coordinate it was looked up for, and are memory-only; they are dropped
    /// with it. The engaged turn-by-turn route (destination name and coordinate)
    /// is memory-only and is dropped too, so the voice coach stops using it.
    /// The display cache (dashboard and fitness snapshots) and the training
    /// load cache (current metrics and the 400-day series) go the same way:
    /// each rewrote its pre-purge snapshot on its next persist.
    private static func forgetInMemoryStores(_ stores: Stores) {
        let location = stores.location
        location.activeRouteSession().disengage()
        location.savedRouteStore().forgetAfterPurge()
        location.breadcrumbRecorder().forgetAfterPurge()
        location.ambientLocationService().forgetAfterPurge()
        location.roadGeocodingService().forgetAfterPurge()
        location.weatherService().forgetAfterPurge()
        location.surroundingsPOIService().forgetAfterPurge()
        stores.device.emailContactStore().forgetAfterPurge()
        stores.assistant.assistantArtifactStore().forgetAfterPurge()
        stores.device.uiStateCache().forgetAfterPurge()
        stores.device.trainingMetricsCache().forgetAfterPurge()
        forgetAssistantAgreements(stores.assistant)
    }

    /// The defaults behind these are swept, but both are also held in memory
    /// for the life of the process, so until the app restarted a re-added key
    /// sent data with no consent sheet and voice chat started with no
    /// disclaimer.
    private static func forgetAssistantAgreements(_ assistant: Stores.Assistant) {
        for provider in ProviderConsentTracker.providersRequiringConsent {
            assistant.providerConsentTracker().revoke(provider)
        }
        assistant.assistantViewModel().hasAcceptedDisclaimer = false
    }

    /// `DebugLogger.clear()` empties the logger's
    /// memory and queues removal of its file. The container sweep already
    /// removed the file that existed before the purge, but the logger keeps
    /// writing while the purge runs, and neither the sweep's count nor the
    /// logger's own removal says whether that re-created log is gone. This
    /// synchronous removal of whatever is left at the logger's path
    /// (`AppConfig.sharedContainerURL()`) is what the "Debug log" line
    /// reports.
    private static func purgeDebugLog(_ logger: @MainActor () -> DebugLogger, errors: inout [String]) -> Bool {
        logger().clear()
        let fm = FileManager.default
        let path = AppConfig.sharedContainerURL().appendingPathComponent("debug_log.txt")
        guard fm.fileExists(atPath: path.path) else { return true }
        do {
            try fm.removeItem(at: path)
            return true
        } catch {
            errors.append(String(localized: "Debug log: \(error.localizedDescription)", bundle: LanguageManager.appBundle))
            return false
        }
    }

    /// Crash logs (current + previous boot).
    private static func purgeCrashLogs(_ crashLogs: @MainActor () -> CrashLogManager, errors: inout [String]) -> Bool {
        do {
            try crashLogs().clearAll()
            return true
        } catch {
            errors.append(String(localized: "Crash logs: \(error.localizedDescription)", bundle: LanguageManager.appBundle))
            return false
        }
    }

    /// Heat-acclimation persisted state includes the representative GPS
    /// coordinate (precise location). These UserDefaults keys must not
    /// survive erasure; right-to-be-forgotten requires precise location to go
    /// too. `clear()` also drops the in-memory readout and cancels a refresh
    /// in flight, so neither shows nor writes back the erased readout.
    ///
    /// LLM cache telemetry — in-memory token/turn counters + the rolling
    /// per-provider recent-turn buffer. LLMCacheTelemetry's own doc says it
    /// is reset by this purge; without this call a "Delete All My Data"
    /// leaves the prior session's usage history
    /// sitting in memory. In-memory only (no disk), so low risk; resets to a
    /// clean launch-state. The in-memory LLM request audit is cleared too:
    /// its entries hold the health data sent in each prompt.
    ///
    /// The health-metric baseline caches + the recovery-score feedback log
    /// persist health data (sleep stages, respiratory-rate baseline,
    /// wrist-temperature baseline, and dated recovery scores) OUTSIDE the
    /// archive/backup dirs and the widget/settings keys —
    /// SleepDataCache/Respiratory/WristTemperature live in
    /// UserDefaults.standard, RecoveryScoreFeedbackStore in an App-Group
    /// `Feedback/` JSON file. Same erasure-gap class as the breadcrumb and
    /// widget steps: without these a "Delete All My Data" left health data on
    /// device. A feedback log that is there and cannot be removed is reported.
    private static func purgeHealthCaches(_ stores: Stores, errors: inout [String]) {
        stores.device.heatAcclimationCache().clear()
        stores.assistant.llmCacheTelemetry().reset()
        stores.assistant.llmRequestAudit().clear()
        SleepDataCache.clear()
        RespiratoryBaselineCache.clear()
        WristTemperatureBaselineCache.clear()
        do {
            try stores.device.recoveryScoreFeedbackStore().clearAll()
        } catch {
            errors.append(String(localized: "Recovery score feedback: \(error.localizedDescription)", bundle: LanguageManager.appBundle))
        }
    }
}

extension DataPurgeService {
    /// The services the purge clears, forgets or reads back beyond the ones
    /// passed by name, handed over by the composition root
    /// (`AppDependencies.purgeStores`). Each is a resolver, not an instance,
    /// so a service is built only when the purge reaches its step, as the
    /// root's own accessors are, and a refused purge builds none. Grouped by
    /// the steps that use them.
    struct Stores {
        /// Holds the app's workout recorder, which `appIsRecording` asks about.
        let recorderBox: @MainActor () -> RecorderBox
        let assistant: Assistant
        let location: Location
        let device: Device

        /// The AI assistant's chat, memory, consent, keys and telemetry.
        struct Assistant {
            let assistantViewModel: @MainActor () -> AssistantViewModel
            let conversationStore: @MainActor () -> ConversationStore
            let userFactsStore: @MainActor () -> UserFactsStore
            let assistantArtifactStore: @MainActor () -> AssistantArtifactStore
            let providerConsentTracker: @MainActor () -> ProviderConsentTracker
            let apiKeyStore: @MainActor () -> APIKeyStore
            let llmCacheTelemetry: @MainActor () -> LLMCacheTelemetry
            let llmRequestAudit: @MainActor () -> LLMRequestAudit
        }

        /// Trails, routes and the location the app holds.
        struct Location {
            let breadcrumbStore: @MainActor () -> BreadcrumbStore
            let breadcrumbRecorder: @MainActor () -> BreadcrumbRecorder
            let activeRouteSession: @MainActor () -> ActiveRouteSession
            let savedRouteStore: @MainActor () -> SavedRouteStore
            let ambientLocationService: @MainActor () -> AmbientLocationService
            let roadGeocodingService: @MainActor () -> RoadGeocodingService
            let weatherService: @MainActor () -> WeatherService
            let surroundingsPOIService: @MainActor () -> SurroundingsPOIService
        }

        /// Everything else on the device: backups, caches, logs and the
        /// morning push.
        struct Device {
            let workoutTrackBackup: @MainActor () -> WorkoutTrackBackup
            let morningNotificationScheduler: @MainActor () -> MorningNotificationScheduler
            let emailContactStore: @MainActor () -> EmailContactStore
            let uiStateCache: @MainActor () -> UIStateCache
            let trainingMetricsCache: @MainActor () -> TrainingMetricsCache
            let heatAcclimationCache: @MainActor () -> HeatAcclimationCache
            let recoveryScoreFeedbackStore: @MainActor () -> RecoveryScoreFeedbackStore
            let debugLogger: @MainActor () -> DebugLogger
            let crashLogManager: @MainActor () -> CrashLogManager
        }
    }
}
