import Foundation
import SwiftUI

// Interrupted-session recovery: the launch-time "we found an unfinished
// recording" alert and the resume, recover and dismiss actions behind it.

extension EmuquApp {
    /// Check if a recording session was in progress when the app was killed.
    /// Persisted state survives crashes — if it exists on launch, the session was interrupted.
    ///
    /// Dismiss means "stop re-prompting me." Re-prompting on every launch
    /// (and re-writing the termination report on every launch) is exactly
    /// the loop the user complained about ("discarding for hours"). So
    /// both the alert AND the
    /// termination report are skipped when this session was previously
    /// dismissed. The backup is still recoverable via Settings → Lost Sessions
    /// for users who change their mind.
    /// Note, at launch, any archived workout that captured essentially nothing
    /// and could be rebuilt from Apple Health.
    ///
    /// The Fitness tab shows a card for these, but only once the user goes
    /// there. A recording that died is exactly the thing a user does not go
    /// looking for — they assume the app lost it — so the fact is recorded at
    /// startup where a debug log will always carry it, whether or not anyone
    /// opened the tab.
    private func logRebuildableWorkouts() {
        let importer = HealthWorkoutImporter(manager: AppDependencies.current.collection.healthKitManager)
        let stubs = importer.interruptedSessions(archive: collector.archive)
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

    func checkForInterruptedSession() {
        logRebuildableWorkouts()
        guard let state = collector.getPersistedRecordingState() else { return }
        // Only alert if the session isn't already archived (e.g. auto-archived on background)
        guard !collector.archive.exists(state.sessionId) else {
            collector.clearPersistedRecordingStatePublic()
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
        Task {
            let success = await collector.recoverToPausedState(info.sessionId, sessionType: info.sessionType)
            await MainActor.run { showRecoveryOutcome(success: success) }
        }
    }

    @MainActor
    private func showRecoveryOutcome(success: Bool) {
        recoveryResultMessage = success
            ? String(localized: "Your session data has been restored. Go to the Record tab to resume or finish.", bundle: languageManager.bundle)
            : String(localized: "Could not restore the session. Check Settings → Lost Sessions for manual recovery.", bundle: languageManager.bundle)
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
        let outcome = await WorkoutRecoveryService.recover(
            sessionId: info.sessionId,
            reason: .userInterrupted,
            archive: collector.archive,
            rawBackup: collector.rawBackup,
            cloudSyncManager: syncManager
        )
        collector.clearPersistedRecordingStatePublic()
        guard let outcome else {
            return String(localized: "Could not recover the workout. The backup data may be incomplete. Check Settings → Lost Sessions for manual recovery.", bundle: languageManager.bundle)
        }
        return outcome.wasArchived
            ? outcome.summaryLine + " Saved to your archive."
            : outcome.summaryLine + " Saved locally; iCloud sync will retry."
    }

    private func recoverInterruptedRecording(_ info: InterruptedSessionInfo) async -> String {
        let recovered = await collector.recoverFromBackup(info.sessionId)
        collector.clearPersistedRecordingStatePublic()
        guard recovered != nil else {
            return String(localized: "Could not recover the session. The backup data may be incomplete. Check Settings → Lost Sessions for manual recovery.", bundle: languageManager.bundle)
        }
        return "Your \(info.sessionType.displayName.lowercased()) session has been saved to your archive."
    }

    func dismissInterruptedSession() {
        // Not just `interruptedSessionAlert = nil`: that closes the
        // alert in-memory but leaves the persisted state on disk so
        // EVERY subsequent launch re-detects it and re-fires the same
        // alert (user-reported as "I have been discarding/dismissing
        // that fucking thing for hours.")
        // Record the dismissal so the alert never fires again
        // for this sessionId. The backup data stays on disk so
        // Settings → Lost Sessions can still recover it if the user
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
    /// launch argument (set only by the `OnboardingFlowUITests` target) wipes
    /// the onboarding/disclaimer/paywall flags so the next launch walks the
    /// new-install path. A no-op when the flag is absent — production launches
    /// are untouched.
    static func resetUITestStateIfRequested() {
        guard CommandLine.arguments.contains("-UITests-FreshInstall") else { return }
        NSLog("[App][launch] -UITests-FreshInstall — wiping onboarding/disclaimer/paywall state")
        clearLaunchModalDefaults()
        // The entitlement anchor is built to survive app deletion, so a
        // reinstall cannot clear it and every run after the first would
        // otherwise inherit the previous run's trial clock and beta flag.
        // DEBUG-only; see `EntitlementAnchor.resetForUITesting()`.
        #if DEBUG
            EntitlementAnchor.resetForUITesting()
        #endif
        removeStoredSettingsFiles()
        removeStoredSessionData()
        // Hosted unit tests connect scripted straps through the real link
        // path, which records them as paired in the same simulator.
        StrapPairingStore.removeAll()
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

    /// Delete and recreate one App Group directory. Split out of
    /// `removeStoredSessionData` to keep both inside the spec nesting limit —
    /// loop, then do, then the existence check was three levels deep.
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
            "assistant.disclaimerAccepted" // AI assistant first-use disclaimer
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
