import Foundation
import Security

// Durable anchor for the two entitlement facts that must survive an app
// deletion, a device wipe, and a move to a new phone:
//
//   1. `isBetaTester` — this Apple ID was recorded as a TestFlight tester
//      by an earlier build (or the legacy flag migrated from one). Those
//      testers are grandfathered permanently on the App Store build, on
//      any device. The grant is honoured only on an install Apple has
//      verified as production (`StoreKitManager.isGrandfatheredBetaTester`):
//      a sandbox install (TestFlight, App Review) meets the same paywall as
//      a customer, whatever this record says.
//   2. The trial start. The App Store's copy, the purchase date of this
//      Apple ID's free-trial transaction, is the clock; it is kept here so
//      the launch gate can read it before StoreKit answers. A start kept
//      without that record, from an earlier build, counts only until the
//      App Store's copy is known.
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
//                   One synchronizable item PER INSTALL (its own account),
//                   plus the legacy `primary` item earlier builds wrote. Every
//                   item of the service is read and merged; an install writes
//                   only its own. A new phone that writes before iCloud
//                   Keychain has delivered the older items therefore adds an
//                   item instead of racing them for one slot, which iCloud
//                   Keychain would settle by picking a winner rather than by
//                   the merge rules below.
//
// Every update reads all tiers, merges them monotonically, and writes the
// result back to the tiers that differ, so a tier that is empty or stale can
// only ever lose to a tier that knows more. A tier that holds a record this
// build cannot decode (a newer build's schema, corruption) is never written
// over: it is left for a build that can read it. That is what makes the
// anchor tamper-resistant without any server.
//
// There is a THIRD copy of `trialStartDate`, and this type does NOT own it:
// `UserSettings.trialStartDate` rides the pre-existing `CloudKitSettingsSync`.
// `SettingsManager.adoptTrialStart(_:)` mirrors the anchor's start into it
// after an App Store trial transaction is recorded, and `SettingsManager`
// reads it as a fallback when the anchor has none — the only copy that
// survives a device change with iCloud Keychain switched off. Nothing
// currently feeds a start that exists only in synced settings back into the
// anchor.
enum EntitlementAnchor {
    /// The durable facts. Monotonic by construction, apart from the App
    /// Store's trial start, which follows the signed-in Apple ID — see
    /// `merged`.
    struct Record: Codable, Equatable {
        /// Once true, always true. Set by migrating the legacy TestFlight flag
        /// (`recordBetaTester`) or by the one-time history check at the first
        /// store-build launch when the device already holds sessions
        /// (`evaluatedHistory`).
        var isBetaTester: Bool
        /// Earliest trial start kept on this device without the App Store's
        /// record: an earlier build's start, or one restored from synced
        /// settings. Never moves later. Encoded under the original
        /// `trialStartDate` key, so earlier builds keep reading it.
        var deviceTrialStartDate: Date?
        /// The purchase date of the free-trial transaction StoreKit last
        /// reported for the signed-in Apple ID. Replaced, not merged, on
        /// each report: it is the App Store's clock, not this device's.
        var storeTrialStartDate: Date?
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
        /// looks again.
        var storeHistoryCheckedAt: Date?

        static let empty = Record(isBetaTester: false, trialStartDate: nil, highWaterMark: .distantPast)

        /// The trial start that counts: the App Store's when known, the
        /// device's otherwise.
        var trialStartDate: Date? {
            storeTrialStartDate ?? deviceTrialStartDate
        }

        init(
            isBetaTester: Bool,
            trialStartDate: Date?,
            highWaterMark: Date,
            storeHistoryCheckedAt: Date? = nil,
            storeTrialStartDate: Date? = nil
        ) {
            self.isBetaTester = isBetaTester
            self.deviceTrialStartDate = trialStartDate
            self.storeTrialStartDate = storeTrialStartDate
            self.highWaterMark = highWaterMark
            self.storeHistoryCheckedAt = storeHistoryCheckedAt
        }

