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
/// was installed, which nothing on the device can show afterwards. When the
/// status did change first (a reconnect, a launch offline, or a switch), the
/// check looks up a few of the sessions this device uploaded in the
/// signed-in account's iCloud before deciding: that lookup by record id is
/// the one read made before the account is confirmed, and it writes nothing.
/// With iCloud Sync off and nothing of an account's on the device, no
/// account is recorded until the user turns sync on.
enum CloudAccountIdentity {
    /// The recorded account's `userRecordID().recordName`.
    static let recordedKey = "cloudkit.accountIdentity"
    /// Why the app, not the user, last turned iCloud Sync off; removed once
    /// sync is enabled again for an account.
    static let stopReasonKey = "cloudkit.syncStoppedReason"

    /// What this launch knows about the signed-in account. A value, so its
    /// rules can be exercised on a copy of their own; the process keeps one
    /// in `launch`.
    struct LaunchState {
        /// The account this launch checked and found to be the recorded one.
        private(set) var confirmed: String?
        /// A `.CKAccountChanged` arrived during this launch.
        private(set) var accountChanged = false
        /// Advanced by every account change, so a check that started before
        /// one does not confirm the account it fetched.
        private(set) var generation = 0

        /// Whether `recorded` is the account this launch confirmed.
        func isConfirmed(recorded: String?) -> Bool {
            guard let recorded else { return false }
            return confirmed == recorded
        }

        /// An account change: nothing is confirmed, and checks begun before
        /// it confirm nothing.
        mutating func noteAccountChanged() {
            confirmed = nil
            accountChanged = true
            generation += 1
        }

        /// Drop the confirmation; checks begun before it confirm nothing.
        mutating func revokeConfirmation() {
            confirmed = nil
            generation += 1
        }

        /// Confirm `name`, fetched in check `check`. False, with nothing
        /// confirmed, when the generation moved on since that check began.
        mutating func confirm(_ name: String, generation check: Int) -> Bool {
            guard generation == check else { return false }
            confirmed = name
            return true
        }
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
        let recorded = recordedAccount
        return launch.withLock { $0.isConfirmed(recorded: recorded) }
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
        launch.withLock { $0.noteAccountChanged() }
    }

    /// Drop this launch's confirmation, so the next check fetches the account
    /// again.
    static func revokeConfirmation() {
        launch.withLock { $0.revokeConfirmation() }
    }

    /// The signed-in account `name`, fetched in check `generation`, is the
    /// recorded one. False, with nothing confirmed, when the account changed
    /// since that check began.
    static func confirm(_ name: String, generation: Int) -> Bool {
        launch.withLock { $0.confirm(name, generation: generation) }
    }

    /// Record `name` as the account sync is enabled for, and confirm it. A
    /// stop notice from an earlier account ends here. False, with nothing
    /// recorded, when the account changed since check `generation` began.
    static func adopt(_ name: String, generation: Int) -> Bool {
        guard launch.withLock({ $0.confirm(name, generation: generation) }) else { return false }
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
        /// It is not the recorded account.
        case differentAccount
        /// Nothing is recorded, the account status changed during this launch,
        /// and bookkeeping from an earlier account remains: whether it is this
        /// account's is looked up in its iCloud before anything else is done
        /// (`CloudAccountGuard.confirmAccount`).
        case attributeBookkeeping
        /// Nothing is recorded and sync is off, and either the app turned it
        /// off or nothing on this device belongs to any account: nothing may
        /// be read or written, and nothing is recorded, until the user opts in.
        case awaitingOptIn
    }

    /// The decision for the signed-in account `current`.
    ///
    /// With no account recorded: while sync is off, nothing is adopted when
    /// the app stopped sync or there is no bookkeeping to keep in step (the
    /// account is recorded when the user turns sync on). Otherwise the
    /// signed-in account is adopted, unless the account status changed during
    /// this launch while bookkeeping remains: that bookkeeping may describe
    /// another Apple ID, so it is attributed by looking it up first. The
    /// upload queue is not bookkeeping (`CloudKitSyncManager.hasAccountBookkeeping`).
    static func verdict(
        recorded: String?, current: String, syncEnabled: Bool, stoppedByApp: Bool,
        accountChangedThisLaunch: Bool, hasBookkeeping: Bool
    ) -> Verdict {
        if let recorded { return recorded == current ? .sameAccount : .differentAccount }
        if !syncEnabled, stoppedByApp || !hasBookkeeping { return .awaitingOptIn }
        if accountChangedThisLaunch, hasBookkeeping { return .attributeBookkeeping }
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
        /// The signed-in account is not the one this device's bookkeeping
        /// belongs to: the check reset that bookkeeping (`stopSync`), and
        /// nothing may be read or written.
        case differentAccount
    }

