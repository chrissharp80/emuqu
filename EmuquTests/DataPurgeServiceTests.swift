@testable import Emuqu
import os
import XCTest

/// Tests for DataPurgeService — the "Delete All My Data" fan-out.
///
/// Most stores it touches are singletons backed by the App Group container,
/// which isn't present in the test bundle. The test verifies:
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
    /// `NSTimeZone.default` is **process-global**. Ten test classes set it to
    /// UTC in `class setUp()` and none of them put it back, so every test class
    /// that happened to run afterwards in the same process silently inherited
    /// UTC. `LiveReadinessTests` computes "today" from `Date()` against the
    /// current calendar, so between 19:00 and midnight US-Central (when the UTC
    /// date is already tomorrow) four of its tests failed — a genuine
    /// time-of-day flake that was invisible only because the suite used to
    /// deadlock before reaching them.
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
    private lazy var archive = SessionArchive(
        directory: containers[0].appendingPathComponent(AppConfig.archiveDirectoryName, isDirectory: true),
        sleepScheduleProvider: { SleepSchedule(bedtimeHour: 22, bedtimeMinute: 0, sleepHours: 8.0) },
        sessionMergeModeProvider: { .defaultGap },
        mergeGapProvider: { 4.5 * 3600 }
    )

    private static func suite(named name: String) -> UserDefaults {
        guard let suite = UserDefaults(suiteName: name) else { preconditionFailure("could not open the test suite \(name)") }
        return suite
    }

    override func setUp() async throws {
        try await super.setUp()
        savedSettings = SettingsManager.shared.settings
        savedDisclaimer = SettingsManager.shared.hasAcceptedDisclaimer
        pinEnglishLanguage()
        for container in containers {
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        }
    }

    override func tearDown() async throws {
        if let savedSettings { SettingsManager.shared.settings = savedSettings }
        SettingsManager.shared.hasAcceptedDisclaimer = savedDisclaimer
        appSuite.removePersistentDomain(forName: appSuiteName)
        groupSuite.removePersistentDomain(forName: groupSuiteName)
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            // swallow-ok: the purge may already have emptied it; what is left is temporary.
        }
        try await super.tearDown()
    }

    /// The purge over this test's temporary containers and suites. The
    /// keychain, the assistant's stores, settings and CloudKit's local state
    /// are still the app's shared instances; settings are restored above.
    private func purge(remoteDeleted: Bool = true) async -> DataPurgeService.Report {
        await DataPurgeService.purgeAllUserData(
            archive: archive, rawBackup: RawRRBackup(),
            cloudSync: CloudKitSyncManager.shared, settingsManager: SettingsManager.shared,
            deleteRemote: { remoteDeleted }, scope: scope
        )
    }

    func testPurgeReturnsReportWithEveryStepAccountedFor() async {
        let report = await purge()

        XCTAssertTrue(report.remoteDeleted, "Stubbed remote deletion outcome must flow into the report")

        // Every step exposes its outcome via a Bool — not a missing field.
        // The unconditional steps must always be true:
        XCTAssertTrue(report.cloudSyncStateReset, "CloudKit local state reset is unconditional")
        XCTAssertTrue(report.keychainCleared, "Keychain wipe is unconditional")
        XCTAssertTrue(report.conversationsCleared, "Conversation clear is unconditional")
        XCTAssertTrue(report.userFactsCleared, "User-facts clear is unconditional")
        XCTAssertTrue(report.disclaimerReset, "Disclaimer reset is unconditional")
        // The App Group preferences suite is swept without a false
        // "domain unavailable" failure: iOS gives a group suite no persistent
        // domain under its own name, and that is not an error.
        XCTAssertFalse(report.errors.contains(where: { $0.contains("Preferences sweep") }),
                       "the preferences sweep must not report a failure: \(report.errors)")
    }

    func testReportSummaryMentionsEveryStep() async {
        let report = await purge()
        let summary = report.summary

        XCTAssertTrue(summary.contains("iCloud records"), "summary must mention the remote deletion step: \(summary)")
        XCTAssertTrue(summary.contains("Local sessions"), "summary must mention archive: \(summary)")
        XCTAssertTrue(summary.contains("Raw backups"), "summary must mention backups: \(summary)")
        XCTAssertTrue(summary.contains("iCloud sync state"), "summary must mention CloudKit: \(summary)")
        XCTAssertTrue(summary.contains("AI provider keys"), "summary must mention keychain: \(summary)")
        XCTAssertTrue(summary.contains("AI conversation history"), "summary must mention conversation: \(summary)")
        XCTAssertTrue(summary.contains("AI memory facts"), "summary must mention user facts: \(summary)")
        XCTAssertTrue(summary.contains("Disclaimer acceptance"), "summary must mention disclaimer: \(summary)")
        XCTAssertFalse(summary.contains("widget"), "the app has no widget, so the summary must not list one: \(summary)")
        XCTAssertTrue(summary.contains("open it again"), "summary should say to reopen the app: \(summary)")
        XCTAssertFalse(summary.contains("pre-existing iCloud records"),
                       "the old 'remote is NOT removed' disclosure must be gone now that the purge deletes remotely: \(summary)")
    }

    // MARK: - Remote Deletion Outcome (GDPR / App Store)

    func testRemoteDeletionSuccessIsSurfacedInSummary() async {
        let report = await purge()
        XCTAssertTrue(report.remoteDeleted)
        XCTAssertTrue(report.summary.contains("iCloud records: deleted"),
                      "success summary must state the remote copies were deleted: \(report.summary)")
        XCTAssertFalse(report.errors.contains(where: { $0.contains("iCloud") }),
                       "no iCloud error should be reported on remote success: \(report.errors)")
    }

    func testRemoteDeletionFailureIsSurfacedAndLocalWipeProceeds() async {
        let report = await purge(remoteDeleted: false)
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
    func testPurgeClearsConversationStoreSingleton() async throws {
        let marker = "purge-marker-\(UUID().uuidString)"
        let store = ConversationStore.shared
        store.save(store.load() + [ChatTurn(role: .user, text: marker)])
        try await waitUntil { store.load().contains { $0.text == marker } }
        XCTAssertTrue(store.load().contains { $0.text == marker },
                      "Sanity: the marker turn reached disk before the purge")

        _ = await purge()

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

    func testPurgeClearsUserFactsSingleton() async {
        UserFactsStore.shared.add("purge-marker-\(UUID().uuidString)")
        XCTAssertFalse(UserFactsStore.shared.facts.isEmpty, "Sanity: facts seeded")

        _ = await purge()

        XCTAssertTrue(UserFactsStore.shared.facts.isEmpty,
                      "DataPurgeService should leave UserFactsStore empty")
    }

    func testPurgeResetsDisclaimerFlagOnSettingsManager() async {
        SettingsManager.shared.hasAcceptedDisclaimer = true

        _ = await purge()

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

        _ = await purge()

        for url in sentinels {
            XCTAssertFalse(
                fileManager.fileExists(atPath: url.path),
                "\(url.lastPathComponent) survived Delete All My Data. Every file in every container must go unless it is on DataPurgeService.keepList."
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
    func testSweepRemovesAnUnknownDefaultsKeyFromEverySuite() async {
        let key = "zz_audit_sentinel_defaults"
        appSuite.set("sentinel", forKey: key)
        groupSuite.set("sentinel", forKey: key)

        _ = await purge()

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
    func testPurgeLeavesEntitlementAndMigrationStateIntact() async {
        let mustSurvive = [
            "storekit.lastKnownPurchased",
            "storekit.lastKnownTestFlight",
            "entitlement.anchor.v1",
            "FlowRecovery.migration.metrics.v1.done",
            "didRunTrimpRepairMigration_v1"
        ]
        for key in mustSurvive {
            appSuite.set("sentinel", forKey: key)
        }

        _ = await purge()

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
    /// persistent domain (`SettingsView+Appearance`). A preferences sweep that
    /// did not exclude the system-owned prefixes would reset the user's chosen
    /// UI language as a side effect of deleting their data.
    func testPurgeLeavesTheChosenAppLanguageAlone() async {
        let key = "AppleLanguages"
        appSuite.set(["fr"], forKey: key)

        _ = await purge()

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

        _ = await purge()

        XCTAssertFalse(fileManager.fileExists(atPath: dir.path), "An unknown directory survived the purge.")
    }

    /// The biometric profile must not survive an erasure request.
    func testPurgeResetsTheBiometricProfile() async {
        let manager = SettingsManager.shared
        manager.settings.bodyWeightKg = 81.5
        manager.hasAcceptedDisclaimer = true

        _ = await purge()

        XCTAssertEqual(
            manager.settings.bodyWeightKg, UserSettings().bodyWeightKg,
            "Body weight survived Delete All My Data"
        )
        XCTAssertFalse(manager.hasAcceptedDisclaimer)
    }

    /// A user who just deleted their iCloud copy must not have sync quietly
    /// switched back on by the reset to fresh-install defaults.
    func testPurgeLeavesICloudSyncOff() async {
        let manager = SettingsManager.shared
        manager.settings.iCloudSyncEnabled = true

        _ = await purge()

        XCTAssertFalse(manager.settings.iCloudSyncEnabled, "Delete All My Data turned iCloud sync back on")
    }
}