        private enum CodingKeys: String, CodingKey {
            case isBetaTester
            case deviceTrialStartDate = "trialStartDate"
            case storeTrialStartDate
            case highWaterMark
            case storeHistoryCheckedAt
        }
    }

    // MARK: - Pure merge logic
    //
    // Kept free of I/O so the monotonic guarantees can be tested directly.

    /// Combines two views of the anchor, keeping the strongest claim from
    /// each. Beta status ORs (never revoked by a tier that has not heard of
    /// it), the device's trial start takes the EARLIEST non-nil value (a
    /// reinstall cannot restart the clock), and the high-water mark takes the
    /// LATEST (a rolled-back clock cannot rewind it).
    ///
    /// The App Store's trial start takes the LATER value. Both tiers hold the
    /// same date for one Apple ID; they differ only after the device switched
    /// Apple IDs, and the later date is the trial that Apple ID just started.
    /// Every entitlement sweep writes the signed-in Apple ID's date again.
    static func merged(_ lhs: Record?, _ rhs: Record?) -> Record? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return Record(
            isBetaTester: lhs.isBetaTester || rhs.isBetaTester,
            trialStartDate: earlier(lhs.deviceTrialStartDate, rhs.deviceTrialStartDate),
            highWaterMark: max(lhs.highWaterMark, rhs.highWaterMark),
            storeHistoryCheckedAt: earlier(lhs.storeHistoryCheckedAt, rhs.storeHistoryCheckedAt),
            storeTrialStartDate: later(lhs.storeTrialStartDate, rhs.storeTrialStartDate)
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

    private static func later(_ lhs: Date?, _ rhs: Date?) -> Date? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return max(lhs, rhs)
    }

    // MARK: - Public API

    /// Fast, synchronous read for the launch path. Reads the UserDefaults
    /// cache only — no keychain round trip, no I/O that could stall the
    /// first frame. Callers that need the authoritative answer use
    /// `resolve(wallClock:)`, which is safe to run after launch.
    static func cached() -> Record {
        readDefaults().storedRecord ?? .empty
    }

    /// Merges every tier, writes the result back to the tiers that differ,
    /// and returns it. This is the authoritative read. It touches the
    /// keychain, so it belongs off the synchronous launch path —
    /// `StoreKitManager.boot()` calls it after the first frame paints. The
    /// launch gate gets the same promotion from `recordHistoryCheck`, which
    /// `StoreKitManager.grandfatherExistingUserIfNeeded` runs on every
    /// non-Debug launch before the gate reads the anchor.
    @discardableResult
    static func resolve(wallClock: Date) -> Record {
        update(wallClock: wallClock) { $0 }.updated
    }

    /// Records — permanently — that this Apple ID is a beta tester.
    ///
    /// Called ONLY when migrating the legacy TestFlight flag an earlier build
    /// stored. It is deliberately never called from `isDeveloperInstall` (DEBUG builds and
    /// Apple-verified Xcode installs): a developer install is not a beta
    /// tester, and recording one would stamp a permanent free entitlement
    /// onto that Apple ID for the App Store build.
    @discardableResult
    static func recordBetaTester(wallClock: Date) -> Record {
        let result = update(wallClock: wallClock) { record in
            var marked = record
            marked.isBetaTester = true
            return marked
        }
        if !result.resolved.isBetaTester {
            debugLog("[Entitlement] beta tester recorded — grandfathered permanently", level: .info)
        }
        return result.updated
    }

    /// Persists `evaluatedHistory` for this launch's look at the device.
    @discardableResult
    static func recordHistoryCheck(hasHistory: Bool, wallClock: Date) -> Record {
        let result = update(wallClock: wallClock) { evaluatedHistory($0, hasHistory: hasHistory, wallClock: wallClock) }
        if result.updated.isBetaTester, !result.resolved.isBetaTester {
            debugLog("[Entitlement] existing history found at first launch — grandfathered as a beta tester", level: .info)
        }
        return result.updated
    }

