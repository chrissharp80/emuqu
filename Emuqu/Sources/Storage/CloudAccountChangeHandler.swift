import CloudKit
import Foundation

/// What `.CKAccountChanged` does to sync: re-check the CloudKit account
/// status and reflect it in the sync state Settings reads.
///
/// Reacting to the account status is its own job, like `CloudDeletionCoordinator`
/// and `CloudAccountGuard`. Built on each
/// access (`CloudKitSyncManager.accountChange`); it holds no state of its
/// own and reaches the manager through one explicit reference.
@MainActor
struct CloudAccountChangeHandler {
    let manager: CloudKitSyncManager

    /// Re-check the CloudKit account status after `.CKAccountChanged` and
    /// reflect it in sync state. A signed-out / restricted account surfaces
    /// as `.error` (read by the same UI as every other sync error) rather
    /// than failing silently; a recovered `.available` account clears the
    /// not-signed-in error and runs a sync, which starts by checking the
    /// account (`resumeSyncForAvailableAccount`): the Apple ID sync was
    /// enabled for syncs on, and a different one stops sync before anything
    /// is read or written.
    ///
    /// `.temporarilyUnavailable` is transient (iCloud briefly unreachable) so
    /// it stamps no permanent error — the next sync retries. It is handled
    /// explicitly because it's a KNOWN case: `@unknown default` covers only
    /// future/unknown values, so leaving it out tripped "switch must be
    /// exhaustive" (a warning under Swift 5, a hard error under stricter
    /// concurrency settings).
    func handle() async {
        let status: CKAccountStatus
        do {
            status = try await manager.container.accountStatus()
        } catch {
            debugLog("[CloudKit] Account change: status check failed: \(error.localizedDescription)", level: .warning)
            return
        }
        switch status {
        case .available:
            await resumeSyncForAvailableAccount()
        case .noAccount, .restricted, .couldNotDetermine:
            pauseSyncForUnusableAccount(status)
        case .temporarilyUnavailable:
            debugLog("[CloudKit] Account change: iCloud temporarily unavailable — will retry on next sync", level: .warning)
        @unknown default:
            break
        }
    }

    /// Clear the not-signed-in error (`CloudKitSyncManager.clearNotSignedInError`),
    /// then refresh.
    ///
    /// The bookkeeping is not wiped here: `.CKAccountChanged` also fires on a
    /// transient drop and reconnect of the SAME account. Which account is
    /// signed in is decided by the account check every sync starts with
    /// (`CloudAccountGuard.confirmAccount`): the same account syncs on, and a
    /// different one stops sync before anything is read or written. With sync
    /// off, the check runs on its own, so a switched account is caught before
    /// the user turns sync on again.
    private func resumeSyncForAvailableAccount() async {
        debugLog("[CloudKit] Account change: iCloud account available — checking it and refreshing sync")
        manager.clearNotSignedInError()
        let settings = manager.settingsManager.settings
        guard settings.iCloudSyncEnabled else {
            guard settings.hasCompletedOnboarding else { return }
            let manager = manager
            await manager.syncSerializer.run { _ = await manager.accountGuard.confirmAccount() }
            return
        }
        await manager.performFullSync()
    }

    /// Surface via the same `syncState`/error path the rest of the UI reads,
    /// and stamp the permanent-error field so Settings shows why sync stopped
    /// instead of silently no-op'ing (`CloudKitSyncManager.showSyncStopped`).
    private func pauseSyncForUnusableAccount(_ status: CKAccountStatus) {
        debugLog("[CloudKit] Account change: no usable iCloud account (\(status.rawValue)) — pausing sync", level: .warning)
        manager.showSyncStopped(CloudSyncMessages.notSignedIn)
    }
}
