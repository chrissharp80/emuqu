import CloudKit
import Foundation
import UIKit

// Supporting types for CloudKit sync: the timeout error, the notification
// names, the serializer that funnels concurrent syncs into one at a time, and
// the separate settings-sync object.

enum SyncTimeoutError: Error, LocalizedError {
    case timedOut
    case stalled
    var errorDescription: String? {
        switch self {
        case .timedOut: "Sync operation timed out — will retry"
        case .stalled: "Sync stalled with no progress — will retry"
        }
    }
}

extension Notification.Name {
    /// Posted by `CloudKitSyncManager.pullRemoteChanges()` after
    /// a pull archives NEW sessions. `userInfo["sessionIds"]` carries an
    /// `[UUID]` of those sessions. `RRCollector` observes this and re-derives
    /// each one's HK-backed `sleepSnapshot` / `vitalsSnapshot` (stripped from
    /// CloudKit uploads per Guideline 5.1.3), bounded + low priority.
    static let cloudKitSnapshotBackfillNeeded =
        Notification.Name("flowRecoveryCloudKitSessionsNeedSnapshotBackfill")
}

/// Serializes async work across the `CloudKitSyncManager` surface. Each
/// `run { ... }` suspends until the previous invocation finishes, so
/// upload / delete / full-sync calls can't interleave at await points and
/// race on `state` mutations. Replaces the prior
/// `while isSyncOperationInFlight { Task.yield() }` busy-wait, which
/// pinned the main actor under contention.
///
/// The closure runs on the `MainActor` because `CloudKitSyncManager`
/// properties (state, syncState, settings) are all main-actor-isolated.
/// A plain `actor` would force cross-actor hops on every access.
@MainActor
final class SyncSerializer {
    @ObservationIgnored private var previous: Task<Void, Never> = Task {}

    func run(_ body: @escaping @MainActor () async -> Void) async {
        let previousTask = previous
        let newTask = Task { @MainActor [previousTask] in
            _ = await previousTask.value
            await body()
        }
        previous = newTask
        await newTask.value
    }
}

// MARK: - CloudKit Settings Sync
//
// Backs `UserSettings` up to the user's iCloud private DB on every
// settings change (debounced) and provides a one-shot restore that
// pulls the cloud copy back down. Lives in this file so we don't need
// to touch `project.pbxproj` to add a new compilation unit.
//
// The loss-of-data hole this guards against:
//   • Settings are stored as a single JSON file at
//     `<AppGroup>/user_settings.json` with `URLFileProtection.complete`.
//   • A Watch-triggered background launch while the device is locked
//     hits `init()`, the load fails silently, defaults are kept, and
//     the next save() overwrites the real file. The user re-inputs
//     everything from scratch.
// `SettingsManager` distinguishes "file missing" from "file
// locked" and refuses to save over the locked case (see
// `SettingsManager.LoadOutcome`). This sync layer is the second leg:
// even if a save did slip through, the cloud copy is recoverable.
//
// Schema
//   • Zone: "UserSettings" (separate from the HRVSession zone so a
//     sessions-only fault recovery doesn't drag settings along).
//   • Record type: "UserSettings".
//   • Single record with fixed name "primary"; last-writer-wins.
//   • Fields:
//       - `settingsJSON`  String — full Codable encoding
//       - `modifiedAt`    Date — for "last synced" UI
//       - `deviceName`    String — diagnostic, helps the user identify
//         which device wrote the most recent copy

@Observable

@MainActor
final class CloudKitSettingsSync {
    static let shared = CloudKitSettingsSync()

    enum Status: Equatable {
        case idle
        case syncing
        case lastPushed(Date)
        case error(String)
    }

    private(set) var status: Status = .idle

    private let container = CKContainer(identifier: AppConfig.iCloudContainerIdentifier)
    var privateDB: CKDatabase { container.privateCloudDatabase }
    let recordType = "UserSettings"
    let zoneID = CKRecordZone.ID(zoneName: "UserSettings", ownerName: CKCurrentUserDefaultName)
    private let recordName = "primary"

    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var changeObserver: NSObjectProtocol?
    private var zoneEnsured = false
    /// Sticky per-launch flag. Set when the UserSettings record type isn't
    /// in production schema yet — same retry-storm protection as
    /// `CloudKitSyncManager.schemaUnavailable`, applied to the settings
    /// sync path. Without this, every `.flowRecoverySettingsChanged`
    /// notification keeps re-arming the debounce → another doomed push.
    private var schemaUnavailable = false

