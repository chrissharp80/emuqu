@testable import Emuqu
import os
import XCTest

/// Tests for DataPurgeService — the "Delete All My Data" fan-out.
///
/// The purge is handed its stores (`DataPurgeService.Stores`). The assistant's
/// conversation and facts, the trail history and the workout recorder are
/// this test's own; the rest are the app's live services, reached through a
/// fresh container rather than `AppDependencies.current`. The test verifies:
///   1. The function runs end-to-end without throwing.
///   2. The report exposes a Bool for every step (no fields swallowed).
///   3. The summary string mentions every step the function attempted.
///   4. The unconditional steps (CloudKit local state, keychain, conversation,
///      facts, disclaimer) are flagged as completed.
///
/// Every call injects a `deleteRemote` stub — the production default routes
/// to `CloudKitSyncManager.deleteAllRemoteData()`, which would fire a REAL
/// zone deletion against whatever iCloud account the simulator is signed
/// into. Tests must never do that.
@MainActor
final class DataPurgeServiceTests: XCTestCase {
    /// Capture-and-restore, not fire-and-forget.
    ///
    /// `NSTimeZone.default` is **process-global**. A class that sets it to UTC
    /// in `class setUp()` and does not put it back leaks UTC into every test
    /// class that runs after it in the same process. `LiveReadinessTests`
    /// computes "today" from `Date()` against the current calendar, so between
    /// 19:00 and midnight US-Central (when the UTC date is already tomorrow)
    /// its tests would fail.
    nonisolated private static let savedDefaultTimeZone = OSAllocatedUnfairLock<TimeZone?>(initialState: nil)
    override class func setUp() {
        super.setUp()
        savedDefaultTimeZone.withLock { $0 = NSTimeZone.default }
        NSTimeZone.default = TestTimeZone.utc
    }

    override class func tearDown() {
        if let saved = savedDefaultTimeZone.withLock({ $0 }) { NSTimeZone.default = saved }
        savedDefaultTimeZone.withLock { $0 = nil }
        super.tearDown()
    }

    /// The purge resets `SettingsManager.shared` to fresh-install defaults.
    /// The settings and the disclaimer flag this test found are put back
    /// afterwards, so the suites that run after it in the same process see
    /// the state they started with rather than a wiped one.
    private var savedSettings: UserSettings?
    private var savedDisclaimer = false

    /// The purge sweeps every file and preference key it is responsible for.
    /// Pointed at the test host's own containers and suites, it wiped them
    /// for every test that ran after it in the process, so each test sweeps
    /// a temporary directory per container and two throwaway suites instead.
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DataPurgeServiceTests-\(UUID().uuidString)", isDirectory: true)
    private let appSuiteName = "DataPurgeServiceTests.app.\(UUID().uuidString)"
    private let groupSuiteName = "DataPurgeServiceTests.group.\(UUID().uuidString)"
    private lazy var appSuite = Self.suite(named: appSuiteName)
    private lazy var groupSuite = Self.suite(named: groupSuiteName)
    private lazy var containers = ["group", "applicationSupport", "documents", "caches", "tmp"]
        .map { root.appendingPathComponent($0, isDirectory: true) }
    private lazy var scope = DataPurgeService.PurgeScope(
        appGroupContainer: containers[0],
        sandboxRoots: Array(containers.dropFirst()),
        defaultsDomains: { [appSuiteName, appSuite, groupSuiteName, groupSuite] _ in
            [(name: appSuiteName, store: appSuite), (name: groupSuiteName, store: groupSuite)]
        }
    )
    /// The baseline the purge resets: on a file in the temporary App Group
    /// container, never the app's own `HRVBaseline.json`.
    private lazy var baselineTracker = BaselineTracker(
        baselineFile: containers[0].appendingPathComponent("HRVBaseline.json"), onBaselineUpdated: nil
    )
    /// The raw backups the purge empties: in the temporary App Group
    /// container, where the purge sweeps them, never the app's own store.
    private lazy var rawBackup = RawRRBackup(
        directory: containers[0].appendingPathComponent(AppConfig.backupDirectoryName, isDirectory: true)
    )
    private lazy var archive = SessionArchive(
        directory: containers[0].appendingPathComponent(AppConfig.archiveDirectoryName, isDirectory: true),
        sleepScheduleProvider: { SleepSchedule(bedtimeHour: 22, bedtimeMinute: 0, sleepHours: 8.0) },
        sessionMergeModeProvider: { .defaultGap },
        mergeGapProvider: { 4.5 * 3600 }
    )

