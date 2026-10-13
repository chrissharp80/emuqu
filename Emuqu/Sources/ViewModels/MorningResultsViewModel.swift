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

    /// The week of nights before this one, from the sleep archived with
    /// `recentSessions` (the sessions before this one); nil when none has
    /// measured sleep. Feeds the summary's multi-night findings and the
    /// report's sleep-trend section.
    var sleepTrendStats: HealthKitManager.SleepTrendStats? {
        SleepTrendStats.recentNights(before: displaySession, in: recentSessions)
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

    /// The live training load for today's session. A past night's advice is
    /// read against the load frozen with it, as the score detail and the PDF
    /// read it, not against today's.
    var adviceLiveLoad: TrainingLoadRegistry.TrainingLoad? {
        isHistoricalSession ? nil : TrainingLoadRegistry.live()
    }

    /// The shared advice gate's read of the load the morning steps use, so the
    /// recovery card's message and the steps under it never disagree.
    var adviceLoadLevel: TrainingAdviceGate.LoadLevel {
        TrainingAdviceGate.level(
            .preferring(live: adviceLiveLoad, frozen: displaySession.trainingSnapshot ?? displayResult.trainingContext)
        )
    }

    // Note: morningFeeling is ONLY edited on the Dashboard while the session
    // is today's. Once it rolls off the dashboard, the feeling is frozen.
    // MorningResultsView shows the badge read-only; no update method here.

    /// Update the user's subjective readiness, re-score the night with it and
    /// persist both. The card only appears when the recording could not supply
    /// HRV, so the score stands the baseline in for the HRV factor and blends
    /// the rating into it (`ScoringWeights.PerceivedReadiness`, 70/30).
    /// A nil value clears the rating and is persisted the same way.
    func updatePerceivedReadiness(_ value: Double?) {
        let shown = displaySession
        var updated = shown
        updated.perceivedReadiness = value
        applyPerceivedReadinessScore(to: &updated)
        reanalyzedSession = updated
        persistPerceivedReadiness(value, scored: updated, revertTo: shown)
    }

    /// Re-score an unreliable night with its perceived-readiness answer, using
    /// the same inputs the deterministic re-score uses (frozen snapshots, the
    /// baseline of the nights before it, the session date). Leaves the session
    /// alone when the night has reliable HRV or no baseline is loaded yet.
    private func applyPerceivedReadinessScore(to session: inout HRVSession) {
        guard !session.isReliableForHRVAggregates, let baselineStats else { return }
        let analysis = session.analysisResult ?? result
        let training = session.trainingSnapshot ?? analysis.trainingContext
        let breakdown = RecoveryScoreCalculator.calculateWithBreakdown(
            RecoveryScoreCalculator.ScoreInputs(
                hrvReadiness: analysis.ansMetrics?.readinessScore, rmssd: analysis.timeDomain.rmssd,
                meanHR: analysis.timeDomain.meanHR, dfaAlpha1: analysis.nonlinear.dfaAlpha1,
                baselineStats: baselineStats, sleepData: session.sleepSnapshot,
                vitals: ReanalysisService.scoringVitals(of: session, result: analysis),
                typicalSleepHours: settings.typicalSleepHours
            ),
            trainingContext: training, config: scoringConfig, useBaselineHRV: true,
            perceivedReadiness: session.perceivedReadiness, ansBalance: liveAnsBalance,
            referenceDate: session.endDate ?? session.startDate
        )
        session.recoveryScore = RecoveryScoreCalculator.toTenScale(breakdown.compositeScore)
        session.scoreBreakdown = breakdown
        session.frozenReadiness = ReanalysisService.computeFrozenReadiness(
            compositeScore: breakdown.compositeScore, trainingContext: training
        )
    }

    /// Write the rating, and the score it gives the archived copy, to the
    /// archive. The copy is read off main and re-scored here from its own
    /// inputs; the write then changes only the rating and score fields under
    /// the archive lock, so a sleep or score update that landed meanwhile is
    /// kept. On success the screen shows that copy; on failure it goes back to
    /// what it showed before, so it never shows a rating the archive lacks.
    private func persistPerceivedReadiness(_ value: Double?, scored: HRVSession, revertTo previous: HRVSession) {
        let sessionId = session.id
        Task {
            let archived = await Task.detached { Self.loadArchived(sessionId) }.value
            var rescored = archived.session ?? scored
            rescored.perceivedReadiness = value
            applyPerceivedReadinessScore(to: &rescored)
            let toWrite = rescored
            let isArchived = archived.session != nil
            let readable = archived.readable
            let saved = await Task.detached {
                readable && Self.writePerceivedReadiness(toWrite, isArchived: isArchived)
            }.value
            guard reanalyzedSession?.perceivedReadiness == value else { return }
            if saved { adoptArchivedSession(toWrite) } else { reanalyzedSession = previous }
        }
    }

    /// The archived copy of the session (nil when it is not archived yet), and
    /// whether the archive could be read at all.
    nonisolated private static func loadArchived(_ id: UUID) -> (session: HRVSession?, readable: Bool) {
        do {
            let stored = try AppDependencies.current.storage.sessionArchive.retrieve(id)
            return (stored, true)
        } catch {
            debugLog("[MorningResultsVM] Could not read session to persist perceivedReadiness: \(error)", level: .warning)
            return (nil, false)
        }
    }

    /// Store the rating and score fields of `rescored`: in place on the
    /// archived copy (`SessionArchive.update`), or by archiving `rescored`
    /// whole when the session is not archived yet. False when the write threw.
    nonisolated private static func writePerceivedReadiness(_ rescored: HRVSession, isArchived: Bool) -> Bool {
        do {
            try storePerceivedReadiness(rescored, isArchived: isArchived)
            debugLog("[MorningResultsVM] Persisted perceivedReadiness=\(rescored.perceivedReadiness.map { String(format: "%.2f", $0) } ?? "nil")")
            return true
        } catch {
            debugLog("[MorningResultsVM] Failed to persist perceivedReadiness: \(error)", level: .warning)
            return false
        }
    }

    /// The write behind `writePerceivedReadiness`: only the rating and score
    /// fields, in place, on an archived copy; the whole session otherwise.
    nonisolated private static func storePerceivedReadiness(_ rescored: HRVSession, isArchived: Bool) throws {
        let archive = AppDependencies.current.storage.sessionArchive
        guard isArchived else {
            try archive.archive(rescored, skipSameNightMerge: false, requestingReupload: true)
            return
        }
        try archive.update(rescored.id) { stored in
            stored.perceivedReadiness = rescored.perceivedReadiness
            stored.recoveryScore = rescored.recoveryScore
            stored.scoreBreakdown = rescored.scoreBreakdown
            stored.frozenReadiness = rescored.frozenReadiness
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
    /// Scored as of the session's own date, as the perceived-readiness
    /// re-score is, so a past night's live score does not depend on the day
    /// the report is opened.
    private var liveRecoveryScore: Double {
        let trainingContext = displaySession.trainingSnapshot ?? displayResult.trainingContext
        let composite = RecoveryScoreCalculator.calculateWithBreakdown(
            RecoveryScoreCalculator.ScoreInputs(
                hrvReadiness: displayResult.ansMetrics?.readinessScore, rmssd: displayResult.timeDomain.rmssd,
                meanHR: displayResult.timeDomain.meanHR, dfaAlpha1: displayResult.nonlinear.dfaAlpha1,
                baselineStats: baselineStats, sleepData: healthKitSleep, vitals: recoveryVitals,
                typicalSleepHours: settings.typicalSleepHours
            ),
            trainingContext: trainingContext, config: scoringConfig,
            ansBalance: liveAnsBalance, referenceDate: sessionReferenceDate
        ).compositeScore
        return ScoreVerdict.clampedDisplayScore(composite)
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
    /// scoring source of truth. Scored as of the session's own date, like
    /// `liveRecoveryScore`.
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
            ansBalance: liveAnsBalance,
            referenceDate: sessionReferenceDate
        )
    }

    /// For legacy sessions without a stored breakdown: the frozen score may
    /// have been computed with different baseline stats, so the live composite
    /// can diverge. Pin the breakdown composite to the frozen score so the
    /// message and factor display are consistent with the displayed number.
    /// The pinned composite came from no recorded algorithm version, so the
    /// breakdown says `unversioned` rather than this build's version.
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
            penalties: live.penalties,
            spo2PenaltyApplied: live.spo2PenaltyApplied,
            scoringVersion: ScoringVersion.unversioned
        )
    }

    /// The last generated summary and the inputs it was built from. Ignored by
    /// observation: it is a memo, not state the view renders from.
    @ObservationIgnored private var summaryMemo: (key: Int, summary: AnalysisSummaryGenerator.AnalysisSummary)?

    /// Generated once per change of its inputs rather than on every body read.
    var analysisSummary: AnalysisSummaryGenerator.AnalysisSummary {
        let readiness = todayReadiness
        let key = summaryKey(readiness: readiness)
        if let memo = summaryMemo, memo.key == key { return memo.summary }
        let summary = summaryGenerator(readiness: readiness).generate()
        summaryMemo = (key, summary)
        // Share with the Assistant so it can reference any session the user has
        // ever opened in MorningResultsView (today, history reviews, etc.).
        AppDependencies.current.assistant.analysisSummaryCache.set(
            summary, forSessionId: displaySession.id,
            fingerprint: AnalysisSummaryCache.fingerprint(for: displaySession)
        )
        return summary
    }

    /// Hash of everything `summaryGenerator` reads that can change while the
    /// report is open, including the language it is written in, so switching
    /// the app language regenerates the summary instead of showing the old one.
    /// `recentSessions` is a `let` and cannot change, so it is left out.
    private func summaryKey(readiness: LiveReadiness?) -> Int {
        var hasher = Hasher()
        hasher.combine(AnalysisSummaryCache.fingerprint(for: displaySession))
        hasher.combine(NarrativeLanguage.isEnglish)
        hasher.combine(LanguageManager.appLocale.identifier)
        hasher.combine(selectedTags)
        combineSleepInputs(into: &hasher)
        hasher.combine(baselineStats?.lnRmssdMean)
        hasher.combine(baselineStats?.meanHRBaseline)
        hasher.combine(readiness?.score)
        hasher.combine(readiness?.todayTrimp)
        combineLiveLoad(adviceLiveLoad, into: &hasher)
        return hasher.finalize()
    }

    /// Every sleep and sleep-trend field the generator reads, as it reads them.
    private func combineSleepInputs(into hasher: inout Hasher) {
        let sleep = AnalysisSleepInput(from: healthKitSleep)
        hasher.combine(sleep.totalSleepMinutes)
        hasher.combine(sleep.inBedMinutes)
        hasher.combine(sleep.deepSleepMinutes)
        hasher.combine(sleep.remSleepMinutes)
        hasher.combine(sleep.awakeMinutes)
        hasher.combine(sleep.sleepEfficiency)
        hasher.combine(sleepTrendStats?.averageSleepMinutes)
        hasher.combine(sleepTrendStats?.nightsAnalyzed)
    }

    /// The live training load the advice gate reads (nil for a past night).
    private func combineLiveLoad(_ load: TrainingLoadRegistry.TrainingLoad?, into hasher: inout Hasher) {
        hasher.combine(load?.atl)
        hasher.combine(load?.ctl)
        hasher.combine(load?.tsb)
        hasher.combine(load?.acwr)
        hasher.combine(load?.todayTrimp)
        hasher.combine(load?.monotony)
        hasher.combine(load?.strain)
    }

    /// `liveLoadSnapshot` feeds the cumulative-load gate the live
    /// snapshot for today's session (`adviceLiveLoad`): free on @MainActor,
    /// and it lets the gate reflect every archive write since the last cache
    /// refresh rather than the frozen value captured at session acceptance.
    ///
    /// `todayReadiness` feeds today's overnight session the live readiness
    /// and today's TRIMP, so the steps switch to post-workout recovery advice
    /// after a hard session. It changes the summary text only, not a score.
    ///
    /// `canonicalBaseline*` (#2) threads the canonical score baseline
    /// (geometric ln(RMSSD) mean + meanHRBaseline) so the narrative agrees with
    /// the score instead of recomputing an arithmetic mean that reads high.
    private func summaryGenerator(readiness: LiveReadiness?) -> AnalysisSummaryGenerator {
        let currentSettings = settings
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
            liveLoadSnapshot: adviceLiveLoad,
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
        if displaySession.sleepSnapshot == nil {
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
        // Snapshot path: frozen view. Assign the latest archived snapshot
        // (`displaySession`, which follows external archive updates) and stop.
        if let snapshot = displaySession.sleepSnapshot {
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
    ///
    /// Only reads: Health's prompt is a remote sheet, and remote sheets over
    /// this one crashed in `_tryToConnectToRemoteSheet`. Launch and taps ask;
    /// without access the RR estimate stands in.
    private func loadLiveSleep() async {
        do {
            let recoveryWindow = sleepFetchWindow()
            let sleep = try await healthKit.fetchSleepData(
                for: recoveryWindow.start,
                recordingEnd: recoveryWindow.end,
                rrPoints: session.rrSeries?.points
            )
            guard let resolved = await resolveSleep(sleep, window: recoveryWindow) else {
                endSleepLoadingAfterWait()
                return
            }
            healthKitSleep = resolved
            isSleepLoading = false
            storeSleepBoundariesIfMeasured(sleep)
        } catch {
            debugLog("[MorningResultsVM] Sleep fetch failed: \(error)")
            isSleepLoading = false
        }
    }

    /// How long the sleep card keeps its spinner while today's night has no
    /// sleep yet, waiting for the Watch to sync, before it shows "--".
    private static let liveSleepWaitNanoseconds: UInt64 = 60 * 1_000_000_000

    /// Stop the spinner after `liveSleepWaitNanoseconds` unless sleep arrived
    /// meanwhile. A later refetch (the view's sleep-data and device-fetch
    /// observers) still fills the card when the Watch syncs.
    private func endSleepLoadingAfterWait() {
        Task { [weak self] in
            await sleepQuietly(Self.liveSleepWaitNanoseconds, context: "morningResultsLiveSleepWait")
            guard let self, self.healthKitSleep == nil else { return }
            self.isSleepLoading = false
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
    ///
    /// Only the latest request is applied: each bump takes a new generation,
    /// and a retrieve that finishes after a later bump was made is dropped, so
    /// an older copy never replaces a newer one.
    func applyExternalArchiveUpdate() {
        let sessionId = session.id
        let shown = displaySession
        archiveUpdateGeneration &+= 1
        let generation = archiveUpdateGeneration
        // Decode and compare off the main actor. This fires on EVERY archive
        // signal bump while the Recovery Report sheet is open (dashboard
        // re-analyze, sleep refresh, any other-session edit), and the full
        // retrieve (disk + AES-GCM decrypt + JSON decode) is too heavy for main.
        Task { [weak self] in
            let stored = await Task.detached { Self.changedArchivedCopy(sessionId, comparedWith: shown) }.value
            guard let self, let stored, generation == self.archiveUpdateGeneration else { return }
            self.adoptArchivedSession(stored)
            debugLog("[MorningResultsVM] external archive update applied — recoveryScore=\(stored.recoveryScore.map { String(format: "%.1f", $0) } ?? "nil") frozenReadiness=\(stored.frozenReadiness.map { String(format: "%.1f", $0) } ?? "nil")")
        }
    }

    /// Bumped by each `applyExternalArchiveUpdate`; a finished retrieve is
    /// applied only while its generation is still the latest.
    @ObservationIgnored private var archiveUpdateGeneration = 0

    /// The archived copy when it differs from what the report shows; nil when
    /// it is unchanged, gone, or unreadable (logged).
    nonisolated private static func changedArchivedCopy(_ id: UUID, comparedWith shown: HRVSession) -> HRVSession? {
        guard let stored = AppDependencies.current.storage.sessionArchive.retrieveOrLog(id) else { return nil }
        return reportsSame(stored, shown) ? nil : stored
    }

    /// Whether two copies are identical in every stored field, compared by
    /// their sorted-key encodings: any field the report shows (feeling badge,
    /// tags, rating, analysis, every snapshot field) counts as a change. A copy
    /// that fails to encode counts as changed.
    nonisolated private static func reportsSame(_ lhs: HRVSession, _ rhs: HRVSession) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let lhsData = attempt("morningResults.encodeArchived", { try encoder.encode(lhs) }),
              let rhsData = attempt("morningResults.encodeShown", { try encoder.encode(rhs) }) else { return false }
        return lhsData == rhsData
    }

    /// Show the archived copy, including the sleep and vitals it was scored
    /// with, so the sleep card, narrative and PDF match the new score.
    private func adoptArchivedSession(_ stored: HRVSession) {
        reanalyzedSession = stored
        if let sleep = stored.sleepSnapshot {
            healthKitSleep = sleep
            isSleepLoading = false
        }
        if let vitals = stored.vitalsSnapshot {
            recoveryVitals = vitals
        }
    }
}
