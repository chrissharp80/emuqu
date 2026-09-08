import CloudKit
import Foundation

// The remote-deletion path (GDPR / App Store), split out of
// `CloudKitSyncManager.swift` to keep that type under the 500-line
// body ceiling. Wiping every custom zone this app writes removes every remote
// record it has ever created.

extension CloudDeletionCoordinator {
    // MARK: - Remote Deletion (GDPR / App Store)

    /// Every custom zone this app writes to the private database. Deleting
    /// these removes every remote record the app has ever created:
    ///   • "HRVSessions" — HRVSession records AND the "RawBackup"
    ///     live-recording backups (`CloudKitLiveBackupManager` shares this
    ///     zone).
    ///   • "UserSettings" — the `CloudKitSettingsSync` "primary" record.
    private var allCustomZoneIDs: [CKRecordZone.ID] {
        [
            manager.zoneID,
            CKRecordZone.ID(zoneName: "UserSettings", ownerName: CKCurrentUserDefaultName)
        ]
    }

    /// Delete ALL of this app's data from the user's private CloudKit
    /// database by deleting the custom zones outright (zone deletion
    /// removes every record inside, server-side, in one round-trip).
    /// Called by the "Delete All My Data" purge flow (GDPR Art. 17 /
    /// App Store — the flow must offer true remote deletion, not
    /// just local-state reset).
    ///
    /// Deliberately NOT guarded on `iCloudSyncEnabled` — a user who synced
    /// in the past and has since turned sync OFF still has remote records
    /// to remove, and they're asking us to delete them. Also NOT guarded
    /// on `schemaUnavailable` — that flag means record *types* are missing
    /// from the production schema; zone deletion is still valid, and a
    /// zone that doesn't exist counts as success below.
    ///
    /// Serialized via `syncSerializer` so it cannot interleave with an
    /// in-flight push/pull (which could otherwise recreate the zone
    /// mid-deletion via `ensureZoneExists`/`recreateZoneAfterNotFound`).
    ///
    /// On success: resets local sync state, clears the sanitize-drip
    /// bookkeeping (a future re-enable must start clean — those record
    /// ids no longer exist remotely), and returns true. On failure:
    /// logs and returns false; the caller surfaces "retry on network".
    func deleteAllRemoteData() async -> Bool {
        var deleted = false
        await manager.syncSerializer.run { [self] in
            deleted = await performDeleteAllRemoteData()
        }
        return deleted
    }

    /// The remote wipe caps its round-trip with the same timeout race the
    /// full-sync body uses — a wedged CloudKit call here would otherwise pin
    /// the purge UI forever AND block the local wipe that runs after this
    /// returns (the local wipe must proceed regardless of network). 30 s
    /// covers a slow single zone-modify operation; anything longer is hung and
    /// surfaces as "retry on network".
    ///
    /// Once the wipe lands (or nothing existed), local bookkeeping is reset so
    /// a future re-enable starts from scratch. `resetLocalSyncState` also
    /// clears `zoneCreated` and sets `syncState = .idle`, so the next upload
    /// (if the user keeps using the app with sync on) recreates an empty zone
    /// via `ensureZoneExists` — correct.
    private func performDeleteAllRemoteData() async -> Bool {
        let zoneNames = allCustomZoneIDs.map(\.zoneName).joined(separator: ", ")
        let outcome: Result<Bool, Error> = await manager.withTimeoutResult(seconds: 30) {
            try await self.deleteCustomZonesOnce()
        }
        guard Self.remoteDeletionSucceeded(outcome) else { return false }
        manager.resetLocalSyncState()
        clearSanitizeDripState()
        debugLog("[CloudKit] Remote deletion complete — zones [\(zoneNames)] removed from private DB; local sync manager.state reset")
        return true
    }

    /// A zone-already-gone error counts as success: the remote data the user
    /// asked us to delete doesn't exist, which IS the requested end state.
    private static func remoteDeletionSucceeded(_ outcome: Result<Bool, Error>) -> Bool {
        switch outcome {
        case .success(true):
            return true
        case .success(false):
            return false
        case let .failure(error):
            guard isZoneAlreadyGoneError(error) else {
                debugLog("[CloudKit] Remote deletion failed: \(error.localizedDescription)", level: .error)
                return false
            }
            return true
        }
    }

    /// One zone-modify round-trip deleting both custom zones. MainActor-
    /// isolated like every other CK call in this class (the async save
    /// suspends, never blocks). Returns false on a real per-zone failure;
    /// a zone that's already gone counts as deleted.
    private func deleteCustomZonesOnce() async throws -> Bool {
        let (_, deleteResults) = try await manager.privateDB.modifyRecordZones(
            saving: [],
            deleting: allCustomZoneIDs
        )
        for (zone, result) in deleteResults {
            if case let .failure(error) = result, !Self.isZoneAlreadyGoneError(error) {
                debugLog("[CloudKit] Remote deletion failed for zone \(zone.zoneName): \(error.localizedDescription)", level: .error)
                return false
            }
        }
        return true
    }

    /// Clear the Guideline 5.1.3 sanitize-drip bookkeeping. After a remote
    /// wipe the drip's remaining-id list refers to records that no longer
    /// exist; leaving it behind would make a future sync re-enable churn
    /// through pointless re-marks. Internal (not private) for unit tests.
    func clearSanitizeDripState() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: CloudKitSyncManager.hkSanitizeRemainingKey)
        defaults.removeObject(forKey: CloudKitSyncManager.hkSanitizeInitializedKey)
    }

    /// True when `error` means the zone we tried to delete doesn't exist —
    /// `.zoneNotFound` / `.userDeletedZone`, directly or wrapped in a
    /// batch `.partialFailure`. For a deletion, "already gone" is success.
    static func isZoneAlreadyGoneError(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        switch ckError.code {
        case .zoneNotFound, .userDeletedZone:
            return true
        case .partialFailure:
            guard let partial = ckError.partialErrorsByItemID, !partial.isEmpty else { return false }
            return partial.values.allSatisfy { isZoneAlreadyGoneError($0) }
        default:
            return false
        }
    }
}