    /// Adopts a device trial start. Keeps the earlier of the two, so this can
    /// only ever shorten a trial kept without the App Store's record, never
    /// extend it. Its one caller, `SettingsManager.adoptTrialStart`, reaches
    /// it only when the start it was given is earlier than the anchor's (it
    /// mirrors the anchor's own start otherwise); today that start is the App
    /// Store's, already recorded by `recordStoreTrialStart`. The App Store's
    /// own start goes through `recordStoreTrialStart` instead.
    ///
    /// The start is also a moment time has provably reached, so the high-water
    /// mark moves up to it. Without that, a new phone whose clock is set before
    /// the trial began — iCloud Keychain off, so no mark came with it — read
    /// the elapsed time as zero and showed a full trial for as long as the
    /// clock stayed back.
    static func adoptTrialStart(_ candidate: Date?, wallClock: Date) {
        guard let candidate else { return }
        update(wallClock: wallClock) { adopting($0, trialStart: candidate) }
    }

    /// `record` with `candidate` adopted as the device's trial start: the
    /// earlier start kept, and the high-water mark moved up to the candidate.
    static func adopting(_ record: Record, trialStart candidate: Date) -> Record {
        var updated = advanced(record, to: candidate)
        updated.deviceTrialStartDate = earlier(record.deviceTrialStartDate, candidate)
        return updated
    }

    /// Records the purchase date of the signed-in Apple ID's free-trial
    /// transaction as the trial start. The App Store keeps one trial per
    /// Apple ID and redelivers the same transaction after a reinstall or on a
    /// new phone, so its date cannot be restarted from this device, and it
    /// replaces any start an earlier build kept here: a trial bought now
    /// grants the thirty days its terms promise.
    static func recordStoreTrialStart(_ start: Date, wallClock: Date) {
        update(wallClock: wallClock) { recordingStoreTrialStart($0, start: start) }
    }

    /// `record` with `start` as the App Store's trial start, and the
    /// high-water mark moved up to it: the start is a moment time has
    /// provably reached.
    static func recordingStoreTrialStart(_ record: Record, start: Date) -> Record {
        var updated = advanced(record, to: start)
        updated.storeTrialStartDate = start
        return updated
    }

    // MARK: - Persistence fan-out

    /// What one stored copy held.
    private enum TierRead: Equatable {
        case absent
        case record(Record)
        /// Present but undecodable (a newer build's schema, corruption) or
        /// not readable right now. Never written over.
        case unreadable

        var storedRecord: Record? {
            if case let .record(stored) = self { return stored }
            return nil
        }
    }

    /// Every tier as read at the start of one update.
    private struct Tiers {
        let defaults: TierRead
        /// All keychain items of the service, merged.
        let keychain: Record?
        /// This install's own keychain item, the only one written.
        let ownKeychain: TierRead
    }

    /// Reads every tier, merges them, advances the high-water mark, applies
    /// `change`, and writes the result to each tier that holds something
    /// different and is not unreadable. Returns the merged record before
    /// `change` and the result after it.
    @discardableResult
    private static func update(wallClock: Date, _ change: (Record) -> Record) -> (resolved: Record, updated: Record) {
        let tiers = readTiers()
        let resolved = advanced(merged(tiers.defaults.storedRecord, tiers.keychain) ?? .empty, to: wallClock)
        let updated = change(resolved)
        if tiers.defaults != .record(updated), tiers.defaults != .unreadable { saveToDefaults(updated) }
        if tiers.ownKeychain != .record(updated), tiers.ownKeychain != .unreadable { saveToKeychain(updated) }
        return (resolved, updated)
    }

    private static func readTiers() -> Tiers {
        let keychain = loadFromKeychain()
        return Tiers(defaults: readDefaults(), keychain: keychain.merged, ownKeychain: keychain.own)
    }

