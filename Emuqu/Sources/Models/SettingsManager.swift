import Foundation
import os
import UIKit

// Holds the SettingsManager singleton plus its persistence and lifecycle code.
// UserSettings (the value type) lives in UserSettings.swift.

// MARK: - Settings Manager

@Observable
@MainActor

final class SettingsManager {
    // `nonisolated(unsafe)` so `SettingsManager.shared` can be
    // reached from nonisolated contexts (report generators, static tables)
    // without a main-actor-isolation warning. Created once via thread-safe
    // static-let init; the shared reference itself is what these sites need.
    nonisolated static let shared = SettingsManager()

    var settings: UserSettings {
        didSet {
            let snapshot = settings
            snapshotBox.withLock { $0 = snapshot }
            // Refuse to persist over a load that failed silently — that
            // would replace the user's real settings with the in-memory
            // defaults. See `loadOutcome` and `init` below for the rationale.
            // (A crash + re-launch sequence once stamped fresh
            // defaults onto the file because `init` had no way to tell
            // "file missing" from "file unreadable.")
            guard loadOutcome != .blockedByProtection else {
                debugLog("[SettingsManager] settings change suppressed — load failed earlier and overwriting would clobber the real file. Will retry once the file becomes readable.", level: .warning)
                return
            }
            save()
            // Tell any cache / derived-state holder that the user just
            // changed something. AssistantContextSource listens so the AI
            // sees the new Max HR / units preference / training-break state
            // on the very next send instead of after the 60 s cache TTL.
            NotificationCenter.default.post(name: .flowRecoverySettingsChanged, object: nil)
        }
    }

    /// Outcome of the most recent `load(from:)` attempt. Drives the
    /// "don't clobber" guard above.
    enum LoadOutcome: Equatable {
        /// Loaded existing settings from disk.
        case loaded
        /// File doesn't exist yet — fresh install. Defaults are correct
        /// to persist.
        case fileNotPresent
        /// File exists but couldn't be read because iOS file protection
        /// was holding it inaccessible (typically: app launched in
        /// background while device was locked). Saving over this would
        /// destroy the user's real settings.
        case blockedByProtection
        /// File exists and was unreadable for a non-protection reason
        /// (corruption, schema mismatch). We continue with defaults but
        /// allow saves so the user can recover by reconfiguring.
        case unreadableOther
    }

    private(set) var loadOutcome: LoadOutcome = .fileNotPresent

    /// Lock-backed mirror of `settings` for readers off the main actor
    /// (analysis, export, and assistant code running on background tasks).
    nonisolated var settingsSnapshot: UserSettings { snapshotBox.withLock { $0 } }
    @ObservationIgnored private let snapshotBox: OSAllocatedUnfairLock<UserSettings>

    private let fileManager = FileManager.default
    private let settingsURL: URL

    // Off-main coalesced settings persistence. A `save()` that
    // does a full prettyPrinted JSON encode (including the base64 avatar) +
    // atomic disk write on the MAIN thread for EVERY `settings` mutation
    // stalls: slider drags fire `didSet` dozens of times per gesture, each
    // blocking the UI with disk I/O — "touching Settings hangs".
    // The heavy write is coalesced onto a utility queue (latest snapshot
    // wins); durability on app exit is guaranteed by
    // `flushPendingWritesSynchronously()` wired to background/terminate.
    private let settingsWriteQueue = DispatchQueue(label: "com.emuqu.settings.write", qos: .utility)
    private struct WriteState {
        var pending: UserSettings?
        var scheduled = false
    }
    @ObservationIgnored private let writeState = OSAllocatedUnfairLock(initialState: WriteState())

