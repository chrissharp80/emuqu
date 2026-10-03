import Foundation

/// ViewModel for MorningResultsView — manages data loading, recovery scoring,
/// and HealthKit integration so the view only handles presentation.
@Observable
@MainActor
final class MorningResultsViewModel {
    // MARK: - Input

    let session: HRVSession
    let result: HRVAnalysisResult
    let recentSessions: [HRVSession]

    // MARK: - Published State

    var selectedTags: Set<ReadingTag>
    var notes: String
    var reanalyzedSession: HRVSession?
    var selectedMethod: WindowSelectionMethod
    var isReanalyzing = false
    var isGeneratingPDF = false
    var isGeneratingEmailPDF = false
    var healthKitSleep: SleepData?
    var sleepTrendStats: HealthKitManager.SleepTrendStats?
    var recoveryVitals: RecoveryVitals?
    var isSleepLoading = true

    /// Recovery baseline stats for z-score scoring (set externally from BaselineTracker)
    var baselineStats: BaselineTracker.RecoveryBaselineStats?

    /// Set by the view to the collector's sleep-boundary writer. Called when
    /// a live fetch finds measured Apple Health sleep for today's session, so
    /// the stored boundaries and the score use the more complete night.
    var onUpdateSleep: ((SleepData) -> Void)?

    // MARK: - Computed Properties

    var displaySession: HRVSession {
        reanalyzedSession ?? session
    }

    var displayResult: HRVAnalysisResult {
        displaySession.analysisResult ?? result
    }

    var hasRawData: Bool {
        guard let series = displaySession.rrSeries else { return false }
        return !series.points.isEmpty
    }

    /// Reference date for HealthKit queries. Uses the session's end date (morning of recording)
    /// so historical sessions fetch data from their actual night, not today.
    var sessionReferenceDate: Date {
        session.endDate ?? session.startDate
    }

    /// Whether this is a historical session (not from today)
    var isHistoricalSession: Bool {
        !Calendar.current.isDateInToday(sessionReferenceDate)
    }

    // Note: morningFeeling is ONLY edited on the Dashboard while the session
    // is today's. Once it rolls off the dashboard, the feeling is frozen.
    // MorningResultsView shows the badge read-only; no update method here.

    /// Update the user's subjective readiness and persist to archive.
    func updatePerceivedReadiness(_ value: Double?) {
        reanalyzedSession = {
            var s = displaySession
            s.perceivedReadiness = value
            return s
        }()
        guard let value else { return }
        // Persist to archive in background
        let sessionId = session.id
        let fallbackSession = displaySession
        Task.detached {
            let archive = AppDependencies.current.storage.sessionArchive
            do {
                var stored = try archive.retrieve(sessionId) ?? fallbackSession
                stored.perceivedReadiness = value
                try archive.archive(stored, skipSameNightMerge: false, requestingReupload: true)
                debugLog("[MorningResultsVM] Persisted perceivedReadiness=\(String(format: "%.2f", value))")
            } catch {
                debugLog("[MorningResultsVM] Failed to persist perceivedReadiness: \(error)")
            }
        }
    }

    private var settings: UserSettings {
        settingsManager.settings
    }

    var scoringConfig: RecoveryScoreCalculator.ScoringConfiguration {
        RecoveryScoreCalculator.ScoringConfiguration(from: settings)
    }

    /// Composite recovery score (0-100) combining HRV (60%), sleep (25%), and vitals (15%) under the v3.oct2026 architecture.
    /// Once a session has a frozen score (from acceptance or sleep adjustment),
    /// always use it so all views show the same number.
    /// Read from `displaySession`, not the immutable
    /// `session` input. `reanalyzedSession` is set whenever the user
    /// re-analyzes from this view OR (after the archive observer
    /// wiring below) when an external surface like the dashboard
    /// re-analyzes / refreshes sleep on the same recording. Reading
    /// `session.recoveryScore` here would lock the displayed number
    /// to whatever was archived at sheet-presentation time, ignoring
    /// every later update.
    var compositeRecoveryScore: Double {
        if let frozen = displaySession.recoveryScore {
            // Guard the frozen branch. A score archived by a build that predates
            // NaN sanitization can be non-finite,
            // and the recovery-score ring does `Int(score)` / `.trim(score/100)`,
            // both of which HARD-CRASH on NaN/Inf. Every other route to the ring is
            // finiteness-guarded; unguarded, this one is the reproducible
            // "reopen an old quick reading → See Full Report → flash → crash".
            return ScoreVerdict.clampedDisplayScore(frozen * 10.0)
        }

        return liveRecoveryScore
    }

