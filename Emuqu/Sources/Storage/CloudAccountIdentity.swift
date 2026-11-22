import CloudKit
import Foundation
import os

/// Which iCloud account this device's sync bookkeeping belongs to.
///
/// Every mark the sync keeps (the uploaded set, the zone-created flag, the
/// confirmed tombstones, the cloud key) describes one iCloud account. When the
/// device is signed into another Apple ID, that bookkeeping no longer matches
/// what iCloud holds, and acting on it uploads this device's archive, settings
/// and live backups into somebody else's iCloud and imports their sessions
/// here. So the account is recorded when sync is enabled for it, and nothing is
/// read from or written to iCloud until this launch has checked that the
/// signed-in account is the recorded one (`isConfirmed`).
///
/// The identity is `CKContainer.userRecordID().recordName`, which is stable
/// for an Apple ID within the app's container and says nothing about the
/// person. It is stored in this device's `UserDefaults` only: never synced,
/// never uploaded.
///
/// Installs from before the identity was recorded have none. They adopt the
/// signed-in account on the first successful check of a launch in which the
/// account status has not changed (`verdict`): that is the account they have
/// been syncing with, unless the Apple ID was switched while an older build
/// was installed, which nothing on the device can show afterwards.
enum CloudAccountIdentity {
    /// The recorded account's `userRecordID().recordName`.
    static let recordedKey = "cloudkit.accountIdentity"
    /// Why the app, not the user, last turned iCloud Sync off; removed once
    /// sync is enabled again for an account.
    static let stopReasonKey = "cloudkit.syncStoppedReason"

    /// What this launch knows about the signed-in account.
    private struct LaunchState {
        /// The account this launch checked and found to be the recorded one.
        var confirmed: String?
        /// A `.CKAccountChanged` arrived during this launch.
        var accountChanged = false
        /// Advanced by every account change, so a check that started before
        /// one does not confirm the account it fetched.
        var generation = 0
    }

    private static let launch = OSAllocatedUnfairLock(initialState: LaunchState())

    /// The recorded account, or nil when none is.
    static var recordedAccount: String? {
        UserDefaults.standard.string(forKey: recordedKey)
    }

    /// Whether this launch checked the signed-in account and it is the
    /// recorded one. Every upload, deletion, pull and cloud-key creation waits
    /// for this.
    static var isConfirmed: Bool {
        guard let recorded = recordedAccount else { return false }
        return launch.withLock { $0.confirmed } == recorded
    }

    /// The current check generation (see `LaunchState.generation`).
    static var checkGeneration: Int {
        launch.withLock { $0.generation }
    }

    /// Whether the account status changed during this launch.
    static var accountChangedThisLaunch: Bool {
        launch.withLock { $0.accountChanged }
    }

    /// A `.CKAccountChanged` arrived: the account is unconfirmed until it is
    /// checked again.
    static func noteAccountChanged() {
        launch.withLock { state in
            state.confirmed = nil
            state.accountChanged = true
            state.generation += 1
        }
    }

    /// Drop this launch's confirmation, so the next check fetches the account
    /// again.
    static func revokeConfirmation() {
        launch.withLock { state in
            state.confirmed = nil
            state.generation += 1
        }
    }

    /// The signed-in account `name`, fetched in check `generation`, is the
    /// recorded one. False, with nothing confirmed, when the account changed
    /// since that check began.
    static func confirm(_ name: String, generation: Int) -> Bool {
        launch.withLock { state -> Bool in
            guard state.generation == generation else { return false }
            state.confirmed = name
            return true
        }
    }

    /// Record `name` as the account sync is enabled for, and confirm it. A
    /// stop notice from an earlier account ends here. False, with nothing
    /// recorded, when the account changed since check `generation` began.
    static func adopt(_ name: String, generation: Int) -> Bool {
        let adopted = launch.withLock { state -> Bool in
            guard state.generation == generation else { return false }
            state.confirmed = name
            return true
        }
        guard adopted else { return false }
        UserDefaults.standard.set(name, forKey: recordedKey)
        UserDefaults.standard.removeObject(forKey: stopReasonKey)
        return true
    }