    nonisolated private init() {
        settingsURL = Self.resolveSettingsURL(fileManager: FileManager.default)
        let (loaded, outcome) = SettingsManager.load(from: settingsURL)
        _loadOutcome = outcome
        let initial = loaded ?? UserSettings()
        _settings = initial
        snapshotBox = OSAllocatedUnfairLock(initialState: initial)

        // If the load failed because the device was locked, watch for the
        // protected-data-unlock notification and try again. Once the user
        // unlocks, we can read the real settings and the "don't clobber" guard
        // lifts on its own.
        if outcome == .blockedByProtection {
            Task { @MainActor in self.installProtectedDataObserver() }
        }
        installDurabilityObservers()
    }

    /// App Group container — survives `app-uninstall + reinstall` cycles (which
    /// Xcode triggers on every build that changes the bundle structure). The
    /// Documents directory does NOT survive those cycles. When the
    /// file lived in Documents, a botched install / clean reinstall would
    /// silently wipe the user's max HR, weight, FTP, biological sex, sleep
    /// schedule, route library, email contacts — every preference.
    ///
    /// Migration: if a file exists in Documents but none in the App Group,
    /// copy it across and continue using the App Group path.
    nonisolated private static func resolveSettingsURL(fileManager: FileManager) -> URL {
        let appGroupURL = AppConfig.sharedContainerURL().appendingPathComponent("user_settings.json")
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("user_settings.json")
        guard !fileManager.fileExists(atPath: appGroupURL.path),
              let legacyURL = documentsURL,
              fileManager.fileExists(atPath: legacyURL.path)
        else { return appGroupURL }
        do {
            try fileManager.copyItem(at: legacyURL, to: appGroupURL)
            debugLog("[SettingsManager] Migrated user_settings.json from Documents → App Group container")
        } catch {
            debugLog("[SettingsManager] Migration copy failed (will continue with fresh defaults): \(error)")
        }
        return appGroupURL
    }

