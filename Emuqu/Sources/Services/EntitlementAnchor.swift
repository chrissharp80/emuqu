import Foundation
import Security

// Durable anchor for the two entitlement facts that must survive an app
// deletion, a device wipe, and a move to a new phone:
//
//   1. `isBetaTester` — this Apple ID ran a TestFlight build at least once.
//      Beta testers are grandfathered permanently and never see the paywall
//      on any device, per the pricing decision.
//   2. `trialStartDate` — when the free trial began. Anchored durably
//      so deleting and reinstalling the app cannot hand the user a fresh
//      trial.
//
// WHY A KEYCHAIN ITEM AND NOT `NSUbiquitousKeyValueStore`
//
// The obvious home for "a small fact that follows the Apple ID" is the
// iCloud key-value store. It is not used here because it requires the
// `com.apple.developer.ubiquity-kvstore-identifier` entitlement, and adding
// an entitlement forces the provisioning profile to be regenerated. The
// entitlements file for this target is deliberately frozen (see the comment
// in `Emuqu.entitlements` about the App Group and CloudKit container names
// addressing live user data), and a re-provisioning round trip is exactly
// the kind of change that breaks a build for reasons unrelated to the code.
//
// A generic-password keychain item with `kSecAttrSynchronizable = true` has
// the same two properties we actually need — it survives app deletion, and
// iCloud Keychain replicates it to every device signed into the same Apple
// ID — and it needs no entitlement at all. `UserSettings` also round-trips
// through CloudKit via `CloudKitSettingsSync`, which gives `trialStartDate`
// a third, independent backstop for free.
//
// Storage tiers OWNED by this type:
//
//   UserDefaults  — synchronous, on the launch critical path. A cache only.
//   Keychain      — authoritative, survives delete, syncs across devices.
//
// `persist` fans out to both, and `resolve` merges both monotonically, so a
// tier that is empty or stale can only ever lose to a tier that knows more.
// That is what makes the anchor tamper-resistant without any server.
//
// There is a THIRD copy of `trialStartDate`, and this type does NOT own it:
// `UserSettings.trialStartDate` rides the pre-existing `CloudKitSettingsSync`
// and is bridged in by `SettingsManager.adoptTrialStart(_:)`, which calls
// `adoptTrialStart(_:wallClock:)` on the way in and mirrors the resolved
// value back out. Do not read the list above as "the anchor also writes
// settings" — it does not, and deleting that bridge on the assumption that it
// does would drop the only copy that survives a device change with iCloud
// Keychain switched off.
enum EntitlementAnchor {
    /// The durable facts. Monotonic by construction — see `merged`.
    struct Record: Codable, Equatable {
        /// Once true, always true. Set only on proof of a sandbox receipt.
        var isBetaTester: Bool
        /// Earliest observed trial start. Never moves later.
        var trialStartDate: Date?
        /// Highest wall-clock time this app has ever observed. Guards
        /// against a user winding the device clock back to extend the
        /// trial — see `effectiveNow(_:)`.
        var highWaterMark: Date
        /// When a store build first checked the device for pre-existing
        /// history (see `evaluatedHistory`). Set once; the earliest value
        /// wins on merge.
        ///
        /// Encoded under a new key on purpose. TestFlight builds used to run
        /// the check too, under `historyCheckedAt`, and locked it for any
        /// tester whose device was still empty at that moment. That tester
        /// could then record for months and still meet the trial on the store
        /// build. The old key is no longer decoded, so the first store launch
        /// looks again; TestFlight builds now anchor testers directly instead.
        var storeHistoryCheckedAt: Date?

        static let empty = Record(isBetaTester: false, trialStartDate: nil, highWaterMark: .distantPast)
    }

    // MARK: - Pure merge logic
    //
    // Kept free of I/O so the monotonic guarantees can be tested directly.

