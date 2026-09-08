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

    func testPurgeReturnsReportWithEveryStepAccountedFor() async {
        let report = await DataPurgeService.purgeAllUserData(
            archive: SessionArchive.shared,
            rawBackup: RawRRBackup(),
            cloudSync: CloudKitSyncManager.shared,
            settingsManager: SettingsManager.shared,
            deleteRemote: { true }
        )

        XCTAssertTrue(report.remoteDeleted, "Stubbed remote deletion outcome must flow into the report")

        // Every step exposes its outcome via a Bool — not a missing field.
        // The unconditional steps must always be true:
        XCTAssertTrue(report.cloudSyncStateReset, "CloudKit local state reset is unconditional")
        XCTAssertTrue(report.keychainCleared, "Keychain wipe is unconditional")
        XCTAssertTrue(report.conversationsCleared, "Conversation clear is unconditional")
        XCTAssertTrue(report.userFactsCleared, "User-facts clear is unconditional")
        XCTAssertTrue(report.disclaimerReset, "Disclaimer reset is unconditional")
        // Widget purge is unconditional too. The
        // App Group container is always reachable from the main app
        // target (the entitlement is mandatory), so this should
        // always be true. If it's false in CI, either the App Group
        // entitlement was dropped or `AppConfig.appGroupIdentifier`
        // drifted from the entitlement value.
        XCTAssertTrue(report.widgetStateCleared,
                      "Widget published state must be cleared by purge")
    }

    func testReportSummaryMentionsEveryStep() async {
        let report = await DataPurgeService.purgeAllUserData(
            archive: SessionArchive.shared,
            rawBackup: RawRRBackup(),
            cloudSync: CloudKitSyncManager.shared,
            settingsManager: SettingsManager.shared,
            deleteRemote: { true }
        )
        let summary = report.summary

        XCTAssertTrue(summary.contains("iCloud records"), "summary must mention the remote deletion step: \(summary)")
        XCTAssertTrue(summary.contains("Local sessions"), "summary must mention archive: \(summary)")
        XCTAssertTrue(summary.contains("Raw backups"), "summary must mention backups: \(summary)")
        XCTAssertTrue(summary.contains("iCloud sync state"), "summary must mention CloudKit: \(summary)")
        XCTAssertTrue(summary.contains("AI provider keys"), "summary must mention keychain: \(summary)")
        XCTAssertTrue(summary.contains("AI conversation history"), "summary must mention conversation: \(summary)")
        XCTAssertTrue(summary.contains("AI memory facts"), "summary must mention user facts: \(summary)")
        XCTAssertTrue(summary.contains("Disclaimer acceptance"), "summary must mention disclaimer: \(summary)")
        XCTAssertTrue(summary.contains("Home-screen widget data"),
                      "summary must mention the widget purge step: \(summary)")
        XCTAssertTrue(summary.contains("Restart the app"), "summary should remind user to restart")
        XCTAssertFalse(summary.contains("pre-existing iCloud records"),
                       "the old 'remote is NOT removed' disclosure must be gone now that the purge deletes remotely: \(summary)")
    }

    // MARK: - Remote Deletion Outcome (GDPR / App Store)

    func testRemoteDeletionSuccessIsSurfacedInSummary() async {
        let report = await DataPurgeService.purgeAllUserData(
            archive: SessionArchive.shared,
            rawBackup: RawRRBackup(),
            cloudSync: CloudKitSyncManager.shared,
            settingsManager: SettingsManager.shared,
            deleteRemote: { true }
        )
        XCTAssertTrue(report.remoteDeleted)
        XCTAssertTrue(report.summary.contains("iCloud records: deleted"),
                      "success summary must state the remote copies were deleted: \(report.summary)")
        XCTAssertFalse(report.errors.contains(where: { $0.contains("iCloud") }),
                       "no iCloud error should be reported on remote success: \(report.errors)")
    }

    func testRemoteDeletionFailureIsSurfacedAndLocalWipeProceeds() async {
        let report = await DataPurgeService.purgeAllUserData(
            archive: SessionArchive.shared,
            rawBackup: RawRRBackup(),
            cloudSync: CloudKitSyncManager.shared,
            settingsManager: SettingsManager.shared,
            deleteRemote: { false }
        )
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

    func testPurgeClearsConversationStoreSingleton() async {
        // Seed the singleton with at least one turn so we can verify clear ran.
        let initial = ConversationStore.shared.load()
        ConversationStore.shared.save(initial + [
            ChatTurn(role: .user, text: "purge-marker-\(UUID().uuidString)")
        ])

        // Allow the async write to land before triggering the purge.
        let saved = expectation(description: "conversation save")
        DispatchQueue.global().async {
            // load() is synchronous against the same internal queue, so it acts as a barrier.
            _ = ConversationStore.shared.load()
            saved.fulfill()
        }
        await fulfillment(of: [saved], timeout: 2.0)

        _ = await DataPurgeService.purgeAllUserData(
            archive: SessionArchive.shared,
            rawBackup: RawRRBackup(),
            cloudSync: CloudKitSyncManager.shared,
            settingsManager: SettingsManager.shared,
            deleteRemote: { true }
        )

        // Allow async clear to land.
        let cleared = expectation(description: "conversation cleared")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            cleared.fulfill()
        }
        await fulfillment(of: [cleared], timeout: 2.0)

        XCTAssertTrue(ConversationStore.shared.load().isEmpty,
                      "DataPurgeService should leave conversation history empty")
    }

    func testPurgeClearsUserFactsSingleton() async {
        UserFactsStore.shared.add("purge-marker-\(UUID().uuidString)")
        XCTAssertFalse(UserFactsStore.shared.facts.isEmpty, "Sanity: facts seeded")

        _ = await DataPurgeService.purgeAllUserData(
            archive: SessionArchive.shared,
            rawBackup: RawRRBackup(),
            cloudSync: CloudKitSyncManager.shared,
            settingsManager: SettingsManager.shared,
            deleteRemote: { true }
        )

        XCTAssertTrue(UserFactsStore.shared.facts.isEmpty,
                      "DataPurgeService should leave UserFactsStore empty")
    }

    func testPurgeResetsDisclaimerFlagOnSettingsManager() async {
        SettingsManager.shared.hasAcceptedDisclaimer = true

        _ = await DataPurgeService.purgeAllUserData(
            archive: SessionArchive.shared,
            rawBackup: RawRRBackup(),
            cloudSync: CloudKitSyncManager.shared,
            settingsManager: SettingsManager.shared,
            deleteRemote: { true }
        )

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
    func testSweepRemovesAnUnknownFileFromEveryContainer() async {
        let fileManager = FileManager.default
        var sentinels: [URL] = []

        if let group = fileManager.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupIdentifier) {
            sentinels.append(group.appendingPathComponent("zz_audit_sentinel_group.json"))
        }
        for directory in [FileManager.SearchPathDirectory.applicationSupportDirectory, .documentDirectory] {
            if let url = fileManager.urls(for: directory, in: .userDomainMask).first {
                sentinels.append(url.appendingPathComponent("zz_audit_sentinel_\(directory.rawValue).json"))
            }
        }
        XCTAssertFalse(sentinels.isEmpty, "No container resolved — the sweep would be untested.")

        for url in sentinels {
            XCTAssertNoThrow(try Data("sentinel".utf8).write(to: url), "Could not seed \(url.lastPathComponent)")
        }

        _ = await DataPurgeService.purgeAllUserData(
            archive: SessionArchive(), rawBackup: RawRRBackup(),
            cloudSync: CloudKitSyncManager.shared, settingsManager: SettingsManager.shared,
            deleteRemote: { true }
        )

        for url in sentinels {
            XCTAssertFalse(
                fileManager.fileExists(atPath: url.path),
                "\(url.lastPathComponent) survived Delete All My Data. Every file in every container must go unless it is on DataPurgeService.keepList."
            )
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
        let group = UserDefaults(suiteName: AppConfig.appGroupIdentifier)
        XCTAssertNotNil(group, "App Group suite unavailable — the sweep would be untested.")
        let key = "zz_audit_sentinel_defaults"

        UserDefaults.standard.set("sentinel", forKey: key)
        group?.set("sentinel", forKey: key)

        _ = await DataPurgeService.purgeAllUserData(
            archive: SessionArchive(), rawBackup: RawRRBackup(),
            cloudSync: CloudKitSyncManager.shared, settingsManager: SettingsManager.shared,
            deleteRemote: { true }
        )

        XCTAssertNil(
            UserDefaults.standard.object(forKey: key),
            "A UserDefaults key survived Delete All My Data in the app's own suite."
        )
        XCTAssertNil(
            group?.object(forKey: key),
            "A UserDefaults key survived Delete All My Data in the App Group suite."
        )
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
            UserDefaults.standard.set("sentinel", forKey: key)
        }
        defer { mustSurvive.forEach(UserDefaults.standard.removeObject(forKey:)) }

        _ = await DataPurgeService.purgeAllUserData(
            archive: SessionArchive(), rawBackup: RawRRBackup(),
            cloudSync: CloudKitSyncManager.shared, settingsManager: SettingsManager.shared,
            deleteRemote: { true }
        )

        for key in mustSurvive {
            XCTAssertNotNil(
                UserDefaults.standard.object(forKey: key),
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
        let original = UserDefaults.standard.array(forKey: key)
        UserDefaults.standard.set(["fr"], forKey: key)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        _ = await DataPurgeService.purgeAllUserData(
            archive: SessionArchive(), rawBackup: RawRRBackup(),
            cloudSync: CloudKitSyncManager.shared, settingsManager: SettingsManager.shared,
            deleteRemote: { true }
        )

        XCTAssertEqual(
            UserDefaults.standard.array(forKey: key) as? [String], ["fr"],
            "The purge changed the app's display language."
        )
    }

    /// A directory, not just a file — `saved_routes.json` was a file but
    /// `Assistant/` and `HRVOffline/` are directories, and a sweep that only
    /// unlinked files would have left both.
    func testSweepRemovesAnUnknownDirectory() async {
        let fileManager = FileManager.default
        guard let group = fileManager.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupIdentifier) else {
            XCTFail("App Group container unavailable — the sweep would be untested.")
            return
        }
        let dir = group.appendingPathComponent("zz_audit_sentinel_dir", isDirectory: true)
        XCTAssertNoThrow(try fileManager.createDirectory(at: dir, withIntermediateDirectories: true))
        XCTAssertNoThrow(try Data("x".utf8).write(to: dir.appendingPathComponent("inner.json")))

        _ = await DataPurgeService.purgeAllUserData(
            archive: SessionArchive(), rawBackup: RawRRBackup(),
            cloudSync: CloudKitSyncManager.shared, settingsManager: SettingsManager.shared,
            deleteRemote: { true }
        )

        XCTAssertFalse(fileManager.fileExists(atPath: dir.path), "An unknown directory survived the purge.")
    }

    /// The biometric profile must not survive an erasure request.
    func testPurgeResetsTheBiometricProfile() async {
        let manager = SettingsManager.shared
        manager.settings.bodyWeightKg = 81.5
        manager.hasAcceptedDisclaimer = true

        _ = await DataPurgeService.purgeAllUserData(
            archive: SessionArchive(), rawBackup: RawRRBackup(),
            cloudSync: CloudKitSyncManager.shared, settingsManager: manager,
            deleteRemote: { true }
        )

        XCTAssertEqual(
            manager.settings.bodyWeightKg, UserSettings().bodyWeightKg,
            "Body weight survived Delete All My Data"
        )
        XCTAssertFalse(manager.hasAcceptedDisclaimer)
    }
}