    /// Durability for the off-main coalesced write: flush any pending settings
    /// write synchronously before the app is suspended or killed, so a mutation
    /// made moments before backgrounding can't be lost.
    nonisolated private func installDurabilityObservers() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.flushPendingWritesSynchronously()
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.flushPendingWritesSynchronously()
        }
    }

    /// Returns both the parsed settings (or nil) and a structured
    /// reason — fileNotPresent, loaded, blockedByProtection, or
    /// unreadableOther — so the caller can decide whether saves are
    /// safe to issue.
    ///
    /// iOS file-protection blocks reads as NSCocoaErrorDomain /
    /// NSFileReadNoPermissionError (257). That is treated as "file is fine, we
    /// just can't see it yet". Anything else is a true read/decode failure and
    /// falls back to defaults, which we ARE willing to save over.
    nonisolated private static func load(from url: URL) -> (UserSettings?, LoadOutcome) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return (nil, .fileNotPresent) }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try decoder.decode(UserSettings.self, from: data), .loaded)
        } catch let nsError as NSError {
            let isProtection = nsError.domain == NSCocoaErrorDomain
                && nsError.code == NSFileReadNoPermissionError
            if isProtection {
                debugLog("[SettingsManager] settings file is locked (NSFileReadNoPermissionError) — will retry after the device unlocks", level: .warning)
                return (nil, .blockedByProtection)
            }
            debugLog("[SettingsManager] failed to load settings: \(nsError) — falling through to defaults", level: .warning)
            return (nil, .unreadableOther)
        }
    }

    /// Re-attempts the load when iOS posts `protectedDataDidBecomeAvailable`,
    /// then notifies observers if the on-disk settings differ from the
    /// in-memory defaults that were used while we were locked out.
    @ObservationIgnored private var protectedDataObserver: NSObjectProtocol?
    private func installProtectedDataObserver() {
        guard protectedDataObserver == nil else { return }
        protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The notification block is `nonisolated` even though `queue:
            // .main` schedules it on the main thread. Hop into the
            // MainActor explicitly so the Swift 6 isolation checker sees
            // the call to `retryLoadAfterUnlock()` lining up with its
            // `@MainActor` annotation.
            Task { @MainActor in self?.retryLoadAfterUnlock() }
        }
    }
    @MainActor
    private func retryLoadAfterUnlock() {
        let (loaded, outcome) = SettingsManager.load(from: settingsURL)
        loadOutcome = outcome
        if let loaded {
            // Replace in-memory defaults with the real on-disk settings. The
            // assignment runs `didSet`, which writes them back unchanged and
            // posts the settings-changed notification observers need.
            settings = loaded
            debugLog("[SettingsManager] real settings loaded after device unlock — \(loadOutcome) — guard lifted")
        }
        if let observer = protectedDataObserver {
            NotificationCenter.default.removeObserver(observer)
            protectedDataObserver = nil
        }
    }

    /// Reset every stored preference to a fresh-install state.
    ///
    /// "Delete All My Data" must not leave `user_settings.json`
    /// untouched, or age, body weight, resting HR, max HR, LTHR, FTP and the
    /// sleep schedule all survive an erasure request. Deleting the file alone
    /// would not fix it: this is a live `@MainActor` singleton and the
    /// next `save()` would rewrite the in-memory copy straight back. The
    /// in-memory state is the source of truth, so resetting it — and letting
    /// the `didSet` persist the defaults — is the only wipe that holds.
    func resetToDefaults() {
        settings = UserSettings()
        hasAcceptedDisclaimer = false
    }

    private func save() {
        // Mirror the perf flags into
        // UserDefaults so the heavy singletons (which can init before
        // SettingsManager.shared has read the JSON file from the App
        // Group container) can peek the master switches at startup.
        // Write-through: every settings save updates these mirror keys
        // so the next launch sees the fresh value.
        let defaults = UserDefaults.standard
        defaults.set(settings.enableAIAssistant, forKey: UserSettings.PerformanceFlagKey.enableAIAssistant.rawValue)
        defaults.set(settings.enableVoiceMode, forKey: UserSettings.PerformanceFlagKey.enableVoiceMode.rawValue)
        defaults.set(settings.enableWatchConnectivity, forKey: UserSettings.PerformanceFlagKey.enableWatchConnectivity.rawValue)

        // Hand the heavy encode + atomic disk write to the utility queue,
        // coalescing rapid mutations to the latest snapshot. Never blocks the
        // main thread. Durability guaranteed by `flushPendingWritesSynchronously()`.
        enqueueDiskWrite(settings)
    }

    /// Stash the latest settings snapshot and ensure a single background
    /// worker is draining it. Latest-wins: a burst of mutations collapses to
    /// one disk write of the final value.
    private func enqueueDiskWrite(_ snapshot: UserSettings) {
        let alreadyScheduled = writeState.withLock { state in
            state.pending = snapshot
            defer { state.scheduled = true }
            return state.scheduled
        }
        guard !alreadyScheduled else { return }
        settingsWriteQueue.async { [weak self] in self?.drainPendingWrites() }
    }

    /// Serial-queue worker. Writes the newest pending snapshot until none
    /// remain. Only ever runs on `settingsWriteQueue`, so writes can't
    /// interleave and there's no torn file.
    nonisolated private func drainPendingWrites() {
        while let snapshot = takePendingWrite() {
            writeSettingsToDisk(snapshot)
        }
    }

    /// Pops the latest pending snapshot, or clears `scheduled` and returns
    /// nil when the queue has drained.
    nonisolated private func takePendingWrite() -> UserSettings? {
        writeState.withLock { state in
            guard let snapshot = state.pending else {
                state.scheduled = false
                return nil
            }
            state.pending = nil
            return snapshot
        }
    }

    /// File protection is `.completeUntilFirstUserAuthentication`,
    /// not `.complete`. The stricter
    /// `.complete` level makes the file unreadable while the
    /// device is locked, so when iOS launches the app in
    /// background (Watch trigger, location event) before the
    /// user unlocks, `load()` fails and `init` defaults to
    /// a fresh `UserSettings`. That fresh default then
    /// overwrites the real file on the next save — the
    /// "fucked up my settings again" data loss.
    ///
    /// `.completeUntilFirstUserAuthentication` is iOS's default
    /// for files written without an explicit class. The file
    /// is encrypted at rest, accessible after the user unlocks
    /// the device once per boot, and stays accessible for
    /// background launches afterwards. Same on-disk encryption,
    /// dramatically better availability profile.
    nonisolated private func writeSettingsToDisk(_ snapshot: UserSettings) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: settingsURL, options: .atomic)
            try (settingsURL as NSURL).setResourceValue(
                URLFileProtection.completeUntilFirstUserAuthentication,
                forKey: .fileProtectionKey
            )
        } catch {
            debugLog("Failed to save settings: \(error)")
        }
    }

    /// Flush any pending settings write synchronously. Wired to
    /// `didEnterBackground` / `willTerminate` so a coalesced write is never
    /// lost when the process is suspended before the utility queue drains.
    /// Blocks the caller only for one final write, and only if one is pending.
    nonisolated func flushPendingWritesSynchronously() {
        settingsWriteQueue.sync {
            self.drainPendingWrites()
        }
    }

    /// Public access for the CloudKit sync helper — read-only export
    /// of the current on-disk settings file as raw JSON, suitable for
    /// pushing into a `CKRecord`. Returns nil when load failed (e.g.
    /// device locked) so the sync layer doesn't echo defaults to
    /// the cloud and overwrite the real backup.
    func currentSettingsJSON() -> Data? {
        guard loadOutcome == .loaded || loadOutcome == .fileNotPresent else { return nil }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return attempt("settings.encode") { try encoder.encode(settings) }
    }

    /// Replace the in-memory settings + on-disk file with a JSON blob
    /// fetched from CloudKit. Used by the cloud-restore action. Throws
    /// if decode fails so the caller can surface the error.
    @MainActor
    func restoreFromJSON(_ data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(UserSettings.self, from: data)
        // Lift any active protection guard — restoring is an explicit
        // user-initiated action that supersedes whatever local state
        // was wedged.
        loadOutcome = .loaded
        settings = restored
    }

    // MARK: - Custom Tag Management

    func addCustomTag(_ tag: ReadingTag) {
        guard !settings.customTags.contains(where: { $0.id == tag.id }) else { return }
        settings.customTags.append(tag)
    }

    func removeCustomTag(_ tag: ReadingTag) {
        settings.customTags.removeAll { $0.id == tag.id }
    }

    // MARK: - Disclaimer Acceptance (Device-Local)

    /// Whether the user has accepted the health disclaimer on this device.
    /// Stored in UserDefaults (NOT in the Codable settings JSON) so it is device-local
    /// and never synced via iCloud. A new device must show the disclaimer again.
    private static let disclaimerAcceptedKey = UserDefaultsKeys.disclaimerAccepted

    /// Bumped whenever the disclaimer flag is written, so observers of
    /// `hasAcceptedDisclaimer` — a UserDefaults read — re-evaluate.
    private var disclaimerRevision = 0

    var hasAcceptedDisclaimer: Bool {
        get {
            _ = disclaimerRevision
            return UserDefaults.standard.bool(forKey: SettingsManager.disclaimerAcceptedKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: SettingsManager.disclaimerAcceptedKey)
            disclaimerRevision += 1
        }
    }

    // MARK: - Baseline Management

    func updateBaseline(rmssd: Double?, hr: Double?) {
        if let rmssd {
            settings.baselineRMSSD = rmssd
        }
        if let hr {
            settings.baselineHR = hr
        }
    }

    func calculatePersonalBaseline(from sessions: [HRVSession]) {
        // Use morning readings from the last 7-14 days
        let calendar = Calendar.current
        let twoWeeksAgo = calendar.date(byAdding: .day, value: -14, to: Date()) ?? Date()
        let morningSessions = sessions.filter { session in
            session.state == .complete
                && session.startDate >= twoWeeksAgo
                && session.tags.contains(where: { $0.id == ReadingTag.morning.id })
        }
        guard morningSessions.count >= 3 else { return }
        let rmssdValues = morningSessions.compactMap(\.rmssd)
        let hrValues = morningSessions.compactMap(\.meanHR)
        if !rmssdValues.isEmpty {
            settings.baselineRMSSD = Self.geometricMean(of: rmssdValues)
        }
        if !hrValues.isEmpty {
            settings.baselineHR = hrValues.reduce(0, +) / Double(hrValues.count)
        }
    }

    /// GEOMETRIC mean (exp of mean-of-logs), matching
    /// BaselineTracker's canonical baseline. RMSSD is log-normal, so an
    /// arithmetic mean sits above the geometric one (Jensen); this
    /// fallback (used before BaselineTracker has 60 days) agrees in
    /// scale with the recovery/readiness baseline instead of reading high.
    /// Falls back to the arithmetic mean when nothing is positive.
    private static func geometricMean(of values: [Double]) -> Double {
        let lnValues = values.filter { $0 > 0 }.map { log($0) }
        guard !lnValues.isEmpty else {
            return values.reduce(0, +) / Double(values.count)
        }
        return exp(lnValues.reduce(0, +) / Double(lnValues.count))
    }

    // MARK: - Trial

    /// Trial length in days. `TrialPolicy` is the single source of truth;
    /// this stays as an alias so existing call sites keep reading naturally.
    nonisolated static var trialDurationDays: Int { TrialPolicy.durationDays }

    /// Days remaining in the free trial. Returns 0 if trial hasn't started or has expired.
    ///
    /// Reads `EntitlementAnchor` in preference to `settings`.
    /// `settings` lives in `user_settings.json` inside the App Group
    /// container, which is destroyed when the app is deleted; the anchor is
    /// a synchronizable keychain item, which is not. Reinstalling therefore
    /// resumes the original trial instead of granting a fresh one.
    /// `settings.trialStartDate` is still maintained as a CloudKit-backed
    /// mirror and remains the fallback when the anchor is empty.
    var trialDaysRemaining: Int {
        let anchor = EntitlementAnchor.cached()
        let start = anchor.trialStartDate ?? settings.trialStartDate
        let now = EntitlementAnchor.effectiveNow(anchor, wallClock: Date())
        return TrialPolicy.daysRemaining(start: start, now: now)
    }

    /// Whether the user is currently within the trial period.
    var isInTrialPeriod: Bool {
        trialDaysRemaining > 0
    }

    /// Adopts a trial start proven by the App Store: the purchase date of the
    /// free trial in-app purchase. That transaction follows the Apple ID
    /// through every reinstall and device, so it is the strongest copy of the
    /// clock there is. Like every other source, it can only move the start
    /// earlier. Mirrored into settings so CloudKit carries a second copy.
    func adoptTrialStart(_ start: Date) {
        if let current = EntitlementAnchor.cached().trialStartDate, current <= start {
            mirrorTrialStart(current)
            return
        }
        EntitlementAnchor.adoptTrialStart(start, wallClock: Date())
        mirrorTrialStart(EntitlementAnchor.cached().trialStartDate)
    }

    private func mirrorTrialStart(_ start: Date?) {
        guard let start, settings.trialStartDate != start else { return }
        settings.trialStartDate = start
    }

    /// Record that the daily trial reminder was shown (device-local, UserDefaults).
    func recordTrialReminderShown() {
        UserDefaults.standard.set(Date(), forKey: UserDefaultsKeys.lastTrialReminderDate)
    }

    /// Whether the trial reminder has already been shown today.
    var hasShownTrialReminderToday: Bool {
        guard let last = UserDefaults.standard.object(forKey: UserDefaultsKeys.lastTrialReminderDate) as? Date else {
            return false
        }
        return Calendar.current.isDateInToday(last)
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted every time `SettingsManager.settings` is mutated. Listeners
    /// that cache derived data (AssistantContextSource, trend views) can
    /// drop their caches so the user's next interaction sees the new value.
    static let flowRecoverySettingsChanged = Notification.Name("FlowRecoverySettingsChanged")
}
