import Foundation

// MARK: - Insufficient-Data One-Shot Migration

extension SessionDataMigrations {
    /// Storage key for the one-shot migration flag.
    /// The `_v1` suffix leaves room for future gate revisions.
    private static let insufficientDataMigrationKey = "didRunInsufficientDataMigration_v1"

    /// One-time rescore for sessions archived before the insufficient-data gate
    /// existed (before April 5, 2026). After this runs, the gate is enforced at
    /// acceptance time by `SessionAcceptanceService` — so no per-load rewrite is
    /// needed.
    ///
    /// Criteria (same as `SessionAcceptanceService`):
    ///   • HRV window < 5 min, OR
    ///   • Session < 3 hours without organized recovery,
    ///   AND RMSSD below the recovery baseline.
    ///
    /// Matched sessions are flipped to `.insufficient` and rescored against
    /// the baseline, then re-archived. Runs exactly once per install.
    /// A night with no earlier nights to form its baseline is left as it is.
    func runInsufficientDataMigrationIfNeeded() async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.insufficientDataMigrationKey) else { return }
        // No baseline yet — can't evaluate the gate. Try again on next launch.
        guard baselineTracker.recoveryBaselineStats != nil else {
            debugLog("[InsufficientDataMigration] No baseline stats yet — skipping this launch")
            return
        }
        guard let candidates = insufficientDataCandidates(in: await loadArchivedSessions(), defaults: defaults) else { return }
        var rescored = 0
        for session in candidates {
            if rescoreIfInsufficient(session) { rescored += 1 }
            // Yield between sessions so we don't block launch.
            await Task.yield()
        }
        defaults.set(true, forKey: Self.insufficientDataMigrationKey)
        debugLog("[InsufficientDataMigration] Complete. Rescored \(rescored) of \(candidates.count) candidate sessions.")
    }

    /// Complete, scored nights that were accepted as good-quality — the only
    /// ones the gate can still reclassify. A quick reading or workout carries
    /// no recovery score and must not gain one here. Nil marks the migration
    /// complete when there are none.
    private func insufficientDataCandidates(in sessions: [HRVSession], defaults: UserDefaults) -> [HRVSession]? {
        let candidates = sessions.filter { s in
            s.state == .complete
                && s.analysisResult != nil
                && Self.carriesRecoveryScore(s)
                && (s.hrvDataQuality == .good || s.hrvDataQuality == nil)
        }
        guard !candidates.isEmpty else {
            defaults.set(true, forKey: Self.insufficientDataMigrationKey)
            debugLog("[InsufficientDataMigration] No candidates — marking migration complete")
            return nil
        }
        return candidates
    }

    /// The gate delegates to the
    /// one classifier so the migration cannot drift from the acceptance-time
    /// and reanalysis paths. The gate reads the night as loaded; the rescore
    /// is applied to the archived copy as it is at the write, so a change
    /// saved since the load (sleep or vitals refresh, a feeling, a pull) is
    /// kept rather than overwritten by the loaded copy.
    private func rescoreIfInsufficient(_ session: HRVSession) -> Bool {
        guard let result = session.analysisResult,
              let baseline = reanalysisService.scoringBaseline(for: session),
              ReanalysisService.hasInsufficientData(
                  session: session, analysisResult: result, baselineRmssd: exp(baseline.lnRmssdMean)
              ) else { return false }
        do {
            try archive.update(session.id, requestingReupload: false) { stored in
                stored.hrvDataQuality = .insufficient
                applyBaselineRescore(&stored)
            }
            debugLog("[InsufficientDataMigration] Rescored session \(session.id.uuidString.prefix(8)) — window too short or no organized recovery vs baseline")
            return true
        } catch {
            debugLog("[InsufficientDataMigration] Failed to archive rescored session \(session.id.uuidString.prefix(8)): \(error)")
            return false
        }
    }

    /// Rescore against the baseline instead of the session's own HRV, through
    /// the one re-score every reanalysis runs
    /// (`ReanalysisService.rescoredBreakdown`): `.insufficient` makes the
    /// nights before this one stand in for its HRV, the strap's nocturnal HR
    /// replaces a daytime resting HR, the acceptance-time ANS-balance term is
    /// kept, and the staleness penalty is measured at the night, not today —
    /// so an old night is not marked down for the time since.
    private func applyBaselineRescore(_ updated: inout HRVSession) {
        guard let result = updated.analysisResult else { return }
        let bestTraining = updated.trainingSnapshot ?? result.trainingContext
        let newBreakdown = reanalysisService.rescoredBreakdown(
            of: updated, result: result, training: bestTraining,
            referenceDate: updated.endDate ?? updated.startDate
        )
        updated.recoveryScore = RecoveryScoreCalculator.toTenScale(newBreakdown.compositeScore)
        updated.scoreBreakdown = newBreakdown
        updated.frozenReadiness = ReanalysisService.computeFrozenReadiness(
            compositeScore: newBreakdown.compositeScore, trainingContext: bestTraining
        )
    }
}
