import Foundation
import os
import SwiftUI

// Interrupted-session recovery: the launch-time "we found an unfinished
// recording" alert and the resume, recover and dismiss actions behind it.

extension EmuquApp {
    /// Note, at launch, any archived workout that captured essentially nothing
    /// and could be rebuilt from Apple Health.
    ///
    /// The Fitness tab shows a card for these, but only once the user goes
    /// there. A recording that died is exactly the thing a user does not go
    /// looking for — they assume the app lost it — so the fact is recorded at
    /// startup where a debug log will always carry it, whether or not anyone
    /// opened the tab.
    ///
    /// The scan reads (and decrypts) the file of each short workout, so it
    /// runs on a detached task (`HealthWorkoutImporter.scanInterruptedSessions`),
    /// off the main actor, and nothing at launch waits for it.
    private func logRebuildableWorkouts() {
        let archive = collector.archive
        Task.detached(priority: .utility) {
            let stubs = HealthWorkoutImporter.scanInterruptedSessions(archive: archive)
            guard !stubs.isEmpty else { return }
            let summary = stubs
                .prefix(3)
                .map { "\($0.sport.rawValue) \($0.startDate) (\(Int($0.capturedSeconds))s captured)" }
                .joined(separator: ", ")
            debugLog(
                "[App][launch] \(stubs.count) interrupted recording(s) can be rebuilt from Apple Health: \(summary)",
                level: .info
            )
        }
    }

    /// Check if a recording session was in progress when the app was killed.
    /// Persisted state survives crashes — if it exists on launch, the session was interrupted.
    ///
    /// Runs once the archive's launch boot (`LaunchArchiveBoot`) has adopted
    /// orphan files: a session whose file was written just before a crash,
    /// but not yet listed in the index, is archived, and asking about it
    /// would offer to rebuild it from its backup over the saved copy.
    ///
    /// The alert is raised only with no launch modal on screen; an alert under
    /// a full-screen cover can be dropped. `EmuquApp.handleLaunchModalChange`
    /// runs the check again when the cover closes.
    func checkForInterruptedSession() {
        let archiveBoot = LaunchArchiveBoot.start(collector.archive)
        Task { @MainActor in
            await archiveBoot.value
            logRebuildableWorkouts()
            guard activeModal == nil else {
                debugLog("[App] Interrupted-session check deferred — a launch modal is on screen")
                return
            }
            presentInterruptedSessionAlertIfNeeded()
        }
    }

    /// Dismiss means "stop re-prompting me." Re-prompting on every launch
    /// (and re-writing the termination report on every launch) traps the
    /// user discarding the same session over and over. So both the alert AND
    /// the termination report are skipped once this session has been
    /// dismissed. The backup is still recoverable via Settings → iCloud & Data → Recover Lost Sessions
    /// for users who change their mind.
    private func presentInterruptedSessionAlertIfNeeded() {
        guard let state = collector.recordingStore.load() else { return }
        // Only alert if the session isn't already archived (e.g. auto-archived on background)
        guard !collector.archive.store.exists(state.sessionId) else {
            collector.recordingStore.clear()
            return
        }
        guard !PersistedRecordingState.isDismissed(state.sessionId) else {
            debugLog("[App] Skipping interrupted-session alert for \(state.sessionId.uuidString.prefix(8)) — user dismissed previously")
            return
        }
        debugLog("[App] Detected interrupted session: \(state.sessionId.uuidString.prefix(8)) started \(state.startTime)")
        // Write a termination report — iOS SIGKILL can't be caught by signal handlers
        AppDependencies.current.app.crashLogManager.recordTermination(
            sessionId: state.sessionId, sessionStart: state.startTime,
            sessionType: state.sessionType.rawValue
        )
        interruptedSessionAlert = InterruptedSessionInfo(
            sessionId: state.sessionId, startTime: state.startTime, sessionType: state.sessionType
        )
    }

    /// Resume: recover backup data into paused state so the user can continue recording.
    /// The Record tab will show the standard Resume / Done buttons.
    func resumeInterruptedSession() {
        guard let info = interruptedSessionAlert else { return }
        interruptedSessionAlert = nil
        Task { await resume(info) }
    }