    /// No frozen score yet (pre-acceptance) — calculate live. Includes the
    /// ANS-balance term so this live number matches the score the acceptance
    /// path freezes; otherwise the hero number visibly jumps on "Accept".
    private var liveRecoveryScore: Double {
        let trainingContext = displaySession.trainingSnapshot ?? displayResult.trainingContext
        return RecoveryScoreCalculator.calculate(
            RecoveryScoreCalculator.ScoreInputs(
                hrvReadiness: displayResult.ansMetrics?.readinessScore, rmssd: displayResult.timeDomain.rmssd,
                meanHR: displayResult.timeDomain.meanHR, dfaAlpha1: displayResult.nonlinear.dfaAlpha1,
                baselineStats: baselineStats, sleepData: healthKitSleep, vitals: recoveryVitals,
                typicalSleepHours: settings.typicalSleepHours
            ),
            trainingContext: trainingContext,
            config: scoringConfig,
            ansBalance: liveAnsBalance
        )
    }

    /// ANS-balance term (pns − sns) for pre-acceptance live scoring, matching
    /// the acceptance path. Nil when the ANS indices aren't both available.
    private var liveAnsBalance: Double? {
        guard let pns = displayResult.ansMetrics?.pnsIndex,
              let sns = displayResult.ansMetrics?.snsIndex else { return nil }
        return pns - sns
    }

    /// Prefer stored breakdown — it was computed at acceptance time with the
    /// exact same inputs as the frozen score, so factors and composite agree.
    /// Read from `displaySession` so a re-analysis (local OR pushed in
    /// via the archive observer) replaces the breakdown along with the
    /// composite score. Reading the immutable `session` input would freeze
    /// the breakdown card at sheet-open time — same swap as
    /// `compositeRecoveryScore`.
    func recoveryBreakdown() -> RecoveryScoreCalculator.ScoreBreakdown {
        if let stored = displaySession.scoreBreakdown {
            return stored
        }
        return pinnedToFrozenScore(liveBreakdown())
    }

    /// Re-score from what's on screen right now. Prefers frozen snapshots when
    /// available so the breakdown matches the frozen composite score — the
    /// snapshot contains user adjustments (excluded segments) and is the
    /// scoring source of truth.
    private func liveBreakdown() -> RecoveryScoreCalculator.ScoreBreakdown {
        let trainingContext = displaySession.trainingSnapshot ?? displayResult.trainingContext
        let effectiveSleep = displaySession.sleepSnapshot ?? healthKitSleep
        let effectiveVitals = displaySession.vitalsSnapshot ?? recoveryVitals
        return RecoveryScoreCalculator.calculateWithBreakdown(
            RecoveryScoreCalculator.ScoreInputs(
                hrvReadiness: displayResult.ansMetrics?.readinessScore, rmssd: displayResult.timeDomain.rmssd,
                meanHR: displayResult.timeDomain.meanHR, dfaAlpha1: displayResult.nonlinear.dfaAlpha1,
                baselineStats: baselineStats, sleepData: effectiveSleep, vitals: effectiveVitals,
                typicalSleepHours: settings.typicalSleepHours
            ),
            trainingContext: trainingContext,
            config: scoringConfig,
            ansBalance: liveAnsBalance
        )
    }