    /// The conversation, facts and trails the purge clears, on files in this
    /// test's folder outside the swept containers.
    private lazy var conversationStore = ConversationStore(
        fileURL: root.appendingPathComponent("Assistant/conversation.json"), saveDebounceMs: 0
    )
    private lazy var userFactsStore = UserFactsStore(fileURL: root.appendingPathComponent("Assistant/user_facts.json"))
    private lazy var breadcrumbStore = BreadcrumbStore(fileURL: root.appendingPathComponent("Breadcrumbs/active.json"))
    /// Every store the purge takes beyond the named ones: the substitutes
    /// above; the AI provider keys under a Keychain service of this test's
    /// own; the workout crash-recovery backups, saved routes and email
    /// contacts in this test's folder; otherwise the live services.
    private lazy var stores: DataPurgeService.Stores = {
        let dependencies = AppDependencies()
        dependencies.overrides.conversationStore = conversationStore
        dependencies.overrides.userFactsStore = userFactsStore
        dependencies.overrides.breadcrumbStore = breadcrumbStore
        dependencies.overrides.recorderBox = RecorderBox(services: WorkoutServices(.current))
        dependencies.overrides.apiKeyStore = apiKeyStore
        dependencies.overrides.workoutTrackBackup = WorkoutTrackBackup(
            directory: root.appendingPathComponent("WorkoutBackup", isDirectory: true), notificationCenter: NotificationCenter()
        )
        dependencies.overrides.savedRouteStore = SavedRouteStore(storeURL: root.appendingPathComponent("saved_routes.json"))
        dependencies.overrides.emailContactStore = EmailContactStore(storeURL: root.appendingPathComponent("email_contacts.json"))
        return dependencies.purgeStores
    }()
    /// The provider keys the purge removes: never the host's Keychain items.
    private lazy var apiKeyStore = APIKeyStore(keychainService: "DataPurgeServiceTests.\(UUID().uuidString)")
    /// The sync bookkeeping the purge resets: this test's own, over its
    /// archive, never `CloudKitSyncManager.shared`'s uploaded and pending
    /// lists. What the reset clears in standard defaults is set aside.
    private lazy var cloudSync = CloudKitSyncManager.isolated(
        archive: archive, directory: root.appendingPathComponent("Sync", isDirectory: true)
    )
    /// The host's sync bookkeeping and assistant-disclaimer acceptance in
    /// standard defaults, and its units choice, put back in `tearDown`.
    private var hostDefaults: HostDefaults?
    private var savedUnits: UnitsPreference = .auto
    /// The purge empties the process-wide re-encryption ledger, the only
    /// record of which of the host's files were written in plaintext; its
    /// entries are recorded again in `tearDown`.
    private var hostLedger: [PendingEncryptionLedger.Store: Set<UUID>] = [:]

    private static func suite(named name: String) -> UserDefaults {
        guard let suite = UserDefaults(suiteName: name) else { preconditionFailure("could not open the test suite \(name)") }
        return suite
    }

    override func setUp() async throws {
        try await super.setUp()
        savedSettings = SettingsManager.shared.settings
        savedDisclaimer = SettingsManager.shared.hasAcceptedDisclaimer
        savedUnits = UnitsPreferenceStore.current
        hostDefaults = HostDefaults.setAside(HostDefaults.cloudSyncBookkeeping + [AssistantViewModel.disclaimerKey])
        hostLedger = Dictionary(uniqueKeysWithValues: PendingEncryptionLedger.Store.allCases.map { ($0, PendingEncryptionLedger.pending(in: $0)) })
        pinEnglishLanguage()
        for container in containers + [root.appendingPathComponent("Sync", isDirectory: true)] {
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        }
    }