    /// Launch auto-recovery may have finished and saved this workout; it
    /// isn't paused any more, and saying so is the outcome.
    private func resume(_ info: InterruptedSessionInfo) async {
        if let saved = await claimRecovery(info.sessionId) {
            await MainActor.run { recoveryResultMessage = saved }
            return
        }
        defer { InterruptedWorkoutAutoRecovery.end(info.sessionId) }
        let success = await collector.recovery.recoverToPausedState(info.sessionId, sessionType: info.sessionType)
        await MainActor.run { showRecoveryOutcome(success: success) }
    }

    @MainActor
    private func showRecoveryOutcome(success: Bool) {
        recoveryResultMessage = success
            ? String(localized: "Your session data has been restored. Go to the Record tab to resume or finish.", bundle: languageManager.bundle)
            : String(localized: "Could not restore the session. Check Settings → iCloud & Data → Recover Lost Sessions for manual recovery.", bundle: languageManager.bundle)
    }

    /// Save as Complete: recover and archive the partial session as-is.
    /// Branches by session type:
    ///   • Workouts use `WorkoutRecoveryService` so the GPS track, per-tick
    ///     samples, and barometric elevation come along — not just the RR
    ///     stream. The reconstructed session reaches the dashboard +
    ///     iCloud as a complete (but flagged "Estimated") workout.
    ///   • HRV / overnight sessions use the existing `recoverFromBackup`
    ///     path, which only knows about RR.
    func recoverInterruptedSession() {
        guard let info = interruptedSessionAlert else { return }
        interruptedSessionAlert = nil
        Task {
            let resultMessage = info.sessionType == .workout
                ? await recoverInterruptedWorkout(info)
                : await recoverInterruptedRecording(info)
            await MainActor.run {
                recoveryResultMessage = resultMessage
            }
        }
    }

    private func recoverInterruptedWorkout(_ info: InterruptedSessionInfo) async -> String {
        // Launch auto-recovery may have this workout already, merged with the
        // strap's own recording. Rebuilding it from the phone's copy would
        // replace that with less.
        if let saved = await claimRecovery(info.sessionId) { return saved }
        defer { InterruptedWorkoutAutoRecovery.end(info.sessionId) }
        let outcome = await WorkoutRecoveryService.recover(
            sessionId: info.sessionId,
            reason: .userInterrupted,
            archive: collector.archive,
            rawBackup: collector.rawBackup,
            cloudSyncManager: syncManager
        )
        collector.recordingStore.clear()
        guard let outcome else {
            return String(localized: "Could not recover the workout. The backup data may be incomplete. Check Settings → iCloud & Data → Recover Lost Sessions for manual recovery.", bundle: languageManager.bundle)
        }
        return outcome.summaryLine + " " + recoveredWorkoutSaveNote(wasArchived: outcome.wasArchived)
    }

    private func recoveredWorkoutSaveNote(wasArchived: Bool) -> String {
        wasArchived
            ? String(localized: "Saved to your archive.", bundle: languageManager.bundle)
            : String(
                localized: "Could not save the recovered workout. Its backup is kept: recover it from Settings → iCloud & Data → Recover Lost Sessions.",
                bundle: languageManager.bundle
            )
    }

    /// The message to show when launch auto-recovery has saved this session;
    /// nil when this call claimed the recovery for the alert
    /// (`InterruptedWorkoutAutoRecovery.claim`), which the caller then runs
    /// and releases with `end`.
    ///
    /// Launch auto-recovery starts only once the tabs are built, so it may
    /// begin after the alert was answered. Claiming the session first keeps
    /// it out: two recoveries of one session would each write it, and the
    /// last one, perhaps the phone-only rebuild, would replace the
    /// strap-merged one. Auto-recovery that started first is waited for. If
    /// it claimed the session between the wait and the claim, it is waited
    /// for again, all within one `autoRecoveryWaitLimit`: once that has
    /// passed with auto-recovery still holding the session, the user is told
    /// it is still being recovered rather than kept waiting on it, and
    /// nothing else rebuilds it.
    private func claimRecovery(_ sessionId: UUID) async -> String? {
        let deadline = Date().addingTimeInterval(Self.autoRecoveryWaitLimit)
        while true {
            let remaining = max(deadline.timeIntervalSinceNow, 0)
            if let saved = await savedByAutoRecovery(sessionId, waitingAtMost: remaining) { return saved }
            if InterruptedWorkoutAutoRecovery.claim(sessionId) { return nil }
            if Date() >= deadline {
                return String(
                    localized: "This workout is still being recovered in the background. It will be in your archive when that finishes. If it is not, recover it from Settings → iCloud & Data → Recover Lost Sessions.",
                    bundle: languageManager.bundle
                )
            }
        }
    }

