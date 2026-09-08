import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

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
///   user can remove them in the Health app under Sources → Emuqu.
@MainActor
enum DataPurgeService {
    struct Report {
        let remoteDeleted: Bool
        let archiveDeleted: Bool
        let backupsDeleted: Bool
        let cloudSyncStateReset: Bool
        let keychainCleared: Bool
        let conversationsCleared: Bool
        let userFactsCleared: Bool
        let disclaimerReset: Bool
        let assistantDisclaimerReset: Bool
        let debugLogCleared: Bool
        let crashLogsCleared: Bool
        let unitsPreferenceReset: Bool
        let widgetStateCleared: Bool
        let breadcrumbsCleared: Bool
        /// How many files/directories the container sweep removed on top of the
        /// named steps. Zero is the healthy steady state; a non-zero number
        /// means a store exists that no named step owns.
        let residualFilesRemoved: Int
        /// The same figure for `UserDefaults` keys. The container sweep covers
        /// only files; preferences are a separate storage class and were the
        /// half of "delete everything" nothing swept.
        let residualDefaultsRemoved: Int
        let errors: [String]

        var summary: String {
            (outcomeLines + errorLines + Self.footerLines).joined(separator: "\n")
        }

        private var outcomeLines: [String] {
            [
                remoteDeleted
                    ? "iCloud records: deleted (sessions, live backups, settings backup)"
                    : "iCloud records: NOT deleted — run this again with internet + iCloud signed in",
                archiveDeleted ? "Local sessions: removed" : "Local sessions: ERROR",
                backupsDeleted ? "Raw backups: removed" : "Raw backups: ERROR",
                cloudSyncStateReset ? "iCloud sync state: reset" : "iCloud sync state: ERROR",
                keychainCleared ? "AI provider keys: removed" : "AI provider keys: ERROR",
                conversationsCleared ? "AI conversation history: cleared" : "AI conversation history: ERROR",
                userFactsCleared ? "AI memory facts: cleared" : "AI memory facts: ERROR",
                disclaimerReset ? "Disclaimer acceptance: reset" : "Disclaimer acceptance: ERROR",
                assistantDisclaimerReset ? "AI assistant disclaimer: reset" : "AI assistant disclaimer: ERROR",
                debugLogCleared ? "Debug log: cleared" : "Debug log: ERROR",
                crashLogsCleared ? "Crash logs: cleared" : "Crash logs: ERROR",
                unitsPreferenceReset ? "Units preference: reset" : "Units preference: ERROR",
                widgetStateCleared ? "Home-screen widget data: cleared" : "Home-screen widget data: ERROR",
                breadcrumbsCleared ? "Get Me Back trails (GPS breadcrumbs): removed" : "Get Me Back trails (GPS breadcrumbs): ERROR",
                "Everything else on disk: \(residualFilesRemoved) item(s) removed by the container sweep",
                "Everything else in app preferences: \(residualDefaultsRemoved) key(s) removed"
            ]
        }

        private var errorLines: [String] {
            errors.isEmpty ? [] : ["", "Errors:"] + errors.map { "- \($0)" }
        }

