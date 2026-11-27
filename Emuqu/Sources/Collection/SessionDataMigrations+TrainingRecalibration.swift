import Foundation

// MARK: - Training-Snapshot Recalibration (one-shot post-Banister-0.64 fix)

extension SessionDataMigrations {
    /// UserDefaults gate. Versioned so a future formula correction can
    /// ship a new `_v2` migration without re-running this one.
    private static let trainingRecalibrationKey = "didRunTrainingRecalibration_v1_banister064"

    /// One-shot: rewrite every archived session's frozen `trainingSnapshot`
    /// using the current TRIMP formula, and the frozen readiness that is
    /// derived from it. The recovery score is left as it is: the composite
    /// does not read the training context
    /// (`RecoveryScoreCalculator.calculateWithBreakdown`), so rescoring here
    /// would only have moved it for reasons that have nothing to do with
    /// training (today's settings and baseline, the time since the night).
    ///
    /// Sessions archived by builds whose `WorkoutSummary.calculateTrimp` lacked
    /// the 0.64 Banister scaling factor carry CTL/ATL inflated by ~1.56× in
    /// their `trainingSnapshot`, which the AI's training tools and the
    /// reanalysis / rescoring flows read. Left alone, the AI would report
    /// inflated CTLs for historical dates, and any session re-scored against
    /// the corrected thresholds would land in the "novel load" (punishing)
    /// path because its stored CTL is higher than the current CTL — a silent
    /// drift.
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
    ///   • The corrected context is applied to the archived copy as it is at
    ///     the write, not to the copy loaded before the HealthKit query, so
    ///     a change saved meanwhile is kept.
    ///
    ///   • A night HealthKit did not answer the workout query for (the store
    ///     locked, a timeout) is left as stored: read as no workouts, its load
    ///     would be the archive's workouts alone. The flag is then left unset
    ///     and the migration runs again on a later launch, up to
    ///     `maxTrainingMigrationAttempts` (`finishTrainingMigration`).
    ///
    /// Runs in the background well after launch (UI has to be live
    /// first — HealthKit calls can be several hundred ms each).
    func runTrainingRecalibrationIfNeeded() async {
        guard !trainingRecalibrationFinished else { return }
        let sessions = archivedSessions
        var tally = (candidates: 0, touched: 0, unanswered: 0)
        for index in 0 ..< sessions.count {
            guard let session = await sessions.session(at: index), Self.isRecalibrationCandidate(session) else { continue }
            tally.candidates += 1
            switch await recalibrate(session) {
            case .rewritten: tally.touched += 1
            case .unanswered: tally.unanswered += 1
            case .leftAsStored: break
            }
        }
        let finished = Self.finishTrainingMigration(key: Self.trainingRecalibrationKey, complete: tally.unanswered == 0)
        debugLog("[TrainingRecalibration] \(finished ? "Complete" : "Pass done, runs again"). Touched \(tally.touched) of \(tally.candidates) candidate sessions (\(tally.unanswered) unanswered).")
    }

    /// Whether the recalibration has run to completion (or given up retrying).
    var trainingRecalibrationFinished: Bool {
        UserDefaults.standard.bool(forKey: Self.trainingRecalibrationKey)
    }

    /// What one night's recalibration did.
    enum RecalibrationOutcome {
        case rewritten
        /// Nothing to correct, no load for that date, or the write failed.
        case leftAsStored
        /// HealthKit did not answer the workout query; the night is retried.
        case unanswered
    }

    /// Sessions with a frozen snapshot are the only ones that carry
    /// potentially-wrong values; ones without training context skip the
    /// training term entirely and are correct as-is.
    private static func isRecalibrationCandidate(_ session: HRVSession) -> Bool {
        session.trainingSnapshot != nil && carriesRecoveryScore(session)
    }

    /// Recompute the training context using the CURRENT formula, built exactly
    /// as acceptance builds it: `calculateTrainingLoad(relativeTo:)` anchored
    /// on the session's end (so the bedtime day's training counts), then
    /// `TrainingContext(from:relativeTo:)` for yesterday's TRIMP and the recent
    /// workouts. Sessions where HealthKit can't produce meaningful numbers for
    /// that date — usually "too far back for the fetch window" — are skipped
    /// with their snapshot left alone.
    ///
    /// A date HealthKit did not answer the workout query for leaves the
    /// session as stored (`calculateTrainingLoadIfAnswered`).
    private func recalibrate(_ session: HRVSession) async -> RecalibrationOutcome {
        guard session.analysisResult != nil else { return .leftAsStored }
        let anchor = Self.trainingAnchor(of: session)
        guard let load = await healthKit.calculateTrainingLoadIfAnswered(relativeTo: anchor) else { return .unanswered }
        guard let newCtx = Self.recalibratedContext(load: load, anchor: anchor, old: session.trainingSnapshot) else {
            return .leftAsStored
        }
        do {
            try archive.update(session.id, requestingReupload: false) { stored in
                Self.applyCorrectedContext(newCtx, to: &stored)
            }
            return .rewritten
        } catch {
            debugLog("[TrainingRecalibration] Failed to archive \(session.id.uuidString.prefix(8)): \(error)")
            return .leftAsStored
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

    /// The corrected context goes on the snapshot and the analysis result,
    /// and the frozen readiness, which does read the load, is recomputed from
    /// the night's own composite. The recovery score and its breakdown stay.
    private static func applyCorrectedContext(_ context: TrainingContext, to stored: inout HRVSession) {
        stored.trainingSnapshot = context
        stored.analysisResult?.trainingContext = context
        guard let composite = stored.scoreBreakdown?.compositeScore else { return }
        stored.frozenReadiness = ReanalysisService.computeFrozenReadiness(compositeScore: composite, trainingContext: context)
    }

    /// Only sessions that were scored as a night are rescored by a migration.
    static func carriesRecoveryScore(_ session: HRVSession) -> Bool {
        (session.sessionType == .overnight || session.sessionType == .nap) && session.recoveryScore != nil
    }
}