    /// How long Save and Resume wait, in all, for launch auto-recovery of the
    /// same session.
    private static let autoRecoveryWaitLimit: TimeInterval = 150

    /// The message to show when launch auto-recovery has saved this session,
    /// after waiting up to `limit` for it to finish; nil when it is not saved
    /// (still to be recovered, or still being recovered when `limit` ran out).
    private func savedByAutoRecovery(_ sessionId: UUID, waitingAtMost limit: TimeInterval) async -> String? {
        await InterruptedWorkoutAutoRecovery.waitUntilDone(sessionId, limit: limit)
        guard collector.archive.store.exists(sessionId) else { return nil }
        collector.recordingStore.clear()
        return String(localized: "Saved to your archive.", bundle: languageManager.bundle)
    }

    /// The message names the type the session was saved as: a backup of an
    /// interrupted night too short to be one is saved as a quick reading
    /// (`SessionRecoveryService.recoveredSessionType`).
    private func recoverInterruptedRecording(_ info: InterruptedSessionInfo) async -> String {
        let recovered = await collector.recovery.recoverFromBackup(info.sessionId, recordedType: info.sessionType)
        collector.recordingStore.clear()
        guard let recovered else {
            return String(localized: "Could not recover the session. The backup data may be incomplete. Check Settings → iCloud & Data → Recover Lost Sessions for manual recovery.", bundle: languageManager.bundle)
        }
        return String(localized: "\(recovered.sessionType.displayName) session saved to your archive.", bundle: languageManager.bundle)
    }

    func dismissInterruptedSession() {
        // Not just `interruptedSessionAlert = nil`: that closes the
        // alert in-memory but leaves the persisted state on disk so
        // EVERY subsequent launch re-detects it and re-fires the same
        // alert.
        // Record the dismissal so the alert never fires again
        // for this sessionId. The backup data stays on disk so
        // Settings → iCloud & Data → Recover Lost Sessions can still recover it if the user
        // changes their mind.
        if let info = interruptedSessionAlert {
            PersistedRecordingState.markDismissed(info.sessionId)
        }
        interruptedSessionAlert = nil
    }

    /// UI-test fresh-install reset.
    ///
    /// Without it the UI tests have no way to reach the onboarding flow, because
    /// acceptance is persisted across launches. The `-UITests-FreshInstall`
    /// launch argument (passed by the EmuquUITests suites that need a fresh
    /// install — onboarding, dashboard, settings, record, data deletion and
    /// others) wipes the onboarding/disclaimer/paywall flags so the next
    /// launch walks the new-install path. A no-op when the flag is absent.
    ///
    /// Compiled out of Release. The UI suites run Debug builds, and a store
    /// binary should hold no code path that erases a user's data on a launch
    /// argument, reachable or not.
    static func resetUITestStateIfRequested() {
        #if DEBUG
            guard CommandLine.arguments.contains("-UITests-FreshInstall") else { return }
            NSLog("[App][launch] -UITests-FreshInstall — wiping onboarding/disclaimer/paywall state")
            clearLaunchModalDefaults()
            // The entitlement anchor is built to survive app deletion, so a
            // reinstall cannot clear it and every run after the first would
            // otherwise inherit the previous run's trial clock and beta flag.
            EntitlementAnchor.resetForUITesting()
            removeStoredSettingsFiles()
            removeStoredSessionData()
            // Hosted unit tests connect scripted straps through the real link
            // path, which records them as paired in the same simulator.
            StrapPairingStore.removeAll()
        #endif
    }