    private init() {
        // Listen to the same notification SettingsManager fires on every
        // change. Debounce so a flurry of edits (e.g. user rapidly
        // toggling a row) collapses into one push.
        changeObserver = NotificationCenter.default.addObserver(
            forName: .flowRecoverySettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleDebouncedPush() }
        }
    }

    /// Push the current settings now, without debounce. Called by the
    /// app-launch hook so the cloud copy stays current even when the
    /// user only adjusts settings on one device per session.
    func pushImmediately() async {
        await performPush()
    }

    /// Pull the cloud copy down and overlay it onto the local settings
    /// file. Returns the modification timestamp from the cloud record
    /// on success so the UI can confirm "Restored from iCloud (April
    /// 27)". Throws when no cloud record exists, or when iCloud is
    /// unreachable.
    func restoreFromCloud() async throws -> Date {
        try await ensureZoneExists()
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        let record: CKRecord
        do {
            record = try await privateDB.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            throw RestoreError.noCloudCopy
        }
        guard let json = record["settingsJSON"] as? String,
              let data = json.data(using: .utf8)
        else {
            throw RestoreError.cloudCopyMalformed
        }
        try AppDependencies.current.app.settingsManager.restoreFromJSON(data)
        let modifiedAt = (record["modifiedAt"] as? Date) ?? Date()
        return modifiedAt
    }

    enum RestoreError: LocalizedError {
        case noCloudCopy
        case cloudCopyMalformed

        var errorDescription: String? {
            switch self {
            case .noCloudCopy:
                "No iCloud backup found. Settings haven't been pushed yet from this Apple ID."
            case .cloudCopyMalformed:
                "iCloud backup couldn't be read — the record exists but its payload is unexpected."
            }
        }
    }

    /// 2-second debounce. Long enough to coalesce rapid edits in the
    /// settings UI, short enough that the user can change something
    /// and tap "Sync now" without seeing a stale state.
    private func scheduleDebouncedPush() {
        guard !schemaUnavailable else { return }
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            await sleepQuietly(2_000_000_000, context: "scheduleDebouncedPush")
            if Task.isCancelled { return }
            await self?.performPush()
        }
    }

    /// On `.serverRecordChanged`, another device wrote a newer record between
    /// our fetch and save. Last-writer-wins for settings is fine — re-fetch on
    /// the next change and overwrite then. No retry here, so we don't fight
    /// the other device.
    ///
    /// A local load failure (e.g. file protection blocking) MUST skip the
    /// push — pushing the in-memory defaults would clobber the cloud copy with
    /// whatever placeholder values the app booted with.
    private func performPush() async {
        guard AppDependencies.current.app.settingsManager.settings.iCloudSyncEnabled else { return }
        guard !schemaUnavailable else { return }
        guard let json = AppDependencies.current.app.settingsManager.currentSettingsJSON() else {
            debugLog("[CloudKitSettings] skipping push — local settings file isn't fully loaded yet", level: .warning)
            return
        }
        guard let jsonString = String(data: json, encoding: .utf8) else { return }
        status = .syncing
        do {
            try await ensureZoneExists()
            try await saveSettingsRecord(jsonString)
            status = .lastPushed(Date())
            debugLog("[CloudKitSettings] settings pushed (\(jsonString.count) bytes)")
        } catch let error as CKError where error.code == .serverRecordChanged {
            debugLog("[CloudKitSettings] push conflict (server has newer copy); will retry on next change", level: .warning)
            status = .idle
        } catch {
            handlePushFailure(error)
        }
    }

    private func saveSettingsRecord(_ jsonString: String) async throws {
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        let record: CKRecord
        do {
            record = try await privateDB.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: recordType, recordID: recordID)
        }
        record["settingsJSON"] = jsonString as CKRecordValue
        record["modifiedAt"] = Date() as CKRecordValue
        record["deviceName"] = UIDevice.current.name as CKRecordValue
        try await privateDB.save(record)
    }

    /// A permanent schema error means the CloudKit UserSettings record type
    /// hasn't been promoted to production. Cancel the debounce so we don't
    /// fire again every 2 s on every settings tweak.
    private func handlePushFailure(_ error: Error) {
        guard !CloudKitSyncManager.isPermanentSchemaError(error) else {
            schemaUnavailable = true
            debounceTask?.cancel()
            debugLog("[CloudKitSettings] push failed — schema not in production, suspending settings sync this launch", level: .error)
            status = .error("iCloud settings backup paused (schema not deployed)")
            return
        }
        debugLog("[CloudKitSettings] push failed: \(error.localizedDescription)", level: .warning)
        status = .error(error.localizedDescription)
    }

    private func ensureZoneExists() async throws {
        guard !zoneEnsured else { return }
        let zone = CKRecordZone(zoneID: zoneID)
        do {
            try await privateDB.save(zone)
            zoneEnsured = true
        } catch let error as CKError where error.code == .serverRejectedRequest {
            // Zone already exists — same accept-as-success semantics
            // CloudKitSyncManager.ensureZoneExists() uses.
            zoneEnsured = true
        }
    }
}
