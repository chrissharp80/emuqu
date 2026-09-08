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
    /// The flag check comes FIRST. Interpolating `archivedSessions.count`
    /// into the entry log message forces loading every session file from disk
    /// on every launch, even after the migration has run — on a 118-session
    /// archive that is ~300 ms of dead work + log noise every cold start. Same
    /// pattern as the other two migrations: early-return on the flag before
    /// touching the archive.
    func runTrimpRepairMigrationIfNeeded() async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.trimpRepairMigrationKey) else { return }
        guard hasTrimpRepairWork(defaults: defaults) else { return }
        let result = await repairTrainingSnapshots { _, _ in }
        defaults.set(true, forKey: Self.trimpRepairMigrationKey)
        debugLog("[TrimpRepairMigration] Complete. Repaired \(result.repaired) of \(result.candidates) candidates (\(result.errors) errors).")
    }

    /// False marks the migration complete: either training-load integration is
    /// off (nothing to repair) or the archive holds no analysed sessions.
    private func hasTrimpRepairWork(defaults: UserDefaults) -> Bool {
        guard settingsManager.settings.enableTrainingLoadIntegration else {
            defaults.set(true, forKey: Self.trimpRepairMigrationKey)
            debugLog("[TrimpRepairMigration] Training load disabled — marking migration complete")
            return false
        }
        debugLog("[TrimpRepairMigration] Starting — \(archivedSessions.count) sessions in archive")
        let candidates = archivedSessions.filter { $0.state == .complete && $0.analysisResult != nil }
        guard !candidates.isEmpty else {
            defaults.set(true, forKey: Self.trimpRepairMigrationKey)
            debugLog("[TrimpRepairMigration] No candidates — marking migration complete")
            return false
        }
        debugLog("[TrimpRepairMigration] Repairing \(candidates.count) sessions with corrected TRIMP math")
        return true
    }
}
