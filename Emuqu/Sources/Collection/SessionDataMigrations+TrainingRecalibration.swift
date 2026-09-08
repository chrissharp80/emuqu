import Foundation

// MARK: - Training-Snapshot Recalibration (one-shot post-Banister-0.64 fix)

extension SessionDataMigrations {
    /// UserDefaults gate. Versioned so a future formula correction can
    /// ship a new `_v2` migration without re-running this one.
    private static let trainingRecalibrationKey = "didRunTrainingRecalibration_v1_banister064"

    /// One-shot: rewrite every archived session's frozen `trainingSnapshot`
    /// using the current TRIMP formula, then rescore the session with
    /// the corrected training context. Sessions whose scores never
    /// depended on training are untouched.
    ///
    /// Why this exists: an earlier `HealthKitManager.WorkoutSummary.calculateTrimp`
    /// lacked the 0.64 Banister scaling factor, so CTL/ATL values
    /// captured onto every morning session were inflated by ~1.56×.
    /// Historic sessions still carry those inflated numbers in their
    /// `trainingSnapshot` — which the AI's training tools and the
    /// reanalysis / rescoring flows read.  Left alone, the AI would
    /// report pre-fix CTLs when asked about historical dates, and any
    /// session that got re-scored against the corrected thresholds
    /// would land in the "novel load" (punishing) path because its
    /// stored CTL is higher than the current CTL — a silent drift.
    ///
    /// The migration is safe-idempotent:
    ///   • Gated by a UserDefaults flag.
    ///   • Only touches sessions with a non-nil `trainingSnapshot`.
    ///   • Recomputes using HealthKit's current TRIMP formula as-of
    ///     the session's start date (not "today").  That preserves the
    ///     original semantic: "how much fitness did I have THEN?".
    ///   • Rescoring uses the ExistingHRV path, not baseline-override,
    ///     so HRV data quality decisions (`useBaselineHRV` etc.) stay
    ///     true to what they were at acceptance time.
    ///
    /// Runs in the background well after launch (UI has to be live
    /// first — HealthKit calls can be several hundred ms each).
    func runTrainingRecalibrationIfNeeded() async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.trainingRecalibrationKey) else { return }
        guard let work = recalibrationWork(defaults: defaults) else { return }
        var touched = 0
        for session in work.candidates {
            if await recalibrate(session, baseline: work.baseline) { touched += 1 }
            // Yield between sessions so the migration is fully background-
            // friendly even with hundreds of entries to walk.
            await Task.yield()
        }
        defaults.set(true, forKey: Self.trainingRecalibrationKey)
        debugLog("[TrainingRecalibration] Complete. Touched \(touched) of \(work.candidates.count) candidate sessions.")
    }

    /// Sessions with a frozen snapshot are the only ones that carry
    /// potentially-wrong values; ones without training context skip the
    /// training term entirely and are correct as-is. Nil means there is nothing
    /// to do this launch — either no candidates (migration marked complete) or
    /// no baseline yet for the rescore path (retry next launch).
    private func recalibrationWork(defaults: UserDefaults) -> (candidates: [HRVSession], baseline: BaselineTracker.RecoveryBaselineStats)? {
        let candidates = archivedSessions.filter { $0.trainingSnapshot != nil }
        guard !candidates.isEmpty else {
            defaults.set(true, forKey: Self.trainingRecalibrationKey)
            debugLog("[TrainingRecalibration] No candidates — marking migration complete")
            return nil
        }
        guard let baseline = baselineTracker.recoveryBaselineStats else {
            debugLog("[TrainingRecalibration] No baseline stats yet — deferring to next launch")
            return nil
        }
        return (candidates, baseline)
    }

    /// Recompute CTL/ATL/TSB using the CURRENT formula, as of the session's own
    /// date. `forMorningReading: true` matches the acceptance-path call so the
    /// semantics are unchanged. Sessions where HealthKit can't produce
    /// meaningful numbers for that date — usually "too far back for the 120-day
    /// fetch window" — are skipped with their snapshot left alone.
    ///
    /// Returns whether the session was rewritten.
    private func recalibrate(_ session: HRVSession, baseline: BaselineTracker.RecoveryBaselineStats) async -> Bool {
        guard let result = session.analysisResult else { return false }
        let metrics = await healthKit.calculateTrainingMetrics(
            forMorningReading: true,
            relativeTo: session.startDate
        )
        guard metrics.ctl > 0 || metrics.atl > 0 else { return false }
        let newCtx = Self.recalibratedContext(metrics: metrics, old: session.trainingSnapshot)
        var mutable = session
        mutable.trainingSnapshot = newCtx
        applyRescore(&mutable, result: result, context: newCtx, baseline: baseline)
        do {
            try archive.archive(mutable)
            return true
        } catch {
            debugLog("[TrainingRecalibration] Failed to archive \(session.id.uuidString.prefix(8)): \(error)")
            return false
        }
    }

    /// Only the load numbers change; VO2max and workout history carry over from
    /// the frozen snapshot.
    private static func recalibratedContext(metrics: HealthKitManager.TrainingMetrics, old: TrainingContext?) -> TrainingContext {
        TrainingContext(
            atl: metrics.atl,
            ctl: metrics.ctl,
            tsb: metrics.tsb,
            yesterdayTrimp: metrics.todayTrimp,
            vo2Max: old?.vo2Max,
            daysSinceHardWorkout: old?.daysSinceHardWorkout,
            recentWorkouts: old?.recentWorkouts
        )
    }

    /// Rescore with the corrected training context so the stored
    /// `recoveryScore` and `scoreBreakdown` stay consistent with the new load
    /// numbers. Everything else (HRV quality, sleep, vitals) stays as it was at
    /// acceptance time.
    ///
    /// The acceptance-time ANS-balance term is preserved so only the training
    /// context changes — omitting it would move the score by the HRV-factor ANS
    /// adjustment on every recalibration.
    ///
    /// Scores off baseline for BOTH untrustworthy classes
    /// (`.insufficient` and `.preSleep`), matching SessionAcceptance's
    /// logic. Checking only `.insufficient` would let a re-scored `.preSleep`
    /// session flip to trusting its awake HRV.
    private func applyRescore(
        _ mutable: inout HRVSession,
        result: HRVAnalysisResult,
        context: TrainingContext,
        baseline: BaselineTracker.RecoveryBaselineStats
    ) {
        let settings = settingsManager.settings
        let newBreakdown = RecoveryScoreCalculator.calculateWithBreakdown(
            RecoveryScoreCalculator.ScoreInputs(
                hrvReadiness: result.ansMetrics?.readinessScore, rmssd: result.timeDomain.rmssd,
                meanHR: result.timeDomain.meanHR, dfaAlpha1: result.nonlinear.dfaAlpha1,
                baselineStats: baseline, sleepData: mutable.sleepSnapshot, vitals: mutable.vitalsSnapshot,
                typicalSleepHours: settings.typicalSleepHours
            ),
            trainingContext: context,
            config: RecoveryScoreCalculator.ScoringConfiguration(from: settings),
            useBaselineHRV: !mutable.isReliableForHRVAggregates,
            ansBalance: Self.ansBalance(result)
        )
        mutable.recoveryScore = RecoveryScoreCalculator.toTenScale(newBreakdown.compositeScore)
        mutable.scoreBreakdown = newBreakdown
        mutable.frozenReadiness = ReanalysisService.computeFrozenReadiness(
            compositeScore: newBreakdown.compositeScore, trainingContext: context
        )
    }

    private static func ansBalance(_ result: HRVAnalysisResult) -> Double? {
        guard let pns = result.ansMetrics?.pnsIndex, let sns = result.ansMetrics?.snsIndex else { return nil }
        return pns - sns
    }
}
