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
    ///   • Only touches scored overnight and nap sessions with a non-nil
    ///     `trainingSnapshot`. Workouts and quick readings carry a snapshot
    ///     too but never a recovery score, and must not gain one here.
    ///   • Recomputes using HealthKit's current TRIMP formula as of
    ///     the session's end (not "today"), the same anchor acceptance
    ///     uses. That preserves the original semantic: "how much fitness
    ///     did I have THEN?".
    ///   • Rescoring uses the ExistingHRV path, not baseline-override,
    ///     so HRV data quality decisions (`useBaselineHRV` etc.) stay
    ///     true to what they were at acceptance time.
    ///
    /// Runs in the background well after launch (UI has to be live
    /// first — HealthKit calls can be several hundred ms each).
    func runTrainingRecalibrationIfNeeded() async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.trainingRecalibrationKey) else { return }
        guard let work = recalibrationWork(in: await loadArchivedSessions(), defaults: defaults) else { return }
        var touched = 0
        for session in work.candidates {
            let prior = scoringBaseline(for: session)
            if let prior, await recalibrate(session, baseline: prior) { touched += 1 }
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
    private func recalibrationWork(
        in sessions: [HRVSession], defaults: UserDefaults
    ) -> (candidates: [HRVSession], baseline: BaselineTracker.RecoveryBaselineStats)? {
        let candidates = sessions.filter { $0.trainingSnapshot != nil && Self.carriesRecoveryScore($0) }
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

    /// Recompute the training context using the CURRENT formula, built exactly
    /// as acceptance builds it: `calculateTrainingLoad(relativeTo:)` anchored
    /// on the session's end (so the bedtime day's training counts), then
    /// `TrainingContext(from:relativeTo:)` for yesterday's TRIMP and the recent
    /// workouts. Sessions where HealthKit can't produce meaningful numbers for
    /// that date — usually "too far back for the fetch window" — are skipped
    /// with their snapshot left alone.
    ///
    /// Returns whether the session was rewritten.
    private func recalibrate(_ session: HRVSession, baseline: BaselineTracker.RecoveryBaselineStats) async -> Bool {
        guard let result = session.analysisResult else { return false }
        let anchor = Self.trainingAnchor(of: session)
        let load = await healthKit.calculateTrainingLoad(relativeTo: anchor)
        guard let newCtx = Self.recalibratedContext(load: load, anchor: anchor, old: session.trainingSnapshot) else {
            return false
        }
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

    /// The acceptance anchor: the session's end, or its start when it has none.
    nonisolated static func trainingAnchor(of session: HRVSession) -> Date {
        session.endDate ?? session.startDate
    }

    /// The load numbers come from the as-of-anchor training load; the VO2max
    /// frozen at acceptance (which may carry the user's override) is kept.
    /// Nil when the load has no metrics or no training at all on record.
    nonisolated static func recalibratedContext(
        load: HealthKitManager.TrainingLoad, anchor: Date, old: TrainingContext?
    ) -> TrainingContext? {
        guard let metrics = load.metrics, metrics.ctl > 0 || metrics.atl > 0,
              var context = TrainingContext(from: load, relativeTo: anchor) else { return nil }
        if let frozenVO2 = old?.vo2Max { context.vo2Max = frozenVO2 }
        return context
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

    /// Only sessions that were scored as a night are rescored by a migration.
    static func carriesRecoveryScore(_ session: HRVSession) -> Bool {
        (session.sessionType == .overnight || session.sessionType == .nap) && session.recoveryScore != nil
    }

    private static func ansBalance(_ result: HRVAnalysisResult) -> Double? {
        guard let pns = result.ansMetrics?.pnsIndex, let sns = result.ansMetrics?.snsIndex else { return nil }
        return pns - sns
    }
}