    /// For legacy sessions without a stored breakdown: the frozen score may
    /// have been computed with different baseline stats, so the live composite
    /// can diverge. Pin the breakdown composite to the frozen score so the
    /// message and factor display are consistent with the displayed number.
    private func pinnedToFrozenScore(
        _ live: RecoveryScoreCalculator.ScoreBreakdown
    ) -> RecoveryScoreCalculator.ScoreBreakdown {
        guard let frozen = displaySession.recoveryScore else { return live }
        let frozenOn100 = frozen * 10.0
        guard abs(live.compositeScore - frozenOn100) > 1 else { return live }
        return RecoveryScoreCalculator.ScoreBreakdown(
            compositeScore: frozenOn100,
            tier: live.tier,
            factors: live.factors,
            penalties: live.penalties
        )
    }

    var analysisSummary: AnalysisSummaryGenerator.AnalysisSummary {
        let summary = summaryGenerator.generate()
        // Share with the Assistant so it can reference any session the user has
        // ever opened in MorningResultsView (today, history reviews, etc.).
        AppDependencies.current.assistant.analysisSummaryCache.set(
            summary, forSessionId: displaySession.id,
            fingerprint: AnalysisSummaryCache.fingerprint(for: displaySession)
        )
        return summary
    }

    /// `liveLoadSnapshot` feeds the cumulative-load gate the live
    /// snapshot: free on @MainActor, and it lets the gate reflect every archive
    /// write since the last cache refresh rather than the frozen value captured
    /// at session acceptance.
    ///
    /// `todayReadiness` feeds today's overnight session the live readiness
    /// and today's TRIMP, so the steps switch to post-workout recovery advice
    /// after a hard session. It changes the summary text only, not a score.
    ///
    /// `canonicalBaseline*` (#2) threads the canonical score baseline
    /// (geometric ln(RMSSD) mean + meanHRBaseline) so the narrative agrees with
    /// the score instead of recomputing an arithmetic mean that reads high.
    private var summaryGenerator: AnalysisSummaryGenerator {
        let currentSettings = settings
        let readiness = todayReadiness
        return AnalysisSummaryGenerator(
            result: displayResult,
            session: displaySession,
            recentSessions: recentSessions,
            selectedTags: selectedTags,
            sleep: AnalysisSleepInput(from: healthKitSleep),
            sleepTrend: AnalysisSleepTrendInput(from: sleepTrendStats),
            trainingContext: displaySession.trainingSnapshot ?? displayResult.trainingContext,
            userAge: currentSettings.age,
            biologicalSex: currentSettings.biologicalSex,
            currentReadiness: readiness?.score,
            todayTrimp: readiness?.todayTrimp ?? 0,
            liveLoadSnapshot: TrainingLoadRegistry.live(),
            canonicalBaselineRMSSD: baselineStats.map { exp($0.lnRmssdMean) },
            canonicalBaselineHR: baselineStats.map(\.meanHRBaseline)
        )
    }

    /// Live readiness for today's overnight session; nil for any other
    /// session, where the morning steps stand.
    private var todayReadiness: LiveReadiness? {
        guard displaySession.sessionType == .overnight, !isHistoricalSession else { return nil }
        return LiveReadiness.compute(
            recoveryScore: compositeRecoveryScore,
            morningSession: displaySession,
            liveMetrics: AppDependencies.current.analysis.trainingMetricsCache.current
        )
    }

    // MARK: - Services

    private let settingsManager: SettingsManager
    let healthKit: HealthKitManager

    // MARK: - Initialization

    @MainActor
    init(
        session: HRVSession,
        result: HRVAnalysisResult,
        recentSessions: [HRVSession] = [],
        settingsManager: SettingsManager = AppDependencies.current.app.settingsManager,
        healthKit: HealthKitManager = AppDependencies.current.collection.healthKitManager
    ) {
        self.session = session
        self.result = result
        self.recentSessions = recentSessions
        self.settingsManager = settingsManager
        self.healthKit = healthKit
        selectedTags = Set(session.tags)
        notes = session.notes ?? ""
        selectedMethod = settingsManager.settings.defaultWindowSelectionMethod
        seedFrozenSnapshots(session)
    }

