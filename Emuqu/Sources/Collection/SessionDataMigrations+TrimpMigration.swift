import Foundation

// MARK: - TRIMP Normalisation One-Shot Migration

extension SessionDataMigrations {
    /// Storage key for the one-shot TRIMP repair flag.
    /// The repair recomputes TRIMP with the user's physiological max HR (from
    /// UserSettings.effectiveMaxHR) as the denominator instead of the workout's
    /// own peak. The workout-peak fallback inverted scoring: easy activities with
    /// low peaks outscored hard ones with brief HR spikes.
    private static let trimpRepairMigrationKey = "didRunTrimpRepairMigration_v1"

    /// One-time repair for archived sessions whose `trainingSnapshot`,
    /// `analysisResult.trainingContext`, and `frozenReadiness` were computed
    /// with a TRIMP fallback that used workout-peak HR as the denominator.
    ///
    /// Delegates to `repairTrainingSnapshots`, which recomputes each session's
    /// training context from current HealthKit workout history using the
    /// current math. A night HealthKit did not answer for is left as stored,
    /// and the migration then runs again on a later launch, up to
    /// `maxTrainingMigrationAttempts` (`finishTrainingMigration`). It also
    /// runs again while the training recalibration has not finished, so its
    /// context stays the one the archive keeps (see the ordering note on
    /// `SessionDataMigrations`).
    ///
    /// The flag check comes FIRST, before the archive is read at all, so a
    /// launch after the migration has run does no disk work. The archive is
    /// then handed to the repair, which picks its own candidates (complete,
    /// analysed sessions); none is a completed run too.
    func runTrimpRepairMigrationIfNeeded() async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.trimpRepairMigrationKey) else { return }
        guard settingsManager.settings.enableTrainingLoadIntegration else {
            defaults.set(true, forKey: Self.trimpRepairMigrationKey)
            debugLog("[TrimpRepairMigration] Training load disabled — marking migration complete")
            return
        }
        let sessions = archivedSessions
        debugLog("[TrimpRepairMigration] Starting — \(sessions.count) sessions in archive")
        let result = await reanalysisService.repairTrainingSnapshots(sessions: sessions) { _, _ in }
        let finished = Self.finishTrainingMigration(
            key: Self.trimpRepairMigrationKey, complete: result.coversEverySession && trainingRecalibrationFinished
        )
        debugLog("[TrimpRepairMigration] \(finished ? "Complete" : "Pass done, runs again"). Repaired \(result.repaired) of \(result.candidates) candidates (\(result.unanswered) unanswered, \(result.errors) errors).")
    }
}