        private static let footerLines = [
            "",
            "Restart the app to reinitialize.",
            "",
            "Note: HealthKit samples written by this app are NOT removed automatically — remove them in the Health app under Sources → Emuqu."
        ]
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
        label: String,
        reportMissingContainer: Bool,
        errors: inout [String]
    ) -> Bool {
        let fm = FileManager.default
        let container = fm.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupIdentifier)
        guard let containerURL = container else {
            if reportMissingContainer {
                errors.append("\(label): app group container unavailable")
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

    /// Executes the full purge. Best-effort: each step runs independently and
    /// failures are collected into the report rather than aborting the rest.
    /// Async because the remote CloudKit deletion is awaited (it's serialized
    /// behind any in-flight sync, so it can take a few seconds).
    ///
    /// `deleteRemote` is a test seam: unit tests inject a stub so the suite
    /// never fires a REAL zone deletion against whatever iCloud account the
    /// simulator happens to be signed into. Production callers leave it nil,
    /// which routes to `cloudSync.deleteAllRemoteData()`.
    static func purgeAllUserData(
        archive: SessionArchive,
        rawBackup: RawRRBackup,
        cloudSync: CloudKitSyncManager,
        settingsManager: SettingsManager,
        deleteRemote: (() async -> Bool)? = nil
    ) async -> Report {
        var errors: [String] = []
        let remoteDeleted = await purgeRemote(cloudSync: cloudSync, deleteRemote: deleteRemote, errors: &errors)
        // The sweep runs FIRST, before the named steps. Those steps recreate
        // the empty archive/backup directories and rewrite settings from live
        // in-memory state; sweeping afterwards would delete what they had just
        // put back.
        let sweptFiles = sweepAllContainers(errors: &errors)
        let sweptDefaults = sweepAllDefaults(errors: &errors)
        let directories = purgeDirectories(settingsManager: settingsManager, cloudSync: cloudSync, errors: &errors)
        let fallible = purgeFallibleStores(errors: &errors)
        return Report(
            remoteDeleted: remoteDeleted, archiveDeleted: directories.archive,
            backupsDeleted: directories.backups, cloudSyncStateReset: true,
            keychainCleared: directories.keychainCleared, conversationsCleared: true, userFactsCleared: true,
            disclaimerReset: true, assistantDisclaimerReset: true,
            debugLogCleared: fallible.debugLogCleared, crashLogsCleared: fallible.crashLogsCleared,
            unitsPreferenceReset: true, widgetStateCleared: fallible.widgetStateCleared,
            breadcrumbsCleared: true, residualFilesRemoved: sweptFiles,
            residualDefaultsRemoved: sweptDefaults, errors: errors
        )
    }

    // MARK: - Container sweep

    /// Everything the enumerated steps above are allowed to leave behind.
    ///
    /// ## Why this exists
    ///
    /// A hand-maintained list of stores to delete drifts: one that wiped
    /// exactly two App Group subdirectories — `HRVArchive/` and `RRBackup/` —
    /// left every other file in every container in place. Enumerating the
    /// types in `Emuqu/Sources` that write to the App Group, Application
    /// Support or Documents and cross-checking them against such a list found
    /// eight stores missed, including:
    ///
    ///   * `saved_routes.json`   — route trackpoints and geocoded road names
    ///                             (PRECISE LOCATION), the same data class the
    ///                             breadcrumb step was added to remove
    ///   * `email_contacts.json` — contact names, addresses and notes, written
    ///                             with `.completeFileProtectionUntilFirstUserAuthentication`
    ///                             under a comment reading "Contact emails are PII"
    ///   * `user_settings.json`  — age, body weight, resting HR, max HR, LTHR,
    ///                             FTP, sleep schedule
    ///   * `Assistant/artifacts.json`, `UIStateCache.json`,
    ///     `TrainingMetricsCache.json`, `beat_consistency_priors.json`,
    ///     `HRVOffline/pending.json`
    ///
    /// The list-what-to-delete design is why: it can only ever be as complete
    /// as the last person to remember to update it, and `DataPurgeServiceTests`
    /// asserted on `Report` fields, so a store absent from the `Report` was
    /// invisible to the tests too. The structure of the test mirrored the
    /// structure of the defect.
    ///
    /// So the design is inverted. The named steps above still run (they own
    /// UserDefaults keys, the Keychain and in-memory state, which a file sweep
    /// cannot reach, and their per-step reporting is what the user reads). This
    /// sweep then removes everything else in every container that is not on the
    /// keep-list below. A future store is covered on the day it is written.
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
    private static let keepList: Set<String> = [
        // Owned by the live `SettingsManager` singleton, which rewrites it from
        // in-memory state on the next mutation. Deleting the file would be a
        // race, not a wipe — `purgeLocalStores` calls `resetToDefaults()`
        // instead, which resets the in-memory copy and lets the `didSet`
        // persist a fresh-install profile.
        "user_settings.json"
    ]

    // MARK: - Preferences sweep

    /// `UserDefaults` keys a full wipe must leave alone.
    ///
    /// ## Why this exists
    ///
    /// The container sweep above inverted the file purge from "list what to
    /// delete" to "delete what is not kept", and the doc comment for it says a
    /// future store is covered on the day it is written. That was true of
    /// files and false of preferences: the named steps removed nine specific
    /// `UserDefaults` keys and nothing swept the rest. 105 distinct keys are
    /// written across the app target. Surviving a "delete all my data" were,
    /// among others, `hasAcceptedHealthDisclaimer`, the CloudKit change token
    /// and last-sync date, `reviewedRecoveredWorkoutIds`,
    /// `hkBackfillExportedWatermarkCount`, and every cached baseline
    /// (`RespiratoryBaselineCache`, `WristTemperatureBaselineCache`,
    /// `SleepDataCache`) — derived physiology, which is health data however it
    /// was derived.
    ///
    /// ## Why this list is not empty
    ///
    /// Three groups, and each one is here because sweeping it would break
    /// something a user would notice:
    ///
    ///   * `storekit.lastKnownPurchased` / `storekit.lastKnownTestFlight` are
    ///     read SYNCHRONOUSLY on the launch path — `StoreKitManager.isPurchased`
    ///     resolves from the cache before StoreKit has re-verified anything.
    ///     Deleting them would show a paying customer the paywall after they
    ///     erased their data, and offline it would not resolve at all.
    ///   * `entitlement.anchor.v1` is the same argument one layer down. Erasing
    ///     someone's data is not a refund; the anchor is deliberately
    ///     device-transferable, which is why it also lives in the iCloud
    ///     Keychain.
    ///   * The migration flags are bookkeeping, not user data. The purge has
    ///     never cleared them, and clearing them now would re-run four
    ///     migrations against a freshly emptied archive for no benefit.
    ///
    /// Deliberately NOT kept: `FeatureFlags`, which lives in the App Group
    /// suite. Every flag defaults to `true` — medical guard on, every provider
    /// enabled — so sweeping them resets toward the safe end, and a wipe
    /// resetting the user's settings is what `resetToDefaults()` already does
    /// for `UserSettings`. The in-process `FeatureFlags` cache is not
    /// invalidated, so the reset shows on next launch rather than immediately.
    ///
    /// `AppleLanguages` is covered by `systemOwnedPrefixes` rather than named
    /// here, but the reasoning is the same: the in-app language picker writes
    /// it (`SettingsView+Appearance`), so sweeping it would silently change the
    /// UI language as a side effect of a data wipe.
    private static let defaultsKeepList: Set<String> = [
        "entitlement.anchor.v1",
        "storekit.lastKnownPurchased",
        "storekit.lastKnownTestFlight"
    ]

    /// Prefixes covering the migration bookkeeping described above. Both
    /// spellings are in use — `FlowRecovery.migration.*` in `Archive+Migrations`
    /// and `didRun…_v1` in the four `RRCollector+*Migration` files.
    private static let defaultsKeepPrefixes = [
        "FlowRecovery.migration.",
        "didRun"
    ]

    /// Prefixes iOS itself writes into an app's persistent domain.
    ///
    /// Deleting one is mostly harmless — the frameworks rewrite them — but
    /// "mostly" is not a good enough reason to touch state this app does not
    /// own, and `AppleLanguages` is a case where it is not harmless at all.
    /// Checked against every `UserDefaults` key string in the app target: none
    /// of them begins with any of these, so nothing of ours hides behind one.
    private static let systemOwnedPrefixes = [
        "Apple", "NS", "com.apple.", "WebKit", "AK", "PK", "MSV", "INNext",
        "CarCapabilities", "ADPrivacy", "METAL", "GEO", "TVRemote", "SU"
    ]

    private static func isPurgeable(defaultsKey key: String) -> Bool {
        if defaultsKeepList.contains(key) { return false }
        if defaultsKeepPrefixes.contains(where: key.hasPrefix) { return false }
        if systemOwnedPrefixes.contains(where: key.hasPrefix) { return false }
        return true
    }

    /// Suites the app persists preferences into: its own domain and the App
    /// Group shared with the widget and the watch app.
    private static func defaultsDomains(errors: inout [String]) -> [(name: String, store: UserDefaults)] {
        var domains: [(String, UserDefaults)] = []
        if let bundleID = Bundle.main.bundleIdentifier {
            domains.append((bundleID, .standard))
        } else {
            // Cannot happen in a shipped app, but a silently skipped domain
            // here would mean a purge that reported success and swept nothing.
            errors.append("preferences sweep: no bundle identifier; app suite not swept")
        }
        let group = AppConfig.appGroupIdentifier
        if let groupStore = UserDefaults(suiteName: group) {
            domains.append((group, groupStore))
        } else {
            errors.append("preferences sweep: app group suite unavailable")
        }
        return domains
    }

    /// Remove every non-kept key from every suite. Returns the count so the
    /// report can say what the named steps had missed.
    ///
    /// `persistentDomain(forName:)` rather than `dictionaryRepresentation()`
    /// deliberately: the latter also surfaces the global, argument and
    /// registration domains, so it would hand back system-wide preferences this
    /// app has no business enumerating, let alone deleting.
    private static func sweepAllDefaults(errors: inout [String]) -> Int {
        var removed = 0
        for domain in defaultsDomains(errors: &errors) {
            guard let contents = domain.store.persistentDomain(forName: domain.name) else {
                errors.append("preferences sweep: domain unavailable: \(domain.name)")
                continue
            }
            for key in contents.keys where isPurgeable(defaultsKey: key) {
                domain.store.removeObject(forKey: key)
                removed += 1
            }
        }
        return removed
    }

    /// Roots a full wipe is responsible for.
    private static func purgeRoots() -> [URL] {
        let fileManager = FileManager.default
        var roots: [URL] = []
        if let group = fileManager.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupIdentifier) {
            roots.append(group)
        }
        for directory in [FileManager.SearchPathDirectory.applicationSupportDirectory, .documentDirectory, .cachesDirectory] {
            if let url = fileManager.urls(for: directory, in: .userDomainMask).first {
                roots.append(url)
            }
        }
        return roots
    }

    /// Delete every file and directory in every root that is not kept.
    /// Returns how many entries were removed, so the report can say whether the
    /// sweep found anything the named steps had missed.
    private static func sweepAllContainers(errors: inout [String]) -> Int {
        var removed = 0
        for root in purgeRoots() {
            removed += sweep(root: root, errors: &errors)
        }
        return removed
    }

    private static func sweep(root: URL, errors: inout [String]) -> Int {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: []
        ) else { return 0 }
        var removed = 0
        for entry in entries where !keepList.contains(entry.lastPathComponent) {
            do {
                try fileManager.removeItem(at: entry)
                removed += 1
            } catch {
                errors.append("residual \(entry.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return removed
    }

    /// Reset the two archive directories and then every non-file store the
    /// sweep cannot reach — UserDefaults keys, the Keychain, in-memory caches.
    private static func purgeDirectories(
        settingsManager: SettingsManager,
        cloudSync: CloudKitSyncManager,
        errors: inout [String]
    ) -> (archive: Bool, backups: Bool, keychainCleared: Bool) {
        let archive = resetAppGroupDirectory(
            named: AppConfig.archiveDirectoryName, label: "archive",
            reportMissingContainer: true, errors: &errors
        )
        let backups = resetAppGroupDirectory(
            named: AppConfig.backupDirectoryName, label: "backups",
            reportMissingContainer: false, errors: &errors
        )
        let keychainCleared = purgeLocalStores(cloudSync: cloudSync, settingsManager: settingsManager)
        purgeHealthCaches()
        return (archive, backups, keychainCleared)
    }

    /// The purge steps that can individually fail and be reported as such.
    private struct FallibleSteps {
        let debugLogCleared: Bool
        let crashLogsCleared: Bool
        let widgetStateCleared: Bool
    }

    private static func purgeFallibleStores(errors: inout [String]) -> FallibleSteps {
        let debugLogCleared = purgeDebugLog(errors: &errors)
        let crashLogsCleared = purgeCrashLogs(errors: &errors)
        let widgetStateCleared = purgeWidgetState(errors: &errors)
        return FallibleSteps(
            debugLogCleared: debugLogCleared,
            crashLogsCleared: crashLogsCleared,
            widgetStateCleared: widgetStateCleared
        )
    }

    /// Step 0, deliberately FIRST. `deleteAllRemoteData` runs through the sync
    /// serializer, so awaiting it here drains any in-flight push/pull before
    /// the local wipe (otherwise a mid-flight pull could re-archive remote
    /// sessions into the freshly cleared archive directory). On success it
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
            errors.append("iCloud: remote deletion failed — check internet + iCloud sign-in, then run Delete All My Data again")
        }
        return remoteDeleted
    }

    /// Every local store that erases without reporting failure.
    ///
    /// Workout GPS-track backups (WorkoutBackup/) are a separate directory
    /// from the RR backups and NOT covered by the age-based purgeOldBackups.
    /// They hold raw GPS tracks (precise location), so a full wipe must clear
    /// them regardless of age — otherwise up to 30 days of location data
    /// survived "Delete All My Data" (GDPR/CCPA erasure gap).
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
    private static func purgeLocalStores(cloudSync: CloudKitSyncManager, settingsManager: SettingsManager) -> Bool {
        AppDependencies.current.storage.workoutTrackBackup.purgeAll()
        cloudSync.resetLocalSyncState()
        let keychainCleared = AppDependencies.current.providers.apiKeyStore.removeAllKeys()
        AppDependencies.current.assistant.conversationStore.clear()
        AppDependencies.current.assistant.userFactsStore.clear()
        // Not `hasAcceptedDisclaimer = false` alone: that resets one flag
        // and leaves the whole biometric profile (age, body weight, resting
        // HR, max HR, LTHR, FTP, sleep schedule) in place through an erasure
        // request.
        settingsManager.resetToDefaults()
        UserDefaults.standard.removeObject(forKey: "assistant.disclaimerAccepted")
        UnitsPreferenceStore.current = .auto
        AppDependencies.current.location.breadcrumbStore.clear()
        AppDependencies.current.location.breadcrumbStore.eraseArchive()
        return keychainCleared
    }

    /// `AppDependencies.current.app.debugLogger.clear()` resets the in-memory ring buffer; we ALSO
    /// unlink the on-disk file so a user who expected "full wipe" doesn't
    /// discover the log still sitting in the App Group container with
    /// yesterday's RMSSD values.
    private static func purgeDebugLog(errors: inout [String]) -> Bool {
        AppDependencies.current.app.debugLogger.clear()
        let fm = FileManager.default
        guard let container = fm.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupIdentifier) else {
            return true
        }
        let path = container.appendingPathComponent("debug_log.txt")
        guard fm.fileExists(atPath: path.path) else { return true }
        do {
            try fm.removeItem(at: path)
            return true
        } catch {
            errors.append("debug log: \(error.localizedDescription)")
            return false
        }
    }