    /// Seed observable fields from frozen snapshots synchronously so the first
    /// render has them. Without this, the chart's .task(id:) sees
    /// healthKitSleep=nil on first pass, then restarts the full stats
    /// computation (including WindowSelector) the moment the snapshot arrives —
    /// two expensive passes per open.
    private func seedFrozenSnapshots(_ session: HRVSession) {
        if let snapshot = session.sleepSnapshot {
            healthKitSleep = snapshot
            isSleepLoading = false
        }
        if let vitals = session.vitalsSnapshot {
            recoveryVitals = vitals
        }
    }

    // MARK: - Data Loading

    /// Main entry point — called from the view's .task modifier.
    ///
    /// MorningResultsView is a FROZEN past-view. It only displays what was
    /// captured at acceptance (and refreshed on explicit reanalysis or a
    /// dashboard sleep adjustment). No live HealthKit queries, no live
    /// training backfills, no vitals refetching. Snapshots were already
    /// seeded synchronously in `init`. The only remaining work here is to
    /// fall back to a live sleep fetch for the narrow case where no sleep
    /// snapshot was frozen yet (first-open of a just-accepted session).
    func loadInitialData() async {
        if session.sleepSnapshot == nil {
            await fetchHealthKitSleep()
        } else {
            isSleepLoading = false
        }
    }

    // MARK: - HealthKit Sleep

    /// Full sleep fetch with frozen snapshot logic, recovery period windows,
    /// and late-syncing Apple Watch segment handling.
    func fetchHealthKitSleep() async {
        guard session.sessionType == .overnight else {
            debugLog("[MorningResultsVM] Skipping sleep fetch for \(session.sessionType.rawValue) session")
            isSleepLoading = false
            return
        }
        // Snapshot path: frozen view. Assign and stop. Caller's gate in
        // `loadInitialData` already skips this call when the snapshot
        // exists; this branch is defensive only.
        if let snapshot = session.sleepSnapshot {
            healthKitSleep = snapshot
            isSleepLoading = false
            return
        }
        guard healthKit.isHealthKitAvailable else {
            debugLog("[MorningResultsVM] HealthKit not available on this device")
            isSleepLoading = false
            return
        }
        await loadLiveSleep()
    }

    /// The night's sleep window under the user's own schedule and merge gap,
    /// not factory defaults: a user with merge off or a 03:00 bedtime must not
    /// get sessions chained across 4.5 h or a cutoff built on a 06:00 wake.
    private func sleepFetchWindow() -> (start: Date, end: Date) {
        let currentSettings = settings
        return HRVSession.sleepFetchWindow(
            for: session,
            allSessions: recentSessions,
            sleepSchedule: currentSettings.sleepSchedule,
            mergeGapSeconds: currentSettings.effectiveMergeGapSeconds
        )
    }

    /// No snapshot yet (pre-acceptance) — fetch live from HealthKit.
    private func loadLiveSleep() async {
        do {
            // Opening a result is not a request for access. After "Skip for
            // now" the fetch reads nothing and the RR estimate below stands in.
            if !healthKit.isAccessSkipped {
                try await healthKit.requestAuthorization()
            }
            let recoveryWindow = sleepFetchWindow()
            let sleep = try await healthKit.fetchSleepData(
                for: recoveryWindow.start,
                recordingEnd: recoveryWindow.end,
                rrPoints: session.rrSeries?.points
            )
            guard let resolved = await resolveSleep(sleep, window: recoveryWindow) else { return }
            healthKitSleep = resolved
            isSleepLoading = false
            storeSleepBoundariesIfMeasured(sleep)
        } catch {
            debugLog("[MorningResultsVM] Sleep fetch failed: \(error)")
            isSleepLoading = false
        }
    }

    /// Hand measured Apple Health sleep to the caller so the stored sleep
    /// boundaries catch up with the more complete data. An RR estimate is not
    /// a measurement, and a user's own adjustment or a past night is left alone.
    func storeSleepBoundariesIfMeasured(_ sleep: SleepData) {
        guard sleep.nightSleepMinutes > 0, !isHistoricalSession,
              displaySession.sleepUserAdjusted != true else { return }
        onUpdateSleep?(sleep)
    }