    /// Confirm the signed-in account, fetching it unless this launch already
    /// did. A different account stops sync (`stopSync(.differentAccount)`).
    /// The verdict is `CloudAccountIdentity.verdict`'s; bookkeeping it cannot
    /// attribute is looked up in iCloud (`lookUpBookkeeping`).
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
        guard let check = await apply(verdict(for: current), to: current, generation: generation) else {
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
    /// `generation`: confirm it, record it, or stop sync. Bookkeeping to
    /// attribute is looked up first: found in this account, it is adopted;
    /// absent, the account is a different one; when iCloud cannot be asked,
    /// nothing is decided and the reason is returned. Nil when the account
    /// changed since that check began, and nothing was confirmed, recorded or
    /// stopped.
    private func apply(_ verdict: CloudAccountIdentity.Verdict, to current: String, generation: Int) async -> Check? {
        switch verdict {
        case .sameAccount:
            return CloudAccountIdentity.confirm(current, generation: generation) ? .confirmed : nil
        case .adopt:
            guard CloudAccountIdentity.adopt(current, generation: generation) else { return nil }
            debugLog("[CloudKit] Recorded the iCloud account this device syncs with", level: .info)
            return .confirmed
        case .attributeBookkeeping:
            return await applyAttribution(to: current, generation: generation)
        case .awaitingOptIn:
            return .stopped
        case .differentAccount:
            guard CloudAccountIdentity.checkGeneration == generation else { return nil }
            stopSync(.differentAccount)
            return .differentAccount
        }
    }

    /// The bookkeeping looked up in iCloud (`lookUpBookkeeping`): found, the
    /// account is adopted; absent, it is a different one; when iCloud cannot
    /// be asked, nothing is decided and the reason is returned.
    private func applyAttribution(to current: String, generation: Int) async -> Check? {
        switch await lookUpBookkeeping() {
        case .found:
            return await apply(.adopt, to: current, generation: generation)
        case .absent:
            return await apply(.differentAccount, to: current, generation: generation)
        case let .unknown(message):
            return .unavailable(message)
        }
    }

    /// What the lookup of this device's bookkeeping in the signed-in
    /// account's iCloud found.
    private enum Attribution {
        /// A session this device uploaded is there: it is the account.
        case found
        /// None of them is, or this device uploaded none to look up.
        case absent
        /// iCloud could not be asked; the message says why.
        case unknown(String)
    }

    /// How many uploaded sessions the lookup asks for. One found is enough:
    /// the record names are this device's session ids, which no other Apple
    /// ID's iCloud holds.
    private static let attributionSampleSize = 5

    /// Look up a few sessions this device uploaded (`uploadedSessionIds`) by
    /// record id in the signed-in account's session zone, reading only their
    /// deletion flag and writing nothing. A record found, tombstones
    /// included, shows the bookkeeping is this account's. All of them missing,
    /// or the zone missing, shows it is not. With nothing uploaded there is
    /// nothing that could show it, and the bookkeeping counts as another
    /// account's: a zone of the same name exists in every account that has
    /// used the app.
    private func lookUpBookkeeping() async -> Attribution {
        let ids = manager.state.uploadedSessionIds.prefix(Self.attributionSampleSize)
        guard !ids.isEmpty else { return .absent }
        let recordIDs = ids.map { CKRecord.ID(recordName: $0.uuidString, zoneID: manager.zoneID) }
        do {
            let fetched = try await manager.privateDB.records(for: recordIDs, desiredKeys: ["isDeleted"])
            return attribution(of: Array(fetched.values))
        } catch let error as CKError where CloudHealthScrubCoordinator.meansNoRecord(error) {
            return .absent
        } catch {
            debugLog("[CloudKit] Could not look up this device's sessions in the signed-in iCloud account: \(error.localizedDescription)", level: .warning)
            return .unknown(manager.cloudKitErrorMessage(error))
        }
    }

    /// What the fetched records show: any record returned is found; a missing
    /// record (or zone) is skipped; any other failure leaves the answer
    /// unknown unless a record is found.
    private func attribution(of results: [Result<CKRecord, Error>]) -> Attribution {
        var answer = Attribution.absent
        for result in results {
            guard case let .failure(error) = result else { return .found }
            guard !Self.meansMissing(error) else { continue }
            answer = .unknown(manager.cloudKitErrorMessage(error))
        }
        return answer
    }

    /// Whether `error` says the record, or its zone, is not in iCloud.
    private static func meansMissing(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        return CloudHealthScrubCoordinator.meansNoRecord(ckError)
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
        case .stopped, .differentAccount:
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
        case .stopped, .differentAccount:
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
    ///
    /// With sync already off (the check ran for the sync-off scrub or an
    /// account change), only the bookkeeping is reset: no stop reason is kept
    /// or shown, since the app did not turn anything off.
    func stopSync(_ reason: CloudAccountIdentity.StopReason) {
        let wasOn = manager.settingsManager.settings.iCloudSyncEnabled
        debugLog("[CloudKit] Stopping iCloud sync (\(reason.rawValue), sync \(wasOn ? "on" : "already off")) — local data kept, bookkeeping reset", level: .warning)
        CloudAccountIdentity.forget()
        manager.resetLocalSyncState()
        manager.deletion.forgetConfirmedTombstones()
        manager.healthScrub.clear()
        guard wasOn else { return }
        CloudAccountIdentity.noteStopped(reason)
        manager.settingsManager.settings.iCloudSyncEnabled = false
        manager.showSyncStopped(reason.message)
    }
}