    /// Forget the recorded account: the next account sync is enabled for is
    /// recorded afresh.
    static func forget() {
        UserDefaults.standard.removeObject(forKey: recordedKey)
        revokeConfirmation()
    }

    /// What a check of the signed-in account decides.
    enum Verdict: Equatable {
        /// It is the recorded account.
        case sameAccount
        /// Nothing is recorded, and this is the account to record.
        case adopt
        /// It is not the recorded account, or nothing is recorded and the
        /// bookkeeping cannot be attributed to it.
        case differentAccount
        /// Nothing is recorded because the app turned sync off, and sync is
        /// still off: nothing may be read or written until the user opts in.
        case awaitingOptIn
    }

    /// The decision for the signed-in account `current`.
    ///
    /// With no account recorded, the signed-in one is adopted unless the app
    /// stopped sync and the user has not turned it on again, or the account
    /// status changed during this launch while bookkeeping from an earlier
    /// account remains: that bookkeeping may describe another Apple ID, so the
    /// safe reading is a different account.
    static func verdict(
        recorded: String?, current: String, syncEnabled: Bool, stoppedByApp: Bool,
        accountChangedThisLaunch: Bool, hasBookkeeping: Bool
    ) -> Verdict {
        if let recorded { return recorded == current ? .sameAccount : .differentAccount }
        if stoppedByApp, !syncEnabled { return .awaitingOptIn }
        if accountChangedThisLaunch, hasBookkeeping { return .differentAccount }
        return .adopt
    }

    /// Why the app turned iCloud Sync off.
    enum StopReason: String {
        /// The device is signed into another Apple ID than the one sync was
        /// enabled for.
        case differentAccount
        /// The app's data was deleted from iCloud: by Delete All My Data on
        /// any device, or in the iCloud settings.
        case iCloudDataDeleted

        /// The line shown under the iCloud Sync switch.
        var message: String {
            switch self {
            case .differentAccount:
                String(
                    localized: "iCloud Sync was turned off because this device is now signed into a different iCloud account. Nothing was uploaded to it. Turn iCloud Sync on to back up to this account.",
                    bundle: LanguageManager.appBundle
                )
            case .iCloudDataDeleted:
                String(
                    localized: "iCloud Sync was turned off because your data in iCloud was deleted. Your sessions are still on this device. Turn iCloud Sync on to back them up again.",
                    bundle: LanguageManager.appBundle
                )
            }
        }
    }

    /// Why the app last turned sync off, until sync is enabled again.
    static var stopReason: StopReason? {
        UserDefaults.standard.string(forKey: stopReasonKey).flatMap(StopReason.init(rawValue:))
    }

    static func noteStopped(_ reason: StopReason) {
        UserDefaults.standard.set(reason.rawValue, forKey: stopReasonKey)
    }
}

/// Checks the signed-in iCloud account against `CloudAccountIdentity` and
/// stops sync when the two part. Built on each access, like the other sync
/// coordinators; it holds no state of its own.
@MainActor
struct CloudAccountGuard {
    let manager: CloudKitSyncManager

    /// What a check found.
    enum Check: Equatable {
        /// The signed-in account is the one sync is enabled for.
        case confirmed
        /// It could not be checked now (no account, network); nothing may
        /// be read or written, and the reason is shown.
        case unavailable(String)
        /// Nothing may be read or written: sync was stopped, now or earlier,
        /// and waits for the user to turn it on.
        case stopped
    }

    /// Confirm the signed-in account, fetching it unless this launch already
    /// did. A different account stops sync (`stopSync(.differentAccount)`).
    /// The verdict is `CloudAccountIdentity.verdict`'s.
    func confirmAccount() async -> Check {
        if CloudAccountIdentity.isConfirmed { return .confirmed }
        let generation = CloudAccountIdentity.checkGeneration
        let current: String
        do {
            current = try await manager.container.userRecordID().recordName
        } catch {
            debugLog("[CloudKit] Could not check the iCloud account: \(error.localizedDescription)", level: .warning)
            return .unavailable(manager.cloudKitErrorMessage(error))
        }
        // An account change while the fetch ran makes `current` stale: the
        // check starts over against the new account.
        guard let check = apply(verdict(for: current), to: current, generation: generation) else {
            return await confirmAccount()
        }
        return check
    }

