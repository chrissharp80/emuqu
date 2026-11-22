@testable import Emuqu
import XCTest

// MARK: - Shared Test Data Generators

/// Create realistic RR points with sine-wave variability (deterministic).
/// - Parameters:
///   - count: Number of RR points to generate.
///   - meanRR: Mean RR interval in milliseconds (default 800).
///   - startMs: Starting timestamp in milliseconds (default 0).
/// - Returns: Array of RRPoint with physiologically clamped intervals.
func createRealisticPoints(count: Int, meanRR: Int = 800, startMs: Int64 = 0) -> [RRPoint] {
    var points: [RRPoint] = []
    var tMs = startMs
    for i in 0 ..< count {
        let variation = Int(sin(Double(i) / 50.0) * 40)
        let rr = max(300, meanRR + variation)
        points.append(RRPoint(t_ms: tMs, rr_ms: rr))
        tMs += Int64(rr)
    }
    return points
}

/// Create uniform RR points (no variability).
/// - Parameters:
///   - count: Number of RR points to generate.
///   - rrMs: Fixed RR interval in milliseconds (default 800).
/// - Returns: Array of RRPoint with identical intervals.
func createUniformPoints(count: Int, rrMs: Int = 800) -> [RRPoint] {
    (0 ..< count).map { i in
        RRPoint(t_ms: Int64(i) * Int64(rrMs), rr_ms: rrMs)
    }
}

/// Build clean artifact flags for every point.
/// - Parameter count: Number of flags to generate.
/// - Returns: Array of clean ArtifactFlags.
func cleanFlags(count: Int) -> [ArtifactFlags] {
    Array(repeating: ArtifactFlags.clean, count: count)
}

// MARK: - Language

extension XCTestCase {
    /// Sets the app's language to English for the rest of this test and
    /// registers a teardown that puts the previous choice back.
    ///
    /// Copy reaches the screen through `LanguageManager.appBundle`, which
    /// follows the host's language unless the user picked one. A test that
    /// asserts English text, or renders a snapshot reference recorded in
    /// English, calls this first so it passes on a host set to any language.
    @MainActor
    func pinEnglishLanguage() {
        guard LanguageManager.appLocale.language.languageCode != .english else { return }
        let original = AppLanguage.current
        LanguageManager.shared.setLanguage(.en)
        addTeardownBlock { @MainActor in LanguageManager.shared.setLanguage(original) }
    }

    /// Fails the test, and stops it, when the app's encryption key is out of
    /// reach. Every runner is expected to have it
    /// (`EncryptionManagerTests.testIsAvailable`), so this is a failure, not
    /// a skip: an assertion behind `if EncryptionManager.shared.isAvailable`
    /// passed silently on a runner without the key, and `XCTSkip` would hide
    /// the same thing behind the skip budget.
    func requireEncryptionKey(file: StaticString = #filePath, line: UInt = #line) throws {
        let available: Bool? = EncryptionManager.shared.isAvailable ? true : nil
        _ = try XCTUnwrap(available, "The encryption key is unavailable on this runner", file: file, line: line)
    }
}

/// Keys of the app host's own `UserDefaults.standard`, set aside for a test.
///
/// `setAside(_:)` takes the host's value of every key and removes it;
/// `restore()` puts the values back and removes whatever the test left. Call
/// `restore()` from `tearDown`, after the test's own clean-up (teardown
/// blocks run before `tearDown`).
struct HostDefaults {
    /// `PersistedRecordingState`: the atomic record `load()` reads first,
    /// the legacy three it migrates from, and the dismissed-prompt list
    /// `clear()` wipes. A test that clears them and does not put them back
    /// erases the marker of a recording the host was interrupted in, so the
    /// next launch never offers to recover it.
    static let recordingState = [
        UserDefaultsKeys.persistedRecordingState,
        UserDefaultsKeys.activeRecordingStartTime,
        UserDefaultsKeys.activeRecordingSessionId,
        UserDefaultsKeys.activeRecordingSessionType,
        "RRCollector.dismissedInterruptedSessionIds"
    ]

    /// The sync bookkeeping `CloudKitSyncManager.resetLocalSyncState()` and
    /// `boot()` keep in standard defaults whichever manager runs them: the
    /// session zone flag, the last-sync stamp, the legacy change token and
    /// the settings zone flag (`CloudKitSettingsSync.zoneCreatedKey`).
    static let cloudSyncBookkeeping = [
        UserDefaultsKeys.cloudKitZoneCreated,
        UserDefaultsKeys.cloudKitLastSyncDate,
        UserDefaultsKeys.cloudKitChangeToken,
        "cloudkit.settingsZoneCreated"
    ]

    private let keys: [String]
    private let values: [String: Any]

    static func setAside(_ keys: [String]) -> HostDefaults {
        let defaults = UserDefaults.standard
        var values: [String: Any] = [:]
        for key in keys {
            if let value = defaults.object(forKey: key) { values[key] = value }
            defaults.removeObject(forKey: key)
        }
        return HostDefaults(keys: keys, values: values)
    }

    func restore() {
        let defaults = UserDefaults.standard
        for key in keys {
            if let value = values[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }
}

extension CloudKitSyncManager {
    /// A sync manager of the test's own: over `archive`, with fresh-install
    /// settings unless given others, and its bookkeeping files in
    /// `directory`, loaded (empty) before it is returned. Nothing it records
    /// reaches the app's `CloudKitSyncManager.shared`. What it keeps in
    /// standard defaults is `HostDefaults.cloudSyncBookkeeping`.
    @MainActor
    static func isolated(archive: SessionArchive, directory: URL, settings: SettingsManager? = nil) -> CloudKitSyncManager {
        let manager = CloudKitSyncManager(
            settingsManager: settings ?? SettingsManager(settingsURL: directory.appendingPathComponent("user_settings.json")),
            archive: archive,
            syncStateURL: directory.appendingPathComponent("sync_state.json")
        )
        manager.boot()
        return manager
    }
}
