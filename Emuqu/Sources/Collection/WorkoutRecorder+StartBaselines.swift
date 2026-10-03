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
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.computeAndCacheStartBaselines(sportForBaselines: sport, archive: archive)
        }
    }

    /// Reset Watch direct-strap fallback state so a previous workout's
    /// ingestion cursor doesn't carry over. The last wrist HR goes too: a
    /// reading left from an earlier workout must never be recorded as this
    /// one's heart rate.
    private func resetWatchStrapFallbackState() {
        watchBridge.latestWatchHR = nil
        lastConsumedWatchStrapAt = nil
        lastWatchRoutedHRAt = nil
        watchRoutedCumulativeMs = 0
        watchRoutedRRBuffer = []
        // Beats the Watch forwarded while no workout was running would
        // otherwise all land in this workout's first tick.
        _ = watchBridge.drainPendingWatchStrapRR()
    }

    /// start() — body of the background-baselines closure: history baselines, readiness, projection, and race predictions computed off-main, committed on the main actor.
    nonisolated private func computeAndCacheStartBaselines(sportForBaselines: Sport, archive: SessionArchive) async {
        let recent = Self.recentLightweightSessions(archive: archive)
        let baselines = WorkoutHistoryBaselines.compute(from: recent, sport: sportForBaselines, limit: 30)
        // Race-time predictions for sport-matched workouts. The Riegel formula
        // needs at least one comparable effort; returns empty otherwise so
        // downstream stays nil.
        let racePredictions = RaceTimePrediction.predict(from: recent, sport: sportForBaselines)
        let morning = Self.todaysMorningSession(in: recent)
        let readiness = Self.readinessSnapshot(morning: morning)
        let projection = Self.trainingProjection(morning: morning, readiness: readiness)
        await MainActor.run {
            self.commitStartBaselines(
                sportForBaselines: sportForBaselines,
                baselines: baselines,
                readiness: readiness,
                projection: projection,
                racePredictions: racePredictions
            )
        }
    }

    /// Guard against a stale write when the user starts
    /// workout B (different sport) before workout A's baseline task
    /// finishes. Without this check, a slow disk + a quick sport-swap
    /// could land workout A's run-baseline into workout B's bike
    /// recorder. Only commit if the sport this task was launched for is
    /// still the active sport.
    private func commitStartBaselines(
        sportForBaselines: Sport,
        baselines: WorkoutHistoryBaselines,
        readiness: ReadinessSnapshot,
        projection: TrainingProjectionSnapshot,
        racePredictions: [Double: Double]
    ) {
        guard currentSession?.sport == sportForBaselines else { return }
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
    nonisolated private static func recentLightweightSessions(archive: SessionArchive) -> [HRVSession] {
        archive.entries.prefix(60).compactMap { try? archive.retrieveLightweight($0.sessionId) }
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

    /// Forward-looking projection from today's ATL/CTL + the morning session's
    /// TRIMP (proxy for "what training load did today's workout add?"). Falls
    /// back to ATL itself when no TRIMP is available — gives the AI a useful
    /// "stay-the-course" projection rather than zero.
    nonisolated private static func trainingProjection(morning: HRVSession?, readiness: ReadinessSnapshot) -> TrainingProjectionSnapshot {
        guard let atl = readiness.atl, let ctl = readiness.ctl else { return .empty }
        let dailyTrimp = morning?.workoutMetadata?.luciaTRIMP ?? atl
        let tomorrow = TrainingLoadProjection.project(
            startingATL: atl, startingCTL: ctl, dailyTrimp: dailyTrimp, horizonDays: 1
        ).first?.tsb
        return TrainingProjectionSnapshot(
            daysUntilFresh: TrainingLoadProjection.daysUntilFresh(currentATL: atl, currentCTL: ctl),
            tsbTomorrowSteadyState: tomorrow
        )
    }
}
