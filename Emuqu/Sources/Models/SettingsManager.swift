import Foundation
import os
import UIKit

// Holds the SettingsManager singleton plus its persistence and lifecycle code.
// UserSettings (the value type) lives in UserSettings.swift.

// MARK: - Settings Manager

@Observable
@MainActor

final class SettingsManager {
    // `nonisolated` so `SettingsManager.shared` can be reached from
    // nonisolated contexts (report generators, static tables) without a
    // main-actor-isolation warning. Created once via thread-safe static-let
    // init; the shared reference itself is what these sites need.
    nonisolated static let shared = SettingsManager()

    var settings: UserSettings {
        didSet {
            let snapshot = settings
            snapshotBox.withLock { $0 = snapshot }
            saveUnlessLocked()
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
        /// (corruption, schema mismatch). A copy is kept beside it
        /// (`unreadableBackupName`) and we continue with defaults, allowing
        /// saves so the user can recover by reconfiguring.
        case unreadableOther
        /// As `unreadableOther`, but the copy could not be made, so the file
        /// is the only copy of the user's settings. Saves are held as for
        /// `blockedByProtection`, and each change tries the copy again
        /// (`saveUnlessLocked`).
        case unreadableNotPreserved
    }

    /// Whether saving would write over a file this launch could not read and
    /// has no copy of: changes are held in memory meanwhile.
    private var savesHeld: Bool {
        loadOutcome == .blockedByProtection || loadOutcome == .unreadableNotPreserved
    }

    private(set) var loadOutcome: LoadOutcome = .fileNotPresent

    /// The in-memory settings the app started from while saves were held
    /// (nil otherwise). Changes made while locked are the fields that differ
    /// from it, and those are merged onto the file's settings once it can be
    /// read, instead of being discarded.
    @ObservationIgnored private var lockedStartingPoint: UserSettings?

    /// The copy `load(from:)` keeps of a settings file it could not read for
    /// a reason other than file protection, beside the file.
    nonisolated static let unreadableBackupName = "user_settings.unreadable.json"

    /// Lock-backed mirror of `settings` for readers off the main actor
    /// (analysis, export, and assistant code running on background tasks).
    nonisolated var settingsSnapshot: UserSettings { snapshotBox.withLock { $0 } }
    @ObservationIgnored private let snapshotBox: OSAllocatedUnfairLock<UserSettings>

    private let fileManager = FileManager.default
    /// The settings file this instance reads and writes: the App Group copy,
    /// or the Documents file while the migration copy keeps failing.
    /// Delete All My Data keeps this one file through its sweep.
    let settingsURL: URL

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
        lockedStartingPoint = outcome == .blockedByProtection || outcome == .unreadableNotPreserved ? initial : nil
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

    /// The settings file lives in the App Group container. Like Documents,
    /// the container is deleted with the app, so a reinstall starts from
    /// defaults until the CloudKit settings pull restores the synced values.
    ///
    /// Migration: if a file exists in Documents but none in the App Group,
    /// copy it across and continue using the App Group path; the Documents
    /// original is deleted once the copy reads back the same
    /// (`removeMigratedLegacyFile`). When the copy fails the Documents file
    /// stays in use for this launch, so the user's settings are read and saved
    /// there and the copy is tried again next launch; starting on defaults
    /// would create the App Group file on the first change and abandon the
    /// Documents settings for good.
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
            removeMigratedLegacyFile(legacyURL, copiedTo: appGroupURL, fileManager: fileManager)
            return appGroupURL
        } catch {
            debugLog("[SettingsManager] Migration copy failed (staying on the Documents file, retrying next launch): \(error)", level: .warning)
            return legacyURL
        }
    }

    /// Deletes the Documents original once its App Group copy reads back
    /// byte for byte the same. Nothing reads the original again, and left in
    /// place it was a second copy of the profile on disk. When either read
    /// fails or they differ, the original stays; Delete All My Data still
    /// removes it, as it is not the file in use.
    nonisolated private static func removeMigratedLegacyFile(_ legacyURL: URL, copiedTo copyURL: URL, fileManager: FileManager) {
        do {
            guard try Data(contentsOf: copyURL) == Data(contentsOf: legacyURL) else {
                debugLog("[SettingsManager] migrated copy differs from the Documents original — keeping the original", level: .warning)
                return
            }
            try fileManager.removeItem(at: legacyURL)
        } catch {
            debugLog("[SettingsManager] could not remove the migrated Documents settings file: \(error)", level: .warning)
        }
    }

    /// Durability for the off-main coalesced write: flush any pending settings
    /// write synchronously before the app is suspended or killed, so a mutation
    /// made moments before backgrounding can't be lost.
    nonisolated private func installDurabilityObservers() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { [weak self] _ in
            _ = self?.flushPendingWritesSynchronously()
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            _ = self?.flushPendingWritesSynchronously()
        }
    }

    /// Returns both the parsed settings (or nil) and a structured
    /// reason — fileNotPresent, loaded, blockedByProtection,
    /// unreadableOther or unreadableNotPreserved — so the caller can decide
    /// whether saves are safe to issue.
    ///
    /// iOS file-protection blocks reads as NSCocoaErrorDomain /
    /// NSFileReadNoPermissionError (257). That is treated as "file is fine, we
    /// just can't see it yet". Anything else is a true read/decode failure and
    /// falls back to defaults, which we are willing to save over once a copy
    /// of the file is kept.
    nonisolated static func load(from url: URL) -> (UserSettings?, LoadOutcome) {
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
            return (nil, preserveUnreadableFile(at: url) ? .unreadableOther : .unreadableNotPreserved)
        }
    }

    /// Keeps a copy of a settings file that exists but cannot be read, beside
    /// it as `unreadableBackupName`, before the first change saves defaults
    /// over it. The copy is made under a temporary name and then replaces an
    /// older copy, so a copy that fails never costs the older one. Returns
    /// whether the file may be written over: copied, or no longer there.
    nonisolated static func preserveUnreadableFile(at url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return true }
        let backup = url.deletingLastPathComponent().appendingPathComponent(unreadableBackupName)
        let staged = backup.appendingPathExtension("partial")
        do {
            if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
            try fm.copyItem(at: url, to: staged)
            if fm.fileExists(atPath: backup.path) {
                _ = try fm.replaceItemAt(backup, withItemAt: staged)
            } else {
                try fm.moveItem(at: staged, to: backup)
            }
            debugLog("[SettingsManager] kept the unreadable settings file as \(unreadableBackupName)", level: .warning)
            return true
        } catch {
            debugLog("[SettingsManager] could not keep a copy of the unreadable settings file — saves held so it is not written over: \(error)", level: .error)
            return false
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
    /// While the file is still locked the observer stays, so the next
    /// unlock tries again. A file that turns out unreadable with no copy
    /// kept keeps the changes held in memory, as `saveUnlessLocked` does.
    @MainActor
    private func retryLoadAfterUnlock() {
        let (loaded, outcome) = SettingsManager.load(from: settingsURL)
        guard outcome != .blockedByProtection else {
            debugLog("[SettingsManager] settings file still locked after unlock — will retry on the next unlock", level: .warning)
            return
        }
        removeProtectedDataObserver()
        loadOutcome = outcome
        guard outcome != .unreadableNotPreserved else {
            debugLog("[SettingsManager] settings file unreadable after unlock and no copy could be kept — changes stay held; the next change tries the copy again", level: .warning)
            return
        }
        adoptAfterUnlock(loaded)
    }

    /// The end of `retryLoadAfterUnlock` once saves may resume: the settings
    /// read from the file with every change made while locked merged in, or,
    /// when the file is gone or unreadable with a copy kept, the in-memory
    /// settings saved as they are.
    private func adoptAfterUnlock(_ loaded: UserSettings?) {
        let startingPoint = lockedStartingPoint
        lockedStartingPoint = nil
        if let loaded {
            // The real on-disk settings, keeping every field changed while
            // locked. `didSet` saves the result and posts the notification.
            settings = startingPoint.map { Self.merging(changesFrom: $0, to: settings, onto: loaded) } ?? loaded
            debugLog("[SettingsManager] real settings loaded after device unlock — \(loadOutcome) — guard lifted")
        } else {
            // Gone or unreadable (a copy kept) after all: saves are allowed,
            // so the changes made while locked are written now.
            save()
        }
    }

    private func removeProtectedDataObserver() {
        guard let observer = protectedDataObserver else { return }
        NotificationCenter.default.removeObserver(observer)
        protectedDataObserver = nil
    }

    /// `disk` with every top-level field that `changed` holds differently
    /// from `base` taken from `changed` (a field cleared in `changed` is
    /// cleared). Compared and merged as JSON, so it covers every field
    /// `UserSettings` encodes. Falls back to `disk` if the merge cannot be
    /// encoded or decoded.
    nonisolated static func merging(
        changesFrom base: UserSettings, to changed: UserSettings, onto disk: UserSettings
    ) -> UserSettings {
        do {
            let before = try jsonFields(base)
            let after = try jsonFields(changed)
            var merged = try jsonFields(disk)
            for key in Set(before.keys).union(after.keys) where (before[key] as? NSObject) != (after[key] as? NSObject) {
                merged[key] = after[key]
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(UserSettings.self, from: try JSONSerialization.data(withJSONObject: merged))
        } catch {
            debugLog("[SettingsManager] could not merge settings changed while the file was locked: \(error) — keeping the file's settings", level: .warning)
            return disk
        }
    }

    /// The settings' top-level JSON fields, encoded as they are saved.
    nonisolated private static func jsonFields(_ settings: UserSettings) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let object = try JSONSerialization.jsonObject(with: try encoder.encode(settings))
        guard let fields = object as? [String: Any] else { throw CocoaError(.coderReadCorrupt) }
        return fields
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
    ///
    /// While saves are held (the file is locked, or unreadable with no copy
    /// kept) the guard would suppress that save, so the held file is deleted
    /// instead (removing a file does not need to read it) and the pending
    /// unlock retry is dropped, so it cannot load the erased settings back.
    /// The copy kept of an unreadable file goes too.
    func resetToDefaults() {
        if savesHeld {
            Self.removeFile(at: settingsURL, what: "settings file saves were held for")
            loadOutcome = .fileNotPresent
            lockedStartingPoint = nil
            removeProtectedDataObserver()
        }
        Self.removeFile(at: settingsURL.deletingLastPathComponent().appendingPathComponent(Self.unreadableBackupName), what: "unreadable settings copy")
        settings = UserSettings()
        hasAcceptedDisclaimer = false
    }

    /// Deletes a settings file if it exists, logging a failure.
    nonisolated private static func removeFile(at url: URL, what: String) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            debugLog("[SettingsManager] could not delete the \(what): \(error)", level: .error)
        }
    }

    /// Refuse to persist over a load that failed silently — that would
    /// replace the user's real settings with the in-memory defaults. See
    /// `loadOutcome` and `init` for the rationale. (A crash + re-launch
    /// sequence once stamped fresh defaults onto the file because `init` had
    /// no way to tell "file missing" from "file unreadable.") The change is
    /// kept in memory and merged onto the real file once it can be read
    /// (`retryLoadAfterUnlock`). A file that could not be read for another
    /// reason and has no copy is copied first; once that succeeds the held
    /// changes are saved, and until then they stay in memory.
    private func saveUnlessLocked() {
        switch loadOutcome {
        case .blockedByProtection:
            debugLog("[SettingsManager] settings change not saved yet — the file is locked and overwriting it would clobber the real settings. It is merged in once the file becomes readable.", level: .warning)
            return
        case .unreadableNotPreserved:
            guard Self.preserveUnreadableFile(at: settingsURL) else {
                debugLog("[SettingsManager] settings change not saved yet — the unreadable settings file has no copy, and overwriting it would lose it", level: .warning)
                return
            }
            loadOutcome = .unreadableOther
            lockedStartingPoint = nil
        case .loaded, .fileNotPresent, .unreadableOther:
            break
        }
        save()
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

    /// Writes any pending settings change now, on the caller's thread, and
    /// reports whether the file then holds `expected`. Both sides are compared
    /// as `load(from:)` reads them, so a field the decoder fills in (the
    /// schema version) is not a difference. Throws the last write's error, or
    /// the read or decode error. Delete All My Data checks with it that the
    /// reset profile reached disk.
    func flushedFileHolds(_ expected: UserSettings) throws -> Bool {
        if let failure = flushPendingWritesSynchronously() { throw failure }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let onDisk = try decoder.decode(UserSettings.self, from: Data(contentsOf: settingsURL))
        return try onDisk == decoder.decode(UserSettings.self, from: encoder.encode(expected))
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
        settingsWriteQueue.async { [weak self] in _ = self?.drainPendingWrites() }
    }

    /// Serial-queue worker. Writes the newest pending snapshot until none
    /// remain. Only ever runs on `settingsWriteQueue`, so writes can't
    /// interleave and there's no torn file. Returns the error of the last
    /// write it made: nil when that write succeeded or nothing was pending.
    nonisolated private func drainPendingWrites() -> (any Error)? {
        var lastFailure: (any Error)?
        while let snapshot = takePendingWrite() {
            lastFailure = writeSettingsToDisk(snapshot)
        }
        return lastFailure
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
    ///
    /// Returns the error when the encode, write or protection change failed
    /// (logged here too), nil when the file was written.
    nonisolated private func writeSettingsToDisk(_ snapshot: UserSettings) -> (any Error)? {
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
            return nil
        } catch {
            debugLog("[SettingsManager] Failed to save settings: \(error)", level: .error)
            return error
        }
    }

    /// Flush any pending settings write synchronously. Wired to
    /// `didEnterBackground` / `willTerminate` so a coalesced write is never
    /// lost when the process is suspended before the utility queue drains.
    /// Blocks the caller only for one final write, and only if one is pending.
    /// Returns that write's error, nil when it succeeded or none was pending.
    nonisolated func flushPendingWritesSynchronously() -> (any Error)? {
        settingsWriteQueue.sync {
            self.drainPendingWrites()
        }
    }

    /// Public access for the CloudKit sync helper — the in-memory settings
    /// encoded as JSON the way they are saved, suitable for pushing into a
    /// `CKRecord`. Returns nil unless the file loaded or did not exist: when
    /// it was locked or unreadable the in-memory settings started from
    /// defaults, and pushing them would overwrite the cloud copy, which is
    /// how the user gets their real settings back.
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
        lockedStartingPoint = nil
        settings = restored
        // The restored copy carries the synced mirror of the trial start; the
        // anchor adopts it (keeping the earlier start) and the resolved start
        // is mirrored back.
        if let trialStart = restored.trialStartDate { adoptTrialStart(trialStart) }
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

    /// Mirrors the trial clock into settings so CloudKit carries a second
    /// copy. StoreKitManager records the App Store's trial start in the
    /// anchor first, where it replaces any start an earlier build kept, so
    /// for it this only mirrors that date. A start from anywhere else — the
    /// synced mirror `restoreFromJSON` brings back from iCloud — is adopted
    /// as a device start, which can only move earlier.
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