    /// `CloudAccountIdentity.verdict` for the signed-in account `current`.
    private func verdict(for current: String) -> CloudAccountIdentity.Verdict {
        CloudAccountIdentity.verdict(
            recorded: CloudAccountIdentity.recordedAccount, current: current,
            syncEnabled: manager.settingsManager.settings.iCloudSyncEnabled,
            stoppedByApp: CloudAccountIdentity.stopReason != nil,
            accountChangedThisLaunch: CloudAccountIdentity.accountChangedThisLaunch,
            hasBookkeeping: manager.hasAccountBookkeeping
        )
    }

    /// Act on `verdict` for the account `current`, fetched in check
    /// `generation`: confirm it, record it, or stop sync. Nil when the account
    /// changed since that check began, and nothing was confirmed or recorded.
    private func apply(_ verdict: CloudAccountIdentity.Verdict, to current: String, generation: Int) -> Check? {
        switch verdict {
        case .sameAccount:
            return CloudAccountIdentity.confirm(current, generation: generation) ? .confirmed : nil
        case .adopt:
            guard CloudAccountIdentity.adopt(current, generation: generation) else { return nil }
            debugLog("[CloudKit] Recorded the iCloud account this device syncs with", level: .info)
            return .confirmed
        case .awaitingOptIn:
            return .stopped
        case .differentAccount:
            stopSync(.differentAccount)
            return .stopped
        }
    }

    /// Why a full sync ends before its first phase.
    enum Halt: LocalizedError {
        /// The account could not be checked; the message says why.
        case unavailable(String)
        /// Sync is off for this account, and the stop is already shown.
        case stopped

        var errorDescription: String? {
            guard case let .unavailable(message) = self else { return nil }
            return message
        }
    }

    /// Returns once the signed-in account is confirmed; throws `Halt`
    /// otherwise. The full sync's first step.
    func requireConfirmedAccount() async throws {
        switch await confirmAccount() {
        case .confirmed:
            return
        case let .unavailable(message):
            throw Halt.unavailable(message)
        case .stopped:
            throw Halt.stopped
        }
    }

    /// The session or settings zone is gone from iCloud. With the account
    /// confirmed afresh, the user deleted the app's iCloud data (Delete All My
    /// Data on another device, or the iCloud settings), and that is honoured:
    /// sync stops and waits for the user to opt in again, rather than
    /// recreating the zone and uploading everything back. A different account
    /// stops sync as one. When the account cannot be checked, nothing is
    /// recreated, re-queued or stopped, and the reason is returned for the
    /// caller to show.
    func zoneWasDeleted() async -> String? {
        CloudAccountIdentity.revokeConfirmation()
        switch await confirmAccount() {
        case .confirmed:
            stopSync(.iCloudDataDeleted)
            return nil
        case .stopped:
            return nil
        case let .unavailable(message):
            return message
        }
    }

    /// Turn iCloud Sync off for `reason`. The per-account bookkeeping is reset
    /// (uploaded set, queue, record versions, zone flags, confirmed
    /// tombstones, the scrub list) and the recorded account forgotten; no
    /// session, setting or backup on this device is touched. The user opts in
    /// again through the iCloud Sync switch, which records the account then.
    func stopSync(_ reason: CloudAccountIdentity.StopReason) {
        debugLog("[CloudKit] Stopping iCloud sync (\(reason.rawValue)) — local data kept, bookkeeping reset", level: .warning)
        CloudAccountIdentity.forget()
        CloudAccountIdentity.noteStopped(reason)
        manager.resetLocalSyncState()
        manager.deletion.forgetConfirmedTombstones()
        manager.healthScrub.clear()
        manager.settingsManager.settings.iCloudSyncEnabled = false
        manager.showSyncStopped(reason.message)
    }
}