    /// If HealthKit returns 0 sleep, fall back to estimation. Apple Watch
    /// data may not be synced yet, the user may have denied HealthKit
    /// permission, or no Watch was worn — in any of those cases we can
    /// still produce a sleep estimate from RR intervals (chest strap) or
    /// passive HealthKit HR samples. Nil means "keep the loading state":
    /// a live session with neither real nor estimable sleep is still waiting
    /// for the Watch to sync.
    private func resolveSleep(
        _ sleep: SleepData,
        window: (start: Date, end: Date)
    ) async -> SleepData? {
        guard sleep.nightSleepMinutes == 0 else { return sleep }
        if let estimated = await estimateSleepFallback(for: window) {
            debugLog("[MorningResultsVM] Using estimated sleep fallback total=\(estimated.nightSleepMinutes)min")
            return estimated
        }
        guard !isHistoricalSession else { return sleep }
        debugLog("[MorningResultsVM] HealthKit returned 0 sleep and no fallback available — keeping loading state")
        return nil
    }

    /// Estimate sleep when HealthKit returns nothing. Tries RR-based HR
    /// estimation first (chest strap), then Apple Watch passive HR samples.
    private func estimateSleepFallback(for window: (start: Date, end: Date)) async -> SleepData? {
        if let points = session.rrSeries?.points,
           !points.isEmpty,
           let rrEstimate = HealthKitManager.estimateSleepFromHR(rrPoints: points, recordingStart: window.start),
           rrEstimate.nightSleepMinutes > 0 {
            return rrEstimate
        }

        let scheduleEnd = settings.sleepSchedule.overnightWindowEnd(relativeTo: window.start)
        let estimationEnd = max(window.end, scheduleEnd)
        if let hkHREstimate = await healthKit.estimateSleepFromHealthKitHR(
            windowStart: window.start,
            windowEnd: estimationEnd
        ), hkHREstimate.nightSleepMinutes > 0 {
            return hkHREstimate
        }

        return nil
    }

    // MARK: - Archive updates

    /// Pull a freshly-archived copy of this session from disk and
    /// route it through `reanalyzedSession` so `displaySession` and
    /// every score / breakdown / readiness computed off it reflect
    /// the new state.
    ///
    /// Called by `MorningResultsView`'s `.onChange(of: archiveSignal.version)`.
    /// Other surfaces — Dashboard re-analyze, sleep refresh, History
    /// row "Re-analyze", Settings → Reanalyze All — all bump the
    /// archive signal after writing. Without this hook the open
    /// Recovery Report sheet would show stale numbers until dismissed
    /// and re-presented.
    ///
    /// Filtered by session id internally so unrelated archive churn
    /// (other sessions edited, trash empties, etc.) doesn't churn
    /// this view.
    func applyExternalArchiveUpdate() {
        let sessionId = session.id
        // Decode off the main actor. This fires on EVERY archive
        // signal bump while the Recovery Report sheet is open (dashboard
        // re-analyze, sleep refresh, any other-session edit), and the full
        // retrieve (disk + AES-GCM decrypt + JSON decode) is too heavy for main.
        Task { [weak self] in
            let stored = await Task.detached { try? AppDependencies.current.storage.sessionArchive.retrieve(sessionId) }.value
            guard let self, let stored else { return }
            // Skip the update if nothing material changed — avoids needless
            // re-renders. Compare the fields the report actually reads.
            let current = self.displaySession
            let same = stored.recoveryScore == current.recoveryScore
                && stored.frozenReadiness == current.frozenReadiness
                && stored.scoreBreakdown?.compositeScore == current.scoreBreakdown?.compositeScore
                && stored.sleepSnapshot?.nightSleepMinutes == current.sleepSnapshot?.nightSleepMinutes
                && stored.trainingSnapshot?.tsb == current.trainingSnapshot?.tsb
            if same { return }
            self.reanalyzedSession = stored
            debugLog("[MorningResultsVM] external archive update applied — recoveryScore=\(stored.recoveryScore.map { String(format: "%.1f", $0) } ?? "nil") frozenReadiness=\(stored.frozenReadiness.map { String(format: "%.1f", $0) } ?? "nil")")
        }
    }
}