    // MARK: - Tier 1: UserDefaults (fast cache)

    private static let defaultsKey = "entitlement.anchor.v1"

    private static func readDefaults() -> TierRead {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return .absent }
        return decode(data).map { TierRead.record($0) } ?? .unreadable
    }

    private static func saveToDefaults(_ record: Record) {
        guard let data = encode(record) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    // MARK: - Tier 2: Keychain (durable, iCloud-synced)

    private static let keychainService = "com.chrissharp.flowrecovery.entitlement"

    /// UserDefaults key holding this install's keychain account name.
    private static let accountDefaultsKey = "entitlement.anchor.account"

    /// This install's own item. Created once per install; a reinstall (or a
    /// wipe that sweeps the key) starts a new one, and the old item is still
    /// read and merged.
    private static var ownKeychainAccount: String {
        if let stored = UserDefaults.standard.string(forKey: accountDefaultsKey) { return stored }
        let created = "install-" + UUID().uuidString
        UserDefaults.standard.set(created, forKey: accountDefaultsKey)
        return created
    }

    /// Every synchronizable item of the service, whatever its account.
    ///
    /// `kSecAttrSynchronizable: true` is what makes the items follow the
    /// Apple ID through iCloud Keychain. A synchronizable item CANNOT use a
    /// `...ThisDeviceOnly` accessibility class, which is why this uses
    /// `kSecAttrAccessibleAfterFirstUnlock` rather than the
    /// device-only variant `APIKeyStore` uses for provider API keys — those
    /// deliberately must not leave the device; this deliberately must.
    private static var keychainServiceQuery: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrSynchronizable: true
        ]
    }

    /// One item: the service query narrowed to `account`.
    private static func keychainQuery(account: String) -> [CFString: Any] {
        var query = keychainServiceQuery
        query[kSecAttrAccount] = account
        return query
    }

    /// Every item merged, and this install's own item as read. When the items
    /// cannot even be listed, nothing is known and the own item counts as
    /// unreadable, so nothing is written over it.
    private static func loadFromKeychain() -> (merged: Record?, own: TierRead) {
        guard let accounts = keychainAccounts() else { return (nil, .unreadable) }
        let own = ownKeychainAccount
        var combined: Record?
        var ownRead = TierRead.absent
        for account in accounts {
            let read = readKeychainItem(account: account)
            combined = merged(combined, read.storedRecord)
            if account == own { ownRead = read }
        }
        return (combined, ownRead)
    }

    /// The account names of every item of the service; [] when there is
    /// none, nil when the keychain could not be queried (logged).
    private static func keychainAccounts() -> [String]? {
        var query = keychainServiceQuery
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            debugLog("[Entitlement] keychain list failed (status \(status))", level: .warning)
            return nil
        }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private static func readKeychainItem(account: String) -> TierRead {
        var query = keychainQuery(account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .absent }
        guard status == errSecSuccess, let data = result as? Data else {
            debugLog("[Entitlement] keychain read failed (status \(status))", level: .warning)
            return .unreadable
        }
        return decode(data).map { TierRead.record($0) } ?? .unreadable
    }

    /// Writes this install's own item.
    private static func saveToKeychain(_ record: Record) {
        guard let data = encode(record) else { return }
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ]
        let query = keychainQuery(account: ownKeychainAccount)
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            debugLog("[Entitlement] keychain update failed (status \(updateStatus))", level: .warning)
            return
        }
        addToKeychain(attributes, query: query)
    }

    /// No existing item to update — insert one instead.
    private static func addToKeychain(_ attributes: [CFString: Any], query: [CFString: Any]) {
        var addQuery = query
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
            UserDefaults.standard.removeObject(forKey: accountDefaultsKey)
            SecItemDelete(keychainServiceQuery as CFDictionary)
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

    /// Whole days left in the trial, rounded UP so a user 29.2 days in is
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
