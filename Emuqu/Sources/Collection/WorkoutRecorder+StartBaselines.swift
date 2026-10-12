import Foundation

// The start-path baseline precomputation: the detached work launched during
// the `tail` span (history baselines, race predictions, today's readiness and
// the training projection), computed off-main and committed back on the main
// actor.

extension WorkoutRecorder {
    /// start() — baseline-cache resets + detached baselines task (runs inside the sync-breakdown `tail` span).
    ///
    /// Pre-compute historical baselines for this sport
    /// so the AI can compare today's effort to past efforts without
    /// a per-tick archive scan. Backgrounded because
    /// `recentSessions(limit:)` deserializes JSON from disk.
    func resetCachedBaselinesAndLaunchBaselineTask(sport: Sport) {
        cachedHistoricalBaselines = WorkoutHistoryBaselines.empty
        cachedTodayReadiness = ReadinessSnapshot.empty
        cachedTrainingProjection = TrainingProjectionSnapshot.empty
        cachedRacePredictionsByDistance = [:]
        resetWatchStrapFallbackState()
        // SessionArchive owns its own lock — safe to read off the main
        // actor. We just need a stable reference to the archive instance.
        let archive = core.archive
        let sessionId = currentSession?.id
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.computeAndCacheStartBaselines(sportForBaselines: sport, sessionId: sessionId, archive: archive)
        }
    }

    /// Reset Watch direct-strap fallback state so a previous workout's
    /// ingestion cursor doesn't carry over. The last wrist HR goes too: a
    /// reading left from an earlier workout must never be recorded as this
    /// one's heart rate.
    private func resetWatchStrapFallbackState() {
        watchBridge.latestWatchHR = nil
        lastWatchRoutedHRAt = nil
        watchRoutedCumulativeMs = 0
        watchRoutedRRBuffer = []
        // Beats the Watch forwarded while no workout was running would
        // otherwise all land in this workout's first tick.
        _ = watchBridge.drainPendingWatchStrapRR()
    }

    /// start() — body of the background-baselines closure: history baselines, readiness, projection, and race predictions computed off-main, committed on the main actor.
    nonisolated private func computeAndCacheStartBaselines(sportForBaselines: Sport, sessionId: UUID?, archive: SessionArchive) async {
        let recent = Self.recentLightweightSessions(archive: archive)
        let baselines = WorkoutHistoryBaselines.compute(from: recent, sport: sportForBaselines, limit: 30)
        // Race-time predictions for sport-matched workouts. The Riegel formula
        // needs at least one comparable effort; returns empty otherwise so
        // downstream stays nil.
        let racePredictions = RaceTimePrediction.predict(from: recent, sport: sportForBaselines)
        let morning = Self.todaysMorningSession(in: recent)
        let readiness = Self.readinessSnapshot(morning: morning)
        let projection = Self.trainingProjection(readiness: readiness)
        await MainActor.run {
            self.commitStartBaselines(
                sessionId: sessionId,
                baselines: baselines,
                readiness: readiness,
                projection: projection,
                racePredictions: racePredictions
            )
        }
    }

    /// Guard against a stale write when the user starts
    /// workout B before workout A's baseline task finishes. Without this
    /// check, a slow disk + a quick restart could land workout A's
    /// baselines (another sport's, or ones from before A was archived)
    /// into workout B's recorder. Only commit if the workout this task was
    /// launched for is still the current one.
    private func commitStartBaselines(
        sessionId: UUID?,
        baselines: WorkoutHistoryBaselines,
        readiness: ReadinessSnapshot,
        projection: TrainingProjectionSnapshot,
        racePredictions: [Double: Double]
    ) {
        guard let sessionId, currentSession?.id == sessionId else { return }
        cachedHistoricalBaselines = baselines
        cachedTodayReadiness = readiness
        cachedTrainingProjection = projection
        cachedRacePredictionsByDistance = racePredictions
    }

    /// Uses `retrieveLightweight()` (~50 ms each, ~3 s total), not 60 ×
    /// `archive.retrieve()` (full, ~300 ms each = ~18 s of archive-lock
    /// contention during a workout startup).
    /// `WorkoutHistoryBaselines.compute`, `RaceTimePrediction.predict`, and the
    /// morning-readiness pull all read `workoutMetadata` / `analysisResult` /
    /// `trainingSnapshot` / scoring fields — none of them touch the raw
    /// `rrSeries` blob. Skipping that decode is a pure perf win and reduces the
    /// lock contention that was bleeding into the user-perceived start time.
    ///
    /// Picked from the index by type: the 60 newest workouts (the baselines
    /// and race predictions use workouts only, and taking the 60 newest
    /// entries of every type left a user with daily overnight and quick
    /// readings 3–4 weeks of workouts), plus the overnight and quick
    /// readings that ended today, for the readiness snapshot.
    nonisolated private static func recentLightweightSessions(archive: SessionArchive) -> [HRVSession] {
        let entries = archive.entries
        let today = Calendar.current.startOfDay(for: Date())
        let workouts = entries.filter { $0.sessionType == .workout }.prefix(60)
        let mornings = entries.filter {
            ($0.sessionType == .overnight || $0.sessionType == .quick) && ($0.endDate ?? $0.date) >= today
        }
        return (Array(workouts) + mornings).compactMap { try? archive.retrieveLightweight($0.sessionId) }
    }

    /// Today's morning HRV session for the readiness snapshot — the most-recent
    /// `.overnight` or `.quick` session ending today. Inlined rather than
    /// sharing the dashboard's selection because we have no view here and the
    /// rule is three lines.
    nonisolated private static func todaysMorningSession(in recent: [HRVSession]) -> HRVSession? {
        let today = Calendar.current.startOfDay(for: Date())
        return recent
            .filter { $0.state == .complete || $0.state == .paused }
            .filter { $0.sessionType == .overnight || $0.sessionType == .quick }
            .filter { ($0.endDate ?? .distantPast) >= today }
            .sorted { ($0.endDate ?? .distantPast) > ($1.endDate ?? .distantPast) }
            .first
    }

    /// HRV ANS readiness is on a 0-10 scale; it's rescaled here to match the
    /// recovery-score 0-100 range so the AI doesn't confuse the two.
    nonisolated private static func readinessSnapshot(morning: HRVSession?) -> ReadinessSnapshot {
        ReadinessSnapshot(
            recoveryScore: morning?.recoveryScore.map { $0 * 10 },
            trainingReadiness: morning?.readinessScore.map { $0 * 10 },
            atl: morning?.trainingSnapshot?.atl,
            ctl: morning?.trainingSnapshot?.ctl,
            tsb: morning?.trainingSnapshot?.tsb
        )
    }

    /// Forward-looking projection from the morning reading's ATL/CTL, with
    /// ATL itself as the daily load — a "stay-the-course" projection rather
    /// than zero. (The morning reading is an overnight or quick session,
    /// which carries no workout TRIMP to use instead.)
    nonisolated private static func trainingProjection(readiness: ReadinessSnapshot) -> TrainingProjectionSnapshot {
        guard let atl = readiness.atl, let ctl = readiness.ctl else { return .empty }
        let dailyTrimp = atl
        let tomorrow = TrainingLoadProjection.project(
            startingATL: atl, startingCTL: ctl, dailyTrimp: dailyTrimp, horizonDays: 1
        ).first?.tsb
        return TrainingProjectionSnapshot(
            daysUntilFresh: TrainingLoadProjection.daysUntilFresh(currentATL: atl, currentCTL: ctl),
            tsbTomorrowSteadyState: tomorrow
        )
    }
}
