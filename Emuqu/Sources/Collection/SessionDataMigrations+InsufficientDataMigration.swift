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
    /// Matched sessions are flipped to `.insufficient` and rescored with
    /// `useBaselineHRV: true`, then re-archived. Runs exactly once per install.
    func runInsufficientDataMigrationIfNeeded() async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.insufficientDataMigrationKey) else { return }
        // No baseline yet — can't evaluate the gate. Try again on next launch.
        guard let baseline = baselineTracker.recoveryBaselineStats else {
            debugLog("[InsufficientDataMigration] No baseline stats yet — skipping this launch")
            return
        }
        guard let candidates = insufficientDataCandidates(defaults: defaults) else { return }
        var rescored = 0
        for session in candidates {
            if rescoreIfInsufficient(session, baseline: baseline) { rescored += 1 }
            // Yield between sessions so we don't block launch.
            await Task.yield()
        }
        defaults.set(true, forKey: Self.insufficientDataMigrationKey)
        debugLog("[InsufficientDataMigration] Complete. Rescored \(rescored) of \(candidates.count) candidate sessions.")
    }

    /// Complete sessions that were accepted as good-quality — the only ones the
    /// gate can still reclassify. Nil marks the migration complete when there
    /// are none.
    private func insufficientDataCandidates(defaults: UserDefaults) -> [HRVSession]? {
        let candidates = archivedSessions.filter { s in
            s.state == .complete
                && s.analysisResult != nil
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
    /// and reanalysis paths.
    private func rescoreIfInsufficient(_ session: HRVSession, baseline: BaselineTracker.RecoveryBaselineStats) -> Bool {
        guard let result = session.analysisResult else { return false }
        guard ReanalysisService.hasInsufficientData(
            session: session,
            analysisResult: result,
            baselineRmssd: exp(baseline.lnRmssdMean)
        ) else { return false }
        var updated = session
        updated.hrvDataQuality = .insufficient
        applyBaselineRescore(&updated, result: result, baseline: baseline)
        do {
            try archive.archive(updated)
            debugLog("[InsufficientDataMigration] Rescored session \(session.id.uuidString.prefix(8)) — window too short or no organized recovery vs baseline")
            return true
        } catch {
            debugLog("[InsufficientDataMigration] Failed to archive rescored session \(session.id.uuidString.prefix(8)): \(error)")
            return false
        }
    }

    /// Rescore against the baseline instead of the session's own HRV. The
    /// acceptance-time ANS-balance term is preserved so the data-quality
    /// re-score doesn't ALSO shift the score by the HRV-factor ANS adjustment.
    private func applyBaselineRescore(
        _ updated: inout HRVSession,
        result: HRVAnalysisResult,
        baseline: BaselineTracker.RecoveryBaselineStats
    ) {
        let settings = settingsManager.settings
        let bestTraining = updated.trainingSnapshot ?? result.trainingContext
        let newBreakdown = RecoveryScoreCalculator.calculateWithBreakdown(
            RecoveryScoreCalculator.ScoreInputs(
                hrvReadiness: result.ansMetrics?.readinessScore, rmssd: result.timeDomain.rmssd,
                meanHR: result.timeDomain.meanHR, dfaAlpha1: result.nonlinear.dfaAlpha1,
                baselineStats: baseline, sleepData: updated.sleepSnapshot, vitals: updated.vitalsSnapshot,
                typicalSleepHours: settings.typicalSleepHours
            ),
            trainingContext: bestTraining,
            config: RecoveryScoreCalculator.ScoringConfiguration(from: settings),
            useBaselineHRV: true,
            ansBalance: Self.ansBalance(result)
        )
        updated.recoveryScore = RecoveryScoreCalculator.toTenScale(newBreakdown.compositeScore)
        updated.scoreBreakdown = newBreakdown
        updated.frozenReadiness = ReanalysisService.computeFrozenReadiness(
            compositeScore: newBreakdown.compositeScore, trainingContext: bestTraining
        )
    }

    private static func ansBalance(_ result: HRVAnalysisResult) -> Double? {
        guard let pns = result.ansMetrics?.pnsIndex, let sns = result.ansMetrics?.snsIndex else { return nil }
        return pns - sns
    }
}
