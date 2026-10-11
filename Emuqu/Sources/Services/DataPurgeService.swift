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
        label: String,
        reportMissingContainer: Bool,
        errors: inout [String]
    ) -> Bool {
        let fm = FileManager.default
        let container = fm.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupIdentifier)
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
        let sweptFiles = sweepAndForget(archive: archive, rawBackup: rawBackup, errors: &errors)
        let sweptDefaults = sweepAllDefaults(errors: &errors)
        let directories = purgeDirectories(settingsManager: settingsManager, cloudSync: cloudSync, errors: &errors)
        let fallible = purgeFallibleStores(errors: &errors)
        let left = readBackClearedStores(settingsManager: settingsManager, cloudSync: cloudSync)
        return Report(
            remoteDeleted: remoteDeleted, archiveDeleted: directories.archive,
            backupsDeleted: directories.backups, cloudSyncStateReset: left.cloudSyncStateReset,
            keychainCleared: directories.keychainCleared, conversationsCleared: left.conversationsCleared,
            userFactsCleared: left.userFactsCleared, disclaimerReset: left.disclaimerReset, assistantDisclaimerReset: left.assistantDisclaimerReset,
            debugLogCleared: fallible.debugLogCleared, crashLogsCleared: fallible.crashLogsCleared,
            unitsPreferenceReset: left.unitsPreferenceReset, breadcrumbsCleared: left.breadcrumbsCleared,
            residualFilesRemoved: sweptFiles, residualDefaultsRemoved: sweptDefaults, errors: errors
        )
    }

    /// The steps whose store calls report no failure of their own, each read
    /// back from the store after every step ran, so the page shows "ERROR"
    /// for a store that still holds data instead of assuming success.
    private struct ReadBack {
        let cloudSyncStateReset: Bool
        let conversationsCleared: Bool
        let userFactsCleared: Bool
        let disclaimerReset: Bool
        let assistantDisclaimerReset: Bool
        let unitsPreferenceReset: Bool
        let breadcrumbsCleared: Bool
    }

    /// The breadcrumb checks are queued behind the store's pending clear and
    /// erase, so they see their result.
    private static func readBackClearedStores(settingsManager: SettingsManager, cloudSync: CloudKitSyncManager) -> ReadBack {
        let assistant = AppDependencies.current.assistant
        let breadcrumbs = AppDependencies.current.location.breadcrumbStore
        return ReadBack(
            cloudSyncStateReset: cloudSync.lastSyncDate == nil && !cloudSync.zoneCreated,
            conversationsCleared: assistant.conversationStore.load().isEmpty,
            userFactsCleared: assistant.userFactsStore.facts.isEmpty,
            disclaimerReset: !settingsManager.hasAcceptedDisclaimer,
            assistantDisclaimerReset: !assistant.assistantViewModel.hasAcceptedDisclaimer,
            unitsPreferenceReset: UnitsPreferenceStore.current == .auto,
            breadcrumbsCleared: !breadcrumbs.hasActiveTrail() && !breadcrumbs.hasArchiveFile()
        )
    }

    /// Sweeps every container, then resets what still pointed into it: the
    /// archive's and raw backup's in-memory indexes list the deleted files
    /// until reset, and every screen showing the archive is told it changed.
    private static func sweepAndForget(archive: SessionArchive, rawBackup: RawRRBackup, errors: inout [String]) -> Int {
        let sweptFiles = sweepAllContainers(errors: &errors)
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
    /// `hkBackfillExportedWatermark`, and every cached baseline
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

    /// The migration bookkeeping described above is kept by its two
    /// spellings — `FlowRecovery.migration.*` in `Archive+Migrations` and
    /// `didRun…_v<n>` in the `RRCollector+*Migration` files. A `didRun` key
    /// is kept only when it also carries a `_v` version marker, so an
    /// ordinary key that merely starts with "didRun" is still swept.
    private static func isPurgeable(defaultsKey key: String) -> Bool {
        if defaultsKeepList.contains(key) { return false }
        if key.hasPrefix("FlowRecovery.migration.") { return false }
        if key.hasPrefix("didRun"), key.contains("_v") { return false }
        return !systemOwnedPrefixes.contains { isSystemKey(key, prefix: $0) }
    }

    /// Apple's keys continue a prefix with a capital, digit or underscore
    /// ("NSLanguages", "SUEnableAutomaticChecks"); a key that continues it
    /// with a lowercase letter ("SUmmary…") is not the system's and is swept.
    private static func isSystemKey(_ key: String, prefix: String) -> Bool {
        guard key.hasPrefix(prefix) else { return false }
        guard !prefix.hasSuffix("."), let next = key.dropFirst(prefix.count).first else { return true }
        return next.isUppercase || next.isNumber || next == "_"
    }

    /// Suites the app persists preferences into: its own domain and the App
    /// Group shared with the watch app.
    private static func defaultsDomains(errors: inout [String]) -> [(name: String, store: UserDefaults)] {
        var domains: [(String, UserDefaults)] = []
        if let bundleID = Bundle.main.bundleIdentifier {
            domains.append((bundleID, .standard))
        } else {
            // Cannot happen in a shipped app, but a silently skipped domain
            // here would mean a purge that reported success and swept nothing.
            errors.append(String(localized: "Preferences sweep: no bundle identifier; app suite not swept", bundle: LanguageManager.appBundle))
        }
        let group = AppConfig.appGroupIdentifier
        if let groupStore = UserDefaults(suiteName: group) {
            domains.append((group, groupStore))
        } else {
            errors.append(String(localized: "Preferences sweep: app group suite unavailable", bundle: LanguageManager.appBundle))
        }
        return domains
    }

    /// Remove every non-kept key from every suite. Returns the count so the
    /// report can say what the named steps had missed. This also removes the
    /// legacy `widget.*` keys an earlier build wrote into the App Group suite
    /// (health-derived scores for a widget that never shipped): none is kept.
    private static func sweepAllDefaults(errors: inout [String]) -> Int {
        var removed = 0
        for domain in defaultsDomains(errors: &errors) {
            for key in storedKeys(in: domain) where isPurgeable(defaultsKey: key) {
                domain.store.removeObject(forKey: key)
                removed += 1
            }
        }
        return removed
    }

    /// The keys a suite itself stores.
    ///
    /// `persistentDomain(forName:)` first: `dictionaryRepresentation()` also
    /// surfaces the global, argument and registration domains, preferences
    /// this app has no business enumerating, let alone deleting. iOS returns
    /// no persistent domain for an App Group suite, so for that one the keys
    /// are what the suite resolves minus what those shared domains supply.
    private static func storedKeys(in domain: (name: String, store: UserDefaults)) -> [String] {
        if let contents = domain.store.persistentDomain(forName: domain.name) {
            return Array(contents.keys)
        }
        let inherited = inheritedDefaultsKeys()
        return domain.store.dictionaryRepresentation().keys.filter { !inherited.contains($0) }
    }

    private static func inheritedDefaultsKeys() -> Set<String> {
        let defaults = UserDefaults.standard
        let global = defaults.persistentDomain(forName: UserDefaults.globalDomain) ?? [:]
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        let registration = defaults.volatileDomain(forName: UserDefaults.registrationDomain)
        return Set(global.keys).union(arguments.keys).union(registration.keys)
    }

    /// Roots a full wipe is responsible for, each with the entries it keeps.
    /// The App Group container also keeps its `Library/`: iOS keeps the group
    /// suite's preferences plist (swept key by key by `sweepAllDefaults`,
    /// while `UserDefaults` still holds it in memory) and its own caches
    /// there, and the app writes nothing into it.
    private static func purgeRoots() -> [(url: URL, kept: Set<String>)] {
        let fileManager = FileManager.default
        var roots: [(url: URL, kept: Set<String>)] = []
        if let group = fileManager.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupIdentifier) {
            roots.append((group, keepList.union(["Library"])))
        }
        for directory in [FileManager.SearchPathDirectory.applicationSupportDirectory, .documentDirectory, .cachesDirectory] {
            if let url = fileManager.urls(for: directory, in: .userDomainMask).first {
                roots.append((url, keepList))
            }
        }
        // Exports are written here before the share sheet: chat transcripts,
        // GPX/TCX/CSV with precise GPS, PDF reports, the debug log.
        roots.append((fileManager.temporaryDirectory, keepList))
        return roots
    }

    /// Delete every file and directory in every root that is not kept.
    /// Returns how many entries were removed (see `Report.residualFilesRemoved`).
    private static func sweepAllContainers(errors: inout [String]) -> Int {
        var removed = 0
        for root in purgeRoots() {
            removed += sweep(root: root.url, keeping: root.kept, errors: &errors)
        }
        return removed
    }

    private static func sweep(root: URL, keeping kept: Set<String>, errors: inout [String]) -> Int {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: []
        ) else { return 0 }
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
        errors: inout [String]
    ) -> (archive: Bool, backups: Bool, keychainCleared: Bool) {
        let archive = resetAppGroupDirectory(
            named: AppConfig.archiveDirectoryName, label: String(localized: "Local sessions", bundle: LanguageManager.appBundle),
            reportMissingContainer: true, errors: &errors
        )
        let backups = resetAppGroupDirectory(
            named: AppConfig.backupDirectoryName, label: String(localized: "Raw backups", bundle: LanguageManager.appBundle),
            reportMissingContainer: false, errors: &errors
        )
        let keychainCleared = purgeLocalStores(cloudSync: cloudSync, settingsManager: settingsManager)
        cancelMorningNotifications()
        purgeHealthCaches()
        return (archive, backups, keychainCleared)
    }

    /// The purge steps that can individually fail and be reported as such.
    private struct FallibleSteps {
        let debugLogCleared: Bool
        let crashLogsCleared: Bool
    }

    private static func purgeFallibleStores(errors: inout [String]) -> FallibleSteps {
        let debugLogCleared = purgeDebugLog(errors: &errors)
        let crashLogsCleared = purgeCrashLogs(errors: &errors)
        // The archive and raw backups are gone, so any pending re-encryption
        // entries point at files that no longer exist.
        PendingEncryptionLedger.clearAll()
        return FallibleSteps(debugLogCleared: debugLogCleared, crashLogsCleared: crashLogsCleared)
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
    /// shows the switch off, and turning it on there is their choice.
    private static func purgeLocalStores(cloudSync: CloudKitSyncManager, settingsManager: SettingsManager) -> Bool {
        AppDependencies.current.storage.workoutTrackBackup.purgeAll()
        cloudSync.resetLocalSyncState()
        let keychainCleared = AppDependencies.current.providers.apiKeyStore.removeAllKeys()
        // The view model too, not only its store: the turns on screen stayed in
        // memory, and the next message saved the whole old chat back to disk.
        AppDependencies.current.assistant.assistantViewModel.clearConversation()
        AppDependencies.current.assistant.conversationStore.clear()
        AppDependencies.current.assistant.userFactsStore.clear()
        // Not `hasAcceptedDisclaimer = false` alone: that resets one flag
        // and leaves the whole biometric profile (age, body weight, resting
        // HR, max HR, LTHR, FTP, sleep schedule) in place through an erasure
        // request.
        settingsManager.resetToDefaults()
        settingsManager.settings.iCloudSyncEnabled = false
        UserDefaults.standard.removeObject(forKey: AssistantViewModel.disclaimerKey)
        UnitsPreferenceStore.current = .auto
        AppDependencies.current.location.breadcrumbStore.clear()
        AppDependencies.current.location.breadcrumbStore.eraseArchive()
        forgetInMemoryStores()
        return keychainCleared
    }

    /// Resetting the settings turns the daily report off, but the repeating request
    /// iOS holds stays scheduled until it is removed, and a delivered
    /// morning push can still show a score on the lock screen.
    private static func cancelMorningNotifications() {
        AppDependencies.current.services.morningNotificationScheduler.cancelAll()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    /// Their files went with the sweep; without this the routes, contacts,
    /// to-dos, the Get Me Back trail, the prefetched facts (last HRV, sleep,
    /// workout, location) and the cached location stayed in memory, readable
    /// by the assistant and written back to disk by the next add, rename or
    /// fix. The engaged turn-by-turn route (destination name and coordinate)
    /// is memory-only and is dropped too, so the voice coach stops using it.
    private static func forgetInMemoryStores() {
        let location = AppDependencies.current.location
        location.activeRouteSession.disengage()
        location.savedRouteStore.forgetAfterPurge()
        location.breadcrumbRecorder.forgetAfterPurge()
        location.ambientLocationService.forgetAfterPurge()
        AppDependencies.current.app.emailContactStore.forgetAfterPurge()
        AppDependencies.current.assistant.assistantArtifactStore.forgetAfterPurge()
        forgetAssistantAgreements()
    }

    /// The defaults behind these are swept, but both are also held in memory
    /// for the life of the process, so until the app restarted a re-added key
    /// sent data with no consent sheet and voice chat started with no
    /// disclaimer.
    private static func forgetAssistantAgreements() {
        for provider in ProviderConsentTracker.providersRequiringConsent {
            AppDependencies.current.providers.providerConsentTracker.revoke(provider)
        }
        AppDependencies.current.assistant.assistantViewModel.hasAcceptedDisclaimer = false
    }

    /// `AppDependencies.current.app.debugLogger.clear()` empties the logger's
    /// memory and queues removal of its file. The container sweep already
    /// removed the file that existed before the purge, but the logger keeps
    /// writing while the purge runs, and neither the sweep's count nor the
    /// logger's own removal says whether that re-created log is gone. This
    /// synchronous removal of whatever is left at the logger's path
    /// (`AppConfig.sharedContainerURL()`) is what the "Debug log" line
    /// reports.
    private static func purgeDebugLog(errors: inout [String]) -> Bool {
        AppDependencies.current.app.debugLogger.clear()
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
    private static func purgeCrashLogs(errors: inout [String]) -> Bool {
        do {
            try AppDependencies.current.app.crashLogManager.clearAll()
            return true
        } catch {
            errors.append(String(localized: "Crash logs: \(error.localizedDescription)", bundle: LanguageManager.appBundle))
            return false
        }
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
    /// device.
    private static func purgeHealthCaches() {
        HeatAcclimationCache.clearPersistedData()
        AppDependencies.current.providers.llmCacheTelemetry.reset()
        AppDependencies.current.providers.llmRequestAudit.clear()
        SleepDataCache.clear()
        RespiratoryBaselineCache.clear()
        WristTemperatureBaselineCache.clear()
        AppDependencies.current.services.recoveryScoreFeedbackStore.clearAll()
    }
}