    /// Combines two views of the anchor, keeping the strongest claim from
    /// each. Beta status ORs (never revoked by a tier that has not heard of
    /// it), the trial start takes the EARLIEST non-nil value (a reinstall
    /// cannot restart the clock), and the high-water mark takes the LATEST
    /// (a rolled-back clock cannot rewind it).
    static func merged(_ lhs: Record?, _ rhs: Record?) -> Record? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return Record(
            isBetaTester: lhs.isBetaTester || rhs.isBetaTester,
            trialStartDate: earlier(lhs.trialStartDate, rhs.trialStartDate),
            highWaterMark: max(lhs.highWaterMark, rhs.highWaterMark),
            storeHistoryCheckedAt: earlier(lhs.storeHistoryCheckedAt, rhs.storeHistoryCheckedAt)
        )
    }

    /// The beta cohort is closed, so "used the app before it was on the
    /// App Store" is the same set as "beta tester", and the device already
    /// holds the proof: archived sessions. A fresh App Store install has none
    /// at its first launch, because nothing could have recorded them. The
    /// check is made once, at the first launch that sees no prior check, and
    /// the timestamp is stored so a new user who records sessions during the
    /// trial is never re-evaluated. Pure; `recordHistoryCheck` persists it.
    static func evaluatedHistory(_ record: Record, hasHistory: Bool, wallClock: Date) -> Record {
        guard record.storeHistoryCheckedAt == nil else { return record }
        var updated = record
        updated.storeHistoryCheckedAt = effectiveNow(record, wallClock: wallClock)
        if hasHistory { updated.isBetaTester = true }
        return updated
    }

    /// The later of `now` and everything this install has seen before.
    /// Winding the clock back therefore cannot rewind the trial: it is measured
    /// against the furthest point time has ever reached. What it can do, with
    /// no server clock to consult, is hold the trial still for as long as the
    /// clock stays behind that point.
    static func effectiveNow(_ record: Record, wallClock: Date) -> Date {
        max(wallClock, record.highWaterMark)
    }

    /// Returns a copy with the high-water mark advanced to `wallClock` when
    /// that is genuinely later. Never moves it backwards.
    static func advanced(_ record: Record, to wallClock: Date) -> Record {
        guard wallClock > record.highWaterMark else { return record }
        var updated = record
        updated.highWaterMark = wallClock
        return updated
    }

    private static func earlier(_ lhs: Date?, _ rhs: Date?) -> Date? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return min(lhs, rhs)
    }

    // MARK: - Public API

    /// Fast, synchronous read for the launch path. Reads the UserDefaults
    /// cache only — no keychain round trip, no I/O that could stall the
    /// first frame. Callers that need the authoritative answer use
    /// `resolve(wallClock:)`, which is safe to run after launch.
    static func cached() -> Record {
        loadFromDefaults() ?? .empty
    }

    /// Merges every tier, writes the result back to all of them, and returns
    /// it. This is the authoritative read. It touches the keychain, so it
    /// belongs off the synchronous launch path — `StoreKitManager.boot()`
    /// calls it after the first frame paints.
    @discardableResult
    static func resolve(wallClock: Date) -> Record {
        let combined = merged(loadFromDefaults(), loadFromKeychain()) ?? .empty
        let advancedRecord = advanced(combined, to: wallClock)
        persist(advancedRecord)
        return advancedRecord
    }

    /// The read the launch gate uses.
    ///
    /// Returns the UserDefaults cache when it already carries a positive
    /// answer, and only falls through to the keychain when it does not.
    ///
    /// That fall-through is the whole point. The gate runs from
    /// `AppLaunchTasks.loadDataAndContinue()`, which is reached from the
    /// FIRST `.task` on the root view — ahead of `runDeferredBoot()` →
    /// `StoreKitManager.boot()`, where the anchor is otherwise reconciled.
    /// For a beta tester who has deleted and reinstalled, or restored onto
    /// a new phone, UserDefaults is empty and their status exists only in
    /// the synchronizable keychain. Reading the fast tier alone would hand
    /// that person a paywall, which is the exact outcome the anchor exists
    /// to prevent.
    ///
    /// Cost is shaped to match: a launch where the anchor is already
    /// populated does no keychain I/O at all, and the one launch where it
    /// is not pays a single read plus the write that promotes the answer
    /// into the fast tier for every subsequent read.
    @discardableResult
    static func resolvedForGate(wallClock: Date) -> Record {
        let fast = cached()
        if fast.isBetaTester || fast.trialStartDate != nil { return fast }
        return resolve(wallClock: wallClock)
    }

    /// Records — permanently — that this Apple ID is a beta tester.
    ///
    /// Called ONLY on positive proof of a TestFlight sandbox receipt. It is
    /// deliberately never called from `isDeveloperInstall`, which grants
    /// access on the much weaker signal of "no App Store receipt present"
    /// and would otherwise stamp a permanent free entitlement onto any
    /// sideloaded build.
    @discardableResult
    static func recordBetaTester(wallClock: Date) -> Record {
        var record = resolve(wallClock: wallClock)
        guard !record.isBetaTester else { return record }
        record.isBetaTester = true
        persist(record)
        debugLog("[Entitlement] beta tester recorded — grandfathered permanently", level: .info)
        return record
    }

    /// Persists `evaluatedHistory` for this launch's look at the device.
    @discardableResult
    static func recordHistoryCheck(hasHistory: Bool, wallClock: Date) -> Record {
        let record = resolve(wallClock: wallClock)
        let updated = evaluatedHistory(record, hasHistory: hasHistory, wallClock: wallClock)
        guard updated != record else { return record }
        persist(updated)
        if updated.isBetaTester, !record.isBetaTester {
            debugLog("[Entitlement] existing history found at first launch — grandfathered as a beta tester", level: .info)
        }
        return updated
    }

    /// Adopts a trial start date discovered elsewhere — the App Store's
    /// purchase date for the trial product, or the `UserSettings.trialStartDate`
    /// that `CloudKitSettingsSync` restores from iCloud. Keeps the earlier of
    /// the two, so this can only ever shorten the remaining trial, never extend
    /// it.
    ///
    /// The start is also a moment time has provably reached, so the high-water
    /// mark moves up to it. Without that, a new phone whose clock is set before
    /// the trial began — iCloud Keychain off, so no mark came with it — read
    /// the elapsed time as zero and showed a full trial for as long as the
    /// clock stayed back.
    static func adoptTrialStart(_ candidate: Date?, wallClock: Date) {
        guard let candidate else { return }
        let record = resolve(wallClock: wallClock)
        var updated = advanced(record, to: candidate)
        if record.trialStartDate == nil || candidate < (record.trialStartDate ?? candidate) {
            updated.trialStartDate = earlier(record.trialStartDate, candidate)
        }
        guard updated != record else { return }
        persist(updated)
    }

    // MARK: - Persistence fan-out

    private static func persist(_ record: Record) {
        saveToDefaults(record)
        saveToKeychain(record)
    }

    // MARK: - Tier 1: UserDefaults (fast cache)

    private static let defaultsKey = "entitlement.anchor.v1"

    private static func loadFromDefaults() -> Record? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return decode(data)
    }

    private static func saveToDefaults(_ record: Record) {
        guard let data = encode(record) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    // MARK: - Tier 2: Keychain (durable, iCloud-synced)

    private static let keychainService = "com.chrissharp.flowrecovery.entitlement"
    private static let keychainAccount = "primary"

    /// Base query shared by read, update and delete.
    ///
    /// `kSecAttrSynchronizable: true` is what makes the item follow the
    /// Apple ID through iCloud Keychain. A synchronizable item CANNOT use a
    /// `...ThisDeviceOnly` accessibility class, which is why this uses
    /// `kSecAttrAccessibleAfterFirstUnlock` rather than the
    /// device-only variant `APIKeyStore` uses for provider API keys — those
    /// deliberately must not leave the device; this deliberately must.
    private static var keychainQuery: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
            kSecAttrSynchronizable: true
        ]
    }

    private static func loadFromKeychain() -> Record? {
        var query = keychainQuery
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return decode(data)
    }

    private static func saveToKeychain(_ record: Record) {
        guard let data = encode(record) else { return }
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(keychainQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            debugLog("[Entitlement] keychain update failed (status \(updateStatus))", level: .warning)
            return
        }
        addToKeychain(attributes)
    }

    /// No existing item to update — insert one instead.
    private static func addToKeychain(_ attributes: [CFString: Any]) {
        var addQuery = keychainQuery
        for (key, value) in attributes {
            addQuery[key] = value
        }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            debugLog("[Entitlement] keychain add failed (status \(addStatus))", level: .warning)
        }
    }

    // MARK: - Test support

    /// Clears every tier of the anchor.
    ///
    /// DEBUG-only and used by exactly one caller: the
    /// `-UITests-FreshInstall` harness, so that a "fresh install" test run
    /// really starts from nothing. The anchor's entire purpose is to
    /// survive deletion, which makes it the one piece of state a reinstall
    /// cannot clear — and therefore the one piece a UI test must be able to
    /// clear explicitly, or every run after the first inherits the previous
    /// run's trial clock.
    ///
    /// Deliberately compiled out of Release. There is no shipping code path
    /// that should ever be able to erase a user's entitlement.
    #if DEBUG
        static func resetForUITesting() {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            SecItemDelete(keychainQuery as CFDictionary)
        }
    #endif

    // MARK: - Coding
    //
    // Spelled out with do/catch rather than an optional-try on purpose. The
    // tech-debt budget in `.ci/try_optional_budget.txt` is a ratchet, and
    // swallowing the error here would hide a decode failure that means
    // "this user's entitlement just disappeared" — precisely the class of
    // silent failure the refactor spec forbids.

    private static func encode(_ record: Record) -> Data? {
        do {
            return try JSONEncoder().encode(record)
        } catch {
            debugLog("[Entitlement] anchor encode failed: \(error)", level: .error)
            return nil
        }
    }

    private static func decode(_ data: Data) -> Record? {
        do {
            return try JSONDecoder().decode(Record.self, from: data)
        } catch {
            debugLog("[Entitlement] anchor decode failed: \(error)", level: .error)
            return nil
        }
    }
}