    /// Crash logs (current + previous boot).
    private static func purgeCrashLogs(errors: inout [String]) -> Bool {
        do {
            try AppDependencies.current.app.crashLogManager.clearAll()
            return true
        } catch {
            errors.append("crash logs: \(error.localizedDescription)")
            return false
        }
    }

    /// Erase the legacy home-screen-widget keys from the App Group store.
    ///
    /// If "Delete All Data" left these in place, a widget would keep showing
    /// yesterday's score until its next timeline refresh. GDPR / CCPA erasure
    /// requires them to go.
    ///
    /// Nothing writes these keys: an earlier build's `WidgetDataPublisher`
    /// published them for a widget target that does not exist in this project
    /// — health-derived values written into a shared container nothing could
    /// read. This erase path deliberately stays, because a user who ran that
    /// build still has those values on disk and removing the writer does not
    /// remove their data. The key list lives here for the same reason — it
    /// describes what must be cleaned up, not what is being produced.
    ///
    /// Remove this only once no supported upgrade path can still carry them.
    private static let legacyWidgetKeys = [
        "widget.todayScore", "widget.todayVerdict", "widget.todayDate",
        "widget.last3Days", "widget.totalSessions"
    ]

    private static func purgeWidgetState(errors: inout [String]) -> Bool {
        guard let widgetStore = UserDefaults(suiteName: AppConfig.appGroupIdentifier) else {
            errors.append("widget state: App Group container unavailable")
            return false
        }
        // The archive and raw backups are gone, so any pending re-encryption
        // entries point at files that no longer exist.
        PendingEncryptionLedger.clearAll()
        for key in legacyWidgetKeys {
            widgetStore.removeObject(forKey: key)
        }
        #if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
        #endif
        return true
    }

