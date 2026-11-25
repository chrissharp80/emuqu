import Foundation

// The purge's preferences sweep: which `UserDefaults` keys a full wipe
// removes from the app's suites and which it keeps.

extension DataPurgeService {
    // MARK: - Preferences sweep

    /// `UserDefaults` keys a full wipe must leave alone.
    ///
    /// ## Why a keep list
    ///
    /// The container sweep (`sweepAllContainers`) deletes every file that is
    /// not kept, so a future store is covered on the day it is written.
    /// Preferences need the same rule: the app target writes over a hundred
    /// distinct `UserDefaults` keys, and a list of keys to remove misses the
    /// rest — among others `hasAcceptedHealthDisclaimer`, the CloudKit change
    /// token and last-sync date, `reviewedRecoveredWorkoutIds`,
    /// `hkBackfillExportedWatermark`, and every cached baseline
    /// (`RespiratoryBaselineCache`, `WristTemperatureBaselineCache`,
    /// `SleepDataCache`) — derived physiology, which is health data however it
    /// was derived.
    ///
    /// ## Why this list is not empty
    ///
    /// Four groups, and each one is here because sweeping it would break
    /// something a user would notice:
    ///
    ///   * `storekit.lastKnownPurchased` / `storekit.lastKnownTestFlight` are
    ///     read SYNCHRONOUSLY on the launch path — `StoreKitManager.isPurchased`
    ///     resolves from the cache before StoreKit has re-verified anything.
    ///     Deleting them would show a paying customer the paywall after they
    ///     erased their data, and offline it would not resolve at all.
    ///   * `storekit.verifiedProductionInstall` / `storekit.verifiedXcodeInstall`
    ///     record which environment signed this install (App Store / Xcode),
    ///     not user data. `boot()` writes them once per process, so sweeping
    ///     them would drop the beta-tester and Xcode-install grants until the
    ///     next launch.
    ///   * `entitlement.anchor.v1` is the same argument one layer down. Erasing
    ///     someone's data is not a refund; the anchor is deliberately
    ///     device-transferable, which is why it also lives in the iCloud
    ///     Keychain. `entitlement.anchor.account` names this install's own
    ///     item in that Keychain; sweeping it would make the next launch write
    ///     a new synchronizable item after every purge, piling them up in the
    ///     user's iCloud Keychain.
    ///   * The migration flags are bookkeeping, not user data. Clearing them
    ///     would re-run four migrations against a freshly emptied archive for
    ///     no benefit.
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
    /// it (`AppearanceAndLanguagePages`), so sweeping it would silently change the
    /// UI language as a side effect of a data wipe.
    private static let defaultsKeepList: Set<String> = [
        "entitlement.anchor.account",
        "entitlement.anchor.v1",
        "storekit.lastKnownPurchased",
        "storekit.lastKnownTestFlight",
        "storekit.verifiedProductionInstall",
        "storekit.verifiedXcodeInstall"
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
    /// spellings — `FlowRecovery.migration.*` in `ArchiveMigrations+Steps` and
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
    static func deviceDefaultsDomains(errors: inout [String]) -> [(name: String, store: UserDefaults)] {
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
    static func sweepAllDefaults(scope: PurgeScope, errors: inout [String]) -> Int {
        var removed = 0
        for domain in scope.defaultsDomains(&errors) {
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
}