// MARK: - Trial arithmetic

/// Pure, side-effect-free arithmetic for the free trial.
///
/// Split from `EntitlementAnchor` storage so every rule below is testable
/// without a keychain, a clock, or a simulator. Every function takes the
/// current time as a parameter rather than reading `Date()` internally.
enum TrialPolicy {
    /// Length of the free trial, in days.
    ///
    /// Thirty, because the app's headline score needs 14 nights to appear and
    /// 28 for full confidence: a shorter trial ends before the user has seen
    /// the thing they would be paying for. No cohort to migrate — the 7 this
    /// replaces never reached a paying user, as the paywall was off until the
    /// store release.
    static let durationDays = 30

    private static let secondsPerDay: TimeInterval = 86_400

    /// Total trial length as an interval.
    static var duration: TimeInterval {
        Double(durationDays) * secondsPerDay
    }

    /// Whole days left in the trial, rounded UP so a user 6.2 days in is
    /// told "1 day remaining" rather than "0". Returns 0 when the trial has
    /// not started or has run out.
    static func daysRemaining(start: Date?, now: Date) -> Int {
        guard let start else { return 0 }
        let elapsed = max(0, now.timeIntervalSince(start))
        let remaining = duration - elapsed
        guard remaining > 0 else { return 0 }
        return Int(ceil(remaining / secondsPerDay))
    }

    /// Whether the trial is currently running.
    static func isActive(start: Date?, now: Date) -> Bool {
        guard let start else { return false }
        return max(0, now.timeIntervalSince(start)) < duration
    }

    /// Whether the trial started and has since run out. Distinct from
    /// `!isActive`, which is also true for a trial that never began.
    static func hasExpired(start: Date?, now: Date) -> Bool {
        guard start != nil else { return false }
        return !isActive(start: start, now: now)
    }
}