    /// Wipe the session archive and raw-RR backups so the UI target starts
    /// every test from a genuinely empty store.
    ///
    /// This is the precondition `Emuqu.xctestplan` names, and what lets that
    /// plan's `testExecutionOrdering: random` be wired into `Emuqu.xcscheme`:
    /// dashboard tests that read whatever the shared session archive happens
    /// to hold when they run are a coin flip under shuffling. The unit target
    /// has a hermetic archive (the `directory:` seam on `SessionArchive.init`)
    /// and survives repeated shuffles; the UI target drives a whole app per
    /// worker and cannot use that seam, so it needs the app to clear the
    /// store at launch instead.
    ///
    /// Safe by construction: the only caller is gated on
    /// `-UITests-FreshInstall`, which nothing but the UI suites passes. It runs
    /// from `EmuquMain.main()`, before any `EmuquApp` stored property touches
    /// `SessionArchive`s lazy `shared`, so the index is loaded from the empty
    /// directory rather than repopulated behind it.
    private static func removeStoredSessionData() {
        for name in [AppConfig.archiveDirectoryName, AppConfig.backupDirectoryName] {
            resetSharedDirectory(named: name)
        }
    }

    /// Delete and recreate one App Group directory.
    private static func resetSharedDirectory(named name: String) {
        let directory = AppConfig.sharedContainerURL().appendingPathComponent(name, isDirectory: true)
        do {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            NSLog("[App][launch] -UITests-FreshInstall could not reset \(name): \(error.localizedDescription)")
        }
    }

    /// UserDefaults keys that gate launch modals. Mirror `UserDefaultsKeys` in
    /// Constants.swift — keep the literal strings in sync if those constants
    /// are ever renamed.
    private static func clearLaunchModalDefaults() {
        let defaults = UserDefaults.standard
        let resetKeys = [
            UserDefaultsKeys.disclaimerAccepted, // "hasAcceptedHealthDisclaimer"
            UserDefaultsKeys.lastTrialReminderDate, // "lastTrialReminderDate"
            AssistantViewModel.disclaimerKey, // AI assistant first-use disclaimer
            // The paywall's "Skip (Debug)" grant. It persists, so one tap in
            // any earlier run on this simulator lifted every forced paywall
            // after it.
            "debug_isPurchased"
        ]
        for key in resetKeys {
            defaults.removeObject(forKey: key)
        }
        defaults.synchronize()
    }

    /// Most of the onboarding flags (`hasCompletedOnboarding`,
    /// `hasAcknowledgedScoreArchitectureChange`, `hasRunScoreHistoryRecompute`,
    /// `hasFixedTempAsymmetry`, `trialStartDate`) live in
    /// `user_settings.json` inside the App Group container — deleting the file
    /// makes SettingsManager load a fresh default UserSettings on next access.
    /// The legacy Documents copy goes too, in case an older install
    /// left one behind.
    private static func removeStoredSettingsFiles() {
        let settingsFile = AppConfig.sharedContainerURL().appendingPathComponent("user_settings.json")
        _ = attempt("AppLaunchRecovery.remove") { try FileManager.default.removeItem(at: settingsFile) }
        if let legacy = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("user_settings.json") {
            _ = attempt("AppLaunchRecovery.remove") { try FileManager.default.removeItem(at: legacy) }
        }
    }
}

/// The launch's one run of `SessionArchive.boot()` (the index retry and the
/// orphan-file adoption), off the main actor. Whichever needs it first starts
/// it: `EmuquApp.bootArchiveOffMain` after the first frame, or the
/// interrupted-recording check, which must not ask the archive whether it
/// holds a session before the orphans are adopted. Later calls return the
/// same task. The app has one archive, so the archive passed after the first
/// call is not used.
enum LaunchArchiveBoot {
    private static let boot = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    @discardableResult
    static func start(_ archive: SessionArchive) -> Task<Void, Never> {
        boot.withLock { running in
            if let running { return running }
            let started = Task.detached(priority: .utility) { archive.boot() }
            running = started
            return started
        }
    }
}