    /// Heat-acclimation persisted state includes the representative GPS
    /// coordinate (precise location). These UserDefaults keys must not
    /// survive erasure; right-to-be-forgotten requires precise location to go
    /// too.
    ///
    /// LLM cache telemetry — in-memory token/turn counters + the rolling
    /// per-provider recent-turn buffer. LLMCacheTelemetry's own doc says it
    /// is reset by this purge; without this call a "Delete All My Data"
    /// leaves the prior session's usage history
    /// sitting in memory. In-memory only (no disk), so low risk; resets to a
    /// clean launch-state. No separate persisted LLM request audit exists.
    ///
    /// The health-metric baseline caches + the recovery-score feedback log
    /// persist health data (sleep stages, respiratory-rate baseline,
    /// wrist-temperature baseline, and dated recovery scores) OUTSIDE the
    /// archive/backup dirs and the widget/settings keys —
    /// SleepDataCache/Respiratory/WristTemperature live in
    /// UserDefaults.standard, RecoveryScoreFeedbackStore in an App-Group
    /// `Feedback/` JSON file. Same erasure-gap class as the breadcrumb and
    /// widget steps: without these a "Delete All My Data" left health data on
    /// device.
    private static func purgeHealthCaches() {
        HeatAcclimationCache.clearPersistedData()
        AppDependencies.current.providers.llmCacheTelemetry.reset()
        SleepDataCache.clear()
        RespiratoryBaselineCache.clear()
        WristTemperatureBaselineCache.clear()
        AppDependencies.current.services.recoveryScoreFeedbackStore.clearAll()
    }
}