    override func tearDown() async throws {
        if let savedSettings { SettingsManager.shared.settings = savedSettings }
        SettingsManager.shared.hasAcceptedDisclaimer = savedDisclaimer
        UnitsPreferenceStore.current = savedUnits
        hostDefaults?.restore()
        for (store, ids) in hostLedger {
            ids.forEach { PendingEncryptionLedger.record($0, in: store) }
        }
        appSuite.removePersistentDomain(forName: appSuiteName)
        groupSuite.removePersistentDomain(forName: groupSuiteName)
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            // swallow-ok: the purge may already have emptied it; what is left is temporary.
        }
        try await super.tearDown()
    }

    /// The purge over this test's temporary containers, suites, baseline and
    /// stores, its Keychain service and its sync manager. Settings are still
    /// the app's shared instance and are restored above, as are the units
    /// choice, the standard-defaults keys the purge clears and the host's
    /// re-encryption ledger. The in-memory caches the purge forgets (the
    /// display and training-load caches, the location services, the provider
    /// consents and telemetry), the morning notifications and the logs are
    /// still the app's.
    ///
    /// Nothing is recording: the answer is passed, so the host app's own
    /// collector and workout recorder are never consulted.
    private func purge(
        remoteDeleted: Bool = true, scope customScope: DataPurgeService.PurgeScope? = nil
    ) async throws -> DataPurgeService.Report {
        try await DataPurgeService.purgeAllUserData(
            archive: archive, rawBackup: rawBackup,
            cloudSync: cloudSync, settingsManager: SettingsManager.shared, stores: stores,
            baselineTracker: baselineTracker, recordingInProgress: { false },
            deleteRemote: { remoteDeleted }, scope: customScope ?? scope
        )
    }

    func testPurgeReturnsReportWithEveryStepAccountedFor() async throws {
        let report = try await purge()

        XCTAssertTrue(report.remoteDeleted, "Stubbed remote deletion outcome must flow into the report")

        // Every step exposes its outcome via a Bool — not a missing field.
        // The unconditional steps must always be true:
        XCTAssertTrue(report.cloudSyncStateReset, "CloudKit local state reset is unconditional")
        XCTAssertTrue(report.keychainCleared, "Keychain wipe is unconditional")
        XCTAssertTrue(report.conversationsCleared, "Conversation clear is unconditional")
        XCTAssertTrue(report.userFactsCleared, "User-facts clear is unconditional")
        XCTAssertTrue(report.disclaimerReset, "Disclaimer reset is unconditional")
        XCTAssertTrue(report.profileReset, "The settings file must read back as the fresh-install profile: \(report.errors)")
        XCTAssertTrue(report.assistantDisclaimerReset, "The assistant disclaimer must be off in UserDefaults and in the view model")
        XCTAssertFalse(UserDefaults.standard.bool(forKey: AssistantViewModel.disclaimerKey),
                       "The stored assistant disclaimer acceptance survived the purge")
        // The App Group preferences suite is swept without a false
        // "domain unavailable" failure: iOS gives a group suite no persistent
        // domain under its own name, and that is not an error.
        XCTAssertFalse(report.errors.contains(where: { $0.contains("Preferences sweep") }),
                       "the preferences sweep must not report a failure: \(report.errors)")
    }

    func testReportSummaryMentionsEveryStep() async throws {
        let report = try await purge()
        let summary = report.summary

        XCTAssertTrue(summary.contains("iCloud records"), "summary must mention the remote deletion step: \(summary)")
        XCTAssertTrue(summary.contains("Local sessions"), "summary must mention archive: \(summary)")
        XCTAssertTrue(summary.contains("Raw backups"), "summary must mention backups: \(summary)")
        XCTAssertTrue(summary.contains("iCloud sync state"), "summary must mention CloudKit: \(summary)")
        XCTAssertTrue(summary.contains("AI provider keys"), "summary must mention keychain: \(summary)")
        XCTAssertTrue(summary.contains("AI conversation history"), "summary must mention conversation: \(summary)")
        XCTAssertTrue(summary.contains("AI memory facts"), "summary must mention user facts: \(summary)")
        XCTAssertTrue(summary.contains("Disclaimer acceptance"), "summary must mention disclaimer: \(summary)")
        XCTAssertTrue(summary.contains("Profile: reset"), "summary must report the profile reset read back from disk: \(summary)")
        XCTAssertFalse(summary.contains("widget"), "the app has no widget, so the summary must not list one: \(summary)")
        XCTAssertTrue(summary.contains("open it again"), "summary should say to reopen the app: \(summary)")
        XCTAssertFalse(summary.contains("pre-existing iCloud records"),
                       "the old 'remote is NOT removed' disclosure must be gone now that the purge deletes remotely: \(summary)")
    }

    // MARK: - Remote Deletion Outcome (GDPR / App Store)

    func testRemoteDeletionSuccessIsSurfacedInSummary() async throws {
        let report = try await purge()
        XCTAssertTrue(report.remoteDeleted)
        XCTAssertTrue(report.summary.contains("iCloud records: deleted"),
                      "success summary must state the remote copies were deleted: \(report.summary)")
        XCTAssertFalse(report.errors.contains(where: { $0.contains("iCloud") }),
                       "no iCloud error should be reported on remote success: \(report.errors)")
    }

    func testRemoteDeletionFailureIsSurfacedAndLocalWipeProceeds() async throws {
        let report = try await purge(remoteDeleted: false)
        // The remote failure must be honest and actionable…
        XCTAssertFalse(report.remoteDeleted)
        XCTAssertTrue(report.summary.contains("iCloud records: NOT deleted"),
                      "failure summary must say remote copies were NOT deleted: \(report.summary)")
        XCTAssertTrue(report.errors.contains(where: { $0.contains("run Delete All My Data again") }),
                      "failure must tell the user to retry with connectivity: \(report.errors)")
        // …while the local wipe still completes (user intent is local
        // deletion regardless of network).
        XCTAssertTrue(report.cloudSyncStateReset, "local sync state reset must run even when remote fails")
        XCTAssertTrue(report.keychainCleared, "local steps must proceed when remote fails")
        XCTAssertTrue(report.conversationsCleared, "local steps must proceed when remote fails")
    }

    /// The marker must be on disk before the purge runs: `save` is debounced
    /// and `load` reads the file directly, so a purge that ran first would
    /// find no persisted history, `clear()` would cancel the pending write,
    /// and the empty load at the end would pass whatever the purge did.
    func testPurgeClearsTheConversationStore() async throws {
        let marker = "purge-marker-\(UUID().uuidString)"
        let store = conversationStore
        store.save(store.load() + [ChatTurn(role: .user, text: marker)])
        try await waitUntil { store.load().contains { $0.text == marker } }
        XCTAssertTrue(store.load().contains { $0.text == marker },
                      "Sanity: the marker turn reached disk before the purge")

        _ = try await purge()

        // `clear()` runs on the store's queue; poll rather than assume it ran.
        try await waitUntil { store.load().isEmpty }
        XCTAssertTrue(store.load().isEmpty,
                      "DataPurgeService should leave conversation history empty")
    }

    /// Polls `condition` every 50 ms until it holds or 10 s pass; the caller
    /// asserts the condition afterwards, so a timeout fails there.
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Read from the file, not only from memory: `clear()` empties the list
    /// at once, and only the queued write shows whether the facts left disk.
    func testPurgeClearsTheUserFacts() async throws {
        userFactsStore.add("purge-marker-\(UUID().uuidString)", origin: .user)
        XCTAssertFalse(userFactsStore.facts.isEmpty, "Sanity: facts seeded")

        let report = try await purge()

        XCTAssertTrue(userFactsStore.facts.isEmpty,
                      "DataPurgeService should leave UserFactsStore empty")
        XCTAssertEqual(userFactsStore.persistedFacts()?.count, 0,
                       "The facts file must hold no facts after the purge")
        XCTAssertTrue(report.userFactsCleared)
    }

    func testPurgeResetsDisclaimerFlagOnSettingsManager() async throws {
        SettingsManager.shared.hasAcceptedDisclaimer = true

        _ = try await purge()

        XCTAssertFalse(SettingsManager.shared.hasAcceptedDisclaimer,
                       "Disclaimer flag should be reset to false after purge")
    }

    // MARK: - Container sweep

    /// The test that fails for a store nobody has written yet.
    ///
    /// The seven tests above assert on `DataPurgeService.Report` fields, which
    /// is exactly why the eight missed stores were invisible: a store that is
    /// not in the `Report` cannot be checked by a test that reads the `Report`.
    /// The structure of the test mirrored the structure of the defect.
    ///
    /// This writes a sentinel into every container a full wipe is responsible
    /// for and asserts it is gone afterwards. It knows nothing about which
    /// stores exist, so it keeps working when a new one is added.
    func testSweepRemovesAnUnknownFileFromEveryContainer() async throws {
        let fileManager = FileManager.default
        let group = try XCTUnwrap(scope.appGroupContainer)
        let sentinels = ([group] + scope.sandboxRoots).map { $0.appendingPathComponent("zz_audit_sentinel.json") }

        for url in sentinels {
            XCTAssertNoThrow(try Data("sentinel".utf8).write(to: url), "Could not seed \(url.lastPathComponent)")
        }

        _ = try await purge()

        for url in sentinels {
            XCTAssertFalse(
                fileManager.fileExists(atPath: url.path),
                "\(url.lastPathComponent) survived Delete All My Data. Every file in every container must go unless DataPurgeService.keptEntries(in:liveSettingsFile:) keeps it."
            )
        }
    }

    /// The tests sweep temporary containers; this pins that the app's own
    /// scope names every real one: the App Group container, Application
    /// Support, Documents, Caches and tmp, and both preference suites.
    func testTheDeviceScopeCoversEveryContainerAndSuite() {
        let fileManager = FileManager.default
        let device = DataPurgeService.PurgeScope.device
        XCTAssertEqual(
            device.appGroupContainer,
            fileManager.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupIdentifier)
        )
        let expected = [FileManager.SearchPathDirectory.applicationSupportDirectory, .documentDirectory, .cachesDirectory]
            .compactMap { fileManager.urls(for: $0, in: .userDomainMask).first } + [fileManager.temporaryDirectory]
        XCTAssertEqual(device.sandboxRoots, expected)
        var errors: [String] = []
        let names = device.defaultsDomains(&errors).map(\.name)
        XCTAssertTrue(names.contains(AppConfig.appGroupIdentifier), "the App Group suite is not swept: \(names)")
        if let bundleID = Bundle.main.bundleIdentifier {
            XCTAssertTrue(names.contains(bundleID), "the app's own suite is not swept: \(names)")
        }
    }

    // MARK: - Preferences sweep

    /// The same test, for the other storage class.
    ///
    /// The container sweep covers files. Preferences were still purged by
    /// enumeration — nine named keys out of 105 the app writes — so a store
    /// that keeps its state in `UserDefaults` survived "Delete All My Data"
    /// entirely. This seeds an unknown key in each suite and asserts it is gone.
    func testSweepRemovesAnUnknownDefaultsKeyFromEverySuite() async throws {
        let key = "zz_audit_sentinel_defaults"
        appSuite.set("sentinel", forKey: key)
        groupSuite.set("sentinel", forKey: key)

        _ = try await purge()

        XCTAssertNil(appSuite.object(forKey: key), "A UserDefaults key survived Delete All My Data in the app's own suite.")
        XCTAssertNil(groupSuite.object(forKey: key), "A UserDefaults key survived Delete All My Data in the App Group suite.")
    }

    /// The other half of the contract, and the reason the sweep is not simply
    /// `removePersistentDomain`.
    ///
    /// `StoreKitManager.isPurchased` reads `storekit.lastKnownPurchased`
    /// SYNCHRONOUSLY on the launch path, before StoreKit has re-verified
    /// anything. A purge that cleared it would show a paying customer the
    /// paywall immediately after they erased their data, and offline it would
    /// never resolve. Same argument for the entitlement anchor one layer down,
    /// and the migration flags are bookkeeping the purge has never touched.
    func testPurgeLeavesEntitlementAndMigrationStateIntact() async throws {
        let mustSurvive = [
            "storekit.lastKnownPurchased",
            "storekit.lastKnownTestFlight",
            "entitlement.anchor.v1",
            "entitlement.anchor.account",
            "FlowRecovery.migration.metrics.v1.done",
            "didRunTrimpRepairMigration_v1"
        ]
        for key in mustSurvive {
            appSuite.set("sentinel", forKey: key)
        }

        _ = try await purge()

        for key in mustSurvive {
            XCTAssertNotNil(
                appSuite.object(forKey: key),
                """
                '\(key)' was cleared by the purge. Erasing someone's health data is \
                not a refund, and re-running migrations against an empty archive buys \
                nothing. See DataPurgeService.defaultsKeepList.
                """
            )
        }
    }

    /// The in-app language picker writes `AppleLanguages` into the app's own
    /// persistent domain (`AppearanceAndLanguagePages`). A preferences sweep that
    /// did not exclude the system-owned prefixes would reset the user's chosen
    /// UI language as a side effect of deleting their data.
    func testPurgeLeavesTheChosenAppLanguageAlone() async throws {
        let key = "AppleLanguages"
        appSuite.set(["fr"], forKey: key)

        _ = try await purge()

        XCTAssertEqual(
            appSuite.array(forKey: key) as? [String], ["fr"],
            "The purge changed the app's display language."
        )
    }

    /// A directory, not just a file — `saved_routes.json` was a file but
    /// `Assistant/` and `HRVOffline/` are directories, and a sweep that only
    /// unlinked files would have left both.
    func testSweepRemovesAnUnknownDirectory() async throws {
        let fileManager = FileManager.default
        let group = try XCTUnwrap(scope.appGroupContainer)
        let dir = group.appendingPathComponent("zz_audit_sentinel_dir", isDirectory: true)
        XCTAssertNoThrow(try fileManager.createDirectory(at: dir, withIntermediateDirectories: true))
        XCTAssertNoThrow(try Data("x".utf8).write(to: dir.appendingPathComponent("inner.json")))

        _ = try await purge()

        XCTAssertFalse(fileManager.fileExists(atPath: dir.path), "An unknown directory survived the purge.")
    }

    /// The biometric profile must not survive an erasure request, on disk:
    /// the reset is an asynchronous write, so the in-memory value alone said
    /// nothing about the file. The purge flushes it and reads the file back
    /// (`Report.profileReset`); this reads the same file independently.
    func testPurgeResetsTheBiometricProfile() async throws {
        let manager = SettingsManager.shared
        manager.settings.bodyWeightKg = 81.5
        manager.settings.maxHR = 187
        manager.hasAcceptedDisclaimer = true

        let report = try await purge()

        XCTAssertTrue(report.profileReset, "The purge did not confirm the profile on disk: \(report.errors)")
        let onDisk = try JSONFileSeal.app.openJSON(
            UserSettings.self, from: Data(contentsOf: manager.settingsURL), with: SettingsManager.settingsDecoder()
        )
        XCTAssertNil(onDisk.bodyWeightKg, "Body weight survived Delete All My Data in the settings file")
        XCTAssertNil(onDisk.maxHR, "Max HR survived Delete All My Data in the settings file")
        XCTAssertEqual(manager.settings.bodyWeightKg, UserSettings().bodyWeightKg)
        XCTAssertFalse(manager.hasAcceptedDisclaimer)
    }

    /// An older build copied `Documents/user_settings.json` into the App Group
    /// and left the original. Only the file the settings manager uses is
    /// kept; a `user_settings.json` anywhere else is the same profile and goes.
    func testPurgeRemovesASettingsFileThatIsNotTheLiveOne() async throws {
        let fileManager = FileManager.default
        let group = try XCTUnwrap(scope.appGroupContainer)
        let copies = ([group] + scope.sandboxRoots).map { $0.appendingPathComponent("user_settings.json") }
        for url in copies {
            try Data(#"{"bodyWeightKg":81.5}"#.utf8).write(to: url)
        }

        let report = try await purge()

        for url in copies {
            XCTAssertFalse(fileManager.fileExists(atPath: url.path),
                           "A settings file that is not the live one survived the purge: \(url.path)")
        }
        XCTAssertTrue(report.profileReset, "The live settings file must still be reset: \(report.errors)")
    }

    /// The live settings file is kept, in its own root only.
    func testOnlyTheLiveSettingsFileIsKept() throws {
        let group = try XCTUnwrap(scope.appGroupContainer)
        let documents = scope.sandboxRoots[1]
        let live = documents.appendingPathComponent("user_settings.json")

        let roots = DataPurgeService.purgeRoots(scope, liveSettingsFile: live)

        let kept = Dictionary(uniqueKeysWithValues: roots.map { ($0.url, $0.kept) })
        XCTAssertEqual(kept[documents], ["user_settings.json"])
        XCTAssertEqual(kept[group], ["Library"])
        for other in scope.sandboxRoots where other != documents {
            XCTAssertEqual(kept[other], [], "\(other.lastPathComponent) keeps a settings file it does not hold")
        }
    }

    // MARK: - Roots that cannot be swept

    /// A root that exists but cannot be listed still holds its files, so the
    /// report says so instead of "0 removed".
    func testARootThatCannotBeListedIsReported() async throws {
        let notADirectory = root.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: notADirectory)
        let unlistable = DataPurgeService.PurgeScope(
            appGroupContainer: scope.appGroupContainer,
            sandboxRoots: scope.sandboxRoots + [notADirectory],
            defaultsDomains: scope.defaultsDomains
        )

        let report = try await purge(scope: unlistable)

        XCTAssertTrue(report.errors.contains { $0.contains("Could not list not-a-directory") },
                      "An unlistable root must be reported: \(report.errors)")
    }

    /// A root that is not there has nothing in it; that is not a failure.
    func testAMissingRootIsNotReported() async throws {
        let missing = DataPurgeService.PurgeScope(
            appGroupContainer: scope.appGroupContainer,
            sandboxRoots: scope.sandboxRoots + [root.appendingPathComponent("missing", isDirectory: true)],
            defaultsDomains: scope.defaultsDomains
        )

        let report = try await purge(scope: missing)

        XCTAssertFalse(report.errors.contains { $0.contains("Could not list") }, "\(report.errors)")
    }

    // MARK: - Personal baseline

    /// The tracker keeps up to 90 nights in memory and wrote them back on the
    /// next night's update, so the purge resets the tracker itself, and the
    /// empty baseline is what the file then holds.
    func testPurgeResetsThePersonalBaseline() async throws {
        let file = containers[0].appendingPathComponent("HRVBaseline.json")
        let nights = (1 ... 3).map { day in
            #"{"date":"2026-01-0\#(day)T23:00:00Z","rmssd":40,"sdnn":55,"meanHR":58}"#
        }
        try Data(#"{"historicalData":[\#(nights.joined(separator: ","))]}"#.utf8).write(to: file)
        XCTAssertEqual(baselineTracker.daysCollected, 3, "Sanity: the tracker loaded the seeded nights")

        _ = try await purge()

        XCTAssertEqual(baselineTracker.daysCollected, 0, "The baseline survived Delete All My Data in memory")
        XCTAssertEqual(BaselineTracker(baselineFile: file, onBaselineUpdated: nil).daysCollected, 0,
                       "The baseline file holds nights after Delete All My Data")
    }

    /// A user who just deleted their iCloud copy must not have sync quietly
    /// switched back on by the reset to fresh-install defaults.
    func testPurgeLeavesICloudSyncOff() async throws {
        let manager = SettingsManager.shared
        manager.settings.iCloudSyncEnabled = true

        _ = try await purge()

        XCTAssertFalse(manager.settings.iCloudSyncEnabled, "Delete All My Data turned iCloud sync back on")
    }

    /// iCloud sync is off, and the purge gate closed, before the remote
    /// deletion starts: a sync queued behind that deletion must find nothing
    /// to upload into the emptied iCloud.
    func testICloudSyncIsOffAndWritesAreRefusedWhileTheRemoteDeletionRuns() async throws {
        let manager = SettingsManager.shared
        manager.settings.iCloudSyncEnabled = true
        var night = HRVSession(
            id: UUID(), startDate: Date(timeIntervalSince1970: 4_102_444_800), endDate: nil,
            state: .complete, sessionType: .overnight, rrSeries: nil, analysisResult: nil, artifactFlags: nil
        )
        night.recoveryScore = 7
        var syncWasOn = true
        var writeRefused = false
        _ = try await DataPurgeService.purgeAllUserData(
            archive: archive, rawBackup: rawBackup,
            cloudSync: cloudSync, settingsManager: manager, stores: stores,
            baselineTracker: baselineTracker, recordingInProgress: { false },
            deleteRemote: { [archive] in
                syncWasOn = manager.settings.iCloudSyncEnabled
                do {
                    try archive.archive(night)
                } catch is PurgeGate.Refused {
                    writeRefused = true
                } catch {
                    XCTFail("expected the purge gate to refuse the write, got \(error)")
                }
                return true
            },
            scope: scope
        )

        XCTAssertFalse(syncWasOn, "iCloud sync was still on while the remote deletion ran")
        XCTAssertTrue(writeRefused, "An archive write went through while the purge ran")
        XCTAssertFalse(archive.store.exists(night.id))
        XCTAssertFalse(PurgeGate.isPurging, "The purge left the gate closed")
        XCTAssertNoThrow(try archive.archive(night), "Archive writes stayed refused after the purge")
    }

    /// A recording started while the remote deletion ran would write its beats
    /// back into the emptied backups, so the purge stops before the local
    /// wipe and says so; the device keeps its data and the gate opens again.
    func testARecordingStartedDuringTheRemoteDeletionStopsThePurgeBeforeTheLocalWipe() async throws {
        let sentinel = try XCTUnwrap(scope.appGroupContainer).appendingPathComponent("zz_late_recording_sentinel.json")
        try Data("sentinel".utf8).write(to: sentinel)
        var asked = 0

        do {
            _ = try await DataPurgeService.purgeAllUserData(
                archive: archive, rawBackup: rawBackup,
                cloudSync: cloudSync, settingsManager: SettingsManager.shared, stores: stores,
                baselineTracker: baselineTracker,
                recordingInProgress: {
                    asked += 1
                    return asked > 1
                },
                deleteRemote: { true }, scope: scope
            )
            XCTFail("The local wipe ran although a recording started during the remote deletion")
        } catch {
            XCTAssertEqual(error, .recordingStartedDuringDelete)
        }

        XCTAssertEqual(asked, 2, "The recording check was not made again after the remote deletion")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path), "The local wipe ran")
        XCTAssertFalse(SettingsManager.shared.settings.iCloudSyncEnabled, "iCloud sync was turned back on")
        XCTAssertFalse(PurgeGate.isPurging, "The stopped purge left the gate closed")
    }

    /// A recording still running holds its beats in memory: it would write
    /// them back into the emptied backups and archive its session when it
    /// stopped. So the purge refuses while one runs, and deletes nothing,
    /// iCloud included.
    func testPurgeIsRefusedWhileARecordingIsInProgress() async throws {
        let sentinel = try XCTUnwrap(scope.appGroupContainer).appendingPathComponent("zz_recording_sentinel.json")
        try Data("sentinel".utf8).write(to: sentinel)
        appSuite.set(true, forKey: "zz_recording_sentinel")
        SettingsManager.shared.hasAcceptedDisclaimer = true

        do {
            _ = try await DataPurgeService.purgeAllUserData(
                archive: archive, rawBackup: rawBackup,
                cloudSync: cloudSync, settingsManager: SettingsManager.shared, stores: stores,
                baselineTracker: baselineTracker, recordingInProgress: { true },
                deleteRemote: {
                    XCTFail("The iCloud deletion ran although the purge was refused")
                    return true
                },
                scope: scope
            )
            XCTFail("Delete All My Data ran while a recording was in progress")
        } catch {
            XCTAssertEqual(error, .recordingInProgress)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path), "A refused purge removed a file")
        XCTAssertTrue(appSuite.bool(forKey: "zz_recording_sentinel"), "A refused purge removed a preference")
        XCTAssertTrue(SettingsManager.shared.hasAcceptedDisclaimer, "A refused purge reset the disclaimer")
    }

    /// With nothing recording, the collector's own state lets the purge run.
    func testPurgeProceedsWhenNothingIsRecording() async throws {
        let collector = SnapshotFixtures.collector()
        XCTAssertFalse(DataPurgeService.isRecordingInProgress(collector: collector, workout: nil))
        let sentinel = try XCTUnwrap(scope.appGroupContainer).appendingPathComponent("zz_idle_sentinel.json")
        try Data("sentinel".utf8).write(to: sentinel)

        let report = try await DataPurgeService.purgeAllUserData(
            archive: archive, rawBackup: rawBackup,
            cloudSync: cloudSync, settingsManager: SettingsManager.shared, stores: stores,
            baselineTracker: baselineTracker,
            recordingInProgress: { DataPurgeService.isRecordingInProgress(collector: collector, workout: nil) },
            deleteRemote: { true }, scope: scope
        )

        XCTAssertTrue(report.archiveDeleted, "The purge did not run with nothing recording: \(report.errors)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path), "The idle purge left a file behind")
    }

    /// Each kind of recording counts: a quick reading, an overnight stream,
    /// a paused night, a stopped night still being analysed, and a recording
    /// on the strap. So does a reading waiting to be accepted: accepting it
    /// after the purge would archive it. Only an idle collector lets it run.
    func testEveryCollectorRecordingStateCounts() {
        let reading = SnapshotFixtures.collector()
        reading.sessionState.isCollecting = true
        XCTAssertTrue(DataPurgeService.isRecordingInProgress(collector: reading, workout: nil), "quick reading")

        let night = SnapshotFixtures.collector()
        night.streamingLifecycle.isOvernightStreaming = true
        XCTAssertTrue(DataPurgeService.isRecordingInProgress(collector: night, workout: nil), "overnight stream")

        let paused = SnapshotFixtures.collector()
        paused.streamingLifecycle.isPaused = true
        XCTAssertTrue(DataPurgeService.isRecordingInProgress(collector: paused, workout: nil), "paused night")

        let analysing = SnapshotFixtures.collector()
        analysing.sessionState.recordingPhase = .analyzing
        XCTAssertTrue(DataPurgeService.isRecordingInProgress(collector: analysing, workout: nil), "night being analysed")

        let strap = SnapshotFixtures.collector()
        strap.deviceStatus.isRecordingOnDevice = true
        XCTAssertTrue(DataPurgeService.isRecordingInProgress(collector: strap, workout: nil), "strap recording")

        let awaiting = SnapshotFixtures.collector()
        awaiting.sessionState.recordingPhase = .awaitingAcceptance
        XCTAssertTrue(DataPurgeService.isRecordingInProgress(collector: awaiting, workout: nil), "night awaiting acceptance")

        let review = SnapshotFixtures.collector()
        review.sessionState.needsAcceptance = true
        XCTAssertTrue(DataPurgeService.isRecordingInProgress(collector: review, workout: nil), "reading awaiting acceptance")

        XCTAssertFalse(DataPurgeService.isRecordingInProgress(collector: SnapshotFixtures.collector(), workout: nil), "idle collector")
    }

    /// A workout counts while it records (paused included, which keeps the
    /// phase) and while it is being finalised, not once it has finished.
    func testAnActiveWorkoutCounts() {
        let recorder = WorkoutRecorder(core: SnapshotFixtures.collector().recordingCore, conversation: VoiceConversationController.shared, services: WorkoutServices(.current))
        XCTAssertFalse(DataPurgeService.isRecordingInProgress(collector: nil, workout: recorder), "idle workout")

        recorder.lifecycle.phase = .recording
        XCTAssertTrue(DataPurgeService.isRecordingInProgress(collector: nil, workout: recorder), "recording workout")

        recorder.lifecycle.phase = .finalizing
        XCTAssertTrue(DataPurgeService.isRecordingInProgress(collector: nil, workout: recorder), "finalising workout")

        recorder.lifecycle.phase = .finished
        XCTAssertFalse(DataPurgeService.isRecordingInProgress(collector: nil, workout: recorder), "finished workout")
    }
}
