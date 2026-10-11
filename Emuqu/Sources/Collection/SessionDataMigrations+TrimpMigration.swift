import Foundation

// MARK: - TRIMP Normalisation One-Shot Migration

extension SessionDataMigrations {
    /// Storage key for the one-shot TRIMP repair flag.
    /// Bumped when the TRIMP denominator was fixed to use the user's physiological
    /// max HR (from UserSettings.effectiveMaxHR) instead of the workout's own peak.
    /// The old fallback inverted scoring — easy activities with low peaks outscored
    /// hard ones with brief HR spikes.
    private static let trimpRepairMigrationKey = "didRunTrimpRepairMigration_v1"

    /// One-time repair for archived sessions whose `trainingSnapshot`,
    /// `analysisResult.trainingContext`, and `frozenReadiness` were computed
    /// with the broken TRIMP fallback (workout-peak HR as denominator).
    ///
    /// Delegates to `repairTrainingSnapshots`, which recomputes each session's
    /// training context from current HealthKit workout history using the fixed
    /// math. Runs exactly once per install.
    ///
    /// The flag check comes FIRST, before the archive is read at all, so a
    /// launch after the migration has run does no disk work. The archive is
    /// then read once and handed to the repair, which picks its own
    /// candidates (complete, analysed sessions); none is a completed run too.
    func runTrimpRepairMigrationIfNeeded() async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.trimpRepairMigrationKey) else { return }
        guard settingsManager.settings.enableTrainingLoadIntegration else {
            defaults.set(true, forKey: Self.trimpRepairMigrationKey)
            debugLog("[TrimpRepairMigration] Training load disabled — marking migration complete")
            return
        }
        let sessions = await loadArchivedSessions()
        debugLog("[TrimpRepairMigration] Starting — \(sessions.count) sessions in archive")
        let result = await reanalysisService.repairTrainingSnapshots(sessions: sessions) { _, _ in }
        defaults.set(true, forKey: Self.trimpRepairMigrationKey)
        debugLog("[TrimpRepairMigration] Complete. Repaired \(result.repaired) of \(result.candidates) candidates (\(result.errors) errors).")
    }
}
