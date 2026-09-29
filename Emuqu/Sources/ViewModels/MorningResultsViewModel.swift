import Combine
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
    var liveTrainingContext: TrainingContext?
    var isSleepLoading = true
    var dayTrimp: Double = 0
    var error: Error?

    /// Recovery baseline stats for z-score scoring (set externally from BaselineTracker)
    var baselineStats: BaselineTracker.RecoveryBaselineStats?

    /// Called when HealthKit has better sleep data than the frozen snapshot.
    /// The view sets this so the collector can persist the updated snapshot.
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
                try archive.archive(stored)
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

    /// Composite recovery score (0-100) combining HRV (60%), sleep (25%), and vitals (15%) under the v2.may2026 architecture.
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
        let trainingContext = displaySession.trainingSnapshot ?? displayResult.trainingContext ?? liveTrainingContext
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

    var readinessScore: Double {
        RecoveryScoreCalculator.toTenScale(compositeRecoveryScore)
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
        let trainingContext = displaySession.trainingSnapshot ?? displayResult.trainingContext ?? liveTrainingContext
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

    /// Overnight-only. `recentSessions` is mixed-type; including
    /// workouts / daytime readings poisons every "vs average" with workout
    /// physiology (resting-HR avg 83, stress avg 714, HRV "+38%") that
    /// contradicts the score's geometric-baseline "+2%".
    /// Excludes untrustworthy-HRV sessions from the "vs your
    /// average" card (see HRVSession.isReliableForHRVAggregates).
    var trendStats: AnalysisSummaryGenerator.TrendStats {
        let validSessions = recentSessions.filter { $0.sessionType == .overnight && $0.state == .complete && $0.analysisResult != nil && $0.isReliableForHRVAggregates }
        guard validSessions.count >= 2 else {
            return .empty
        }

        let averages = sessionAverages(validSessions)
        let baselines = baselineAverages(validSessions)
        return AnalysisSummaryGenerator.TrendStats(
            hasData: true,
            avgRMSSD: averages.rmssd, baselineRMSSD: baselines.rmssd,
            avgHR: averages.hr, baselineHR: baselines.hr,
            avgStress: averages.stress, baselineStress: baselines.stress,
            avgReadiness: averages.readiness,
            sessionCount: validSessions.count,
            daySpan: Self.daySpan(of: validSessions),
            trend7Day: sevenDayTrend(validSessions),
            trend30Day: nil
        )
    }

    /// Whole days between the oldest and newest session in the window.
    private static func daySpan(of sessions: [HRVSession]) -> Int {
        let dates = sessions.map(\.startDate)
        return Calendar.current.dateComponents(
            [.day], from: dates.min() ?? Date(), to: dates.max() ?? Date()
        ).day ?? 0
    }

    /// A struct, not a 4-tuple: SwiftLint caps a tuple at three members, and
    /// these read better named at the call site anyway.
    private struct SessionAverages {
        let rmssd: Double
        let hr: Double
        let stress: Double?
        let readiness: Double?
    }

    private func sessionAverages(_ validSessions: [HRVSession]) -> SessionAverages {
        let rmssdValues = validSessions.compactMap(\.rmssd)
        let hrValues = validSessions.compactMap(\.meanHR)
        let stressValues = validSessions.compactMap(\.stressIndex)
        let readinessValues = validSessions.compactMap(\.readinessScore)

        let avgRMSSD = rmssdValues.isEmpty ? 0 : rmssdValues.reduce(0, +) / Double(rmssdValues.count)
        let avgHR = hrValues.isEmpty ? 0 : hrValues.reduce(0, +) / Double(hrValues.count)
        let avgStress = stressValues.isEmpty ? nil : stressValues.reduce(0, +) / Double(stressValues.count)
        let avgReadiness = readinessValues.isEmpty ? nil : readinessValues.reduce(0, +) / Double(readinessValues.count)

        return SessionAverages(rmssd: avgRMSSD, hr: avgHR, stress: avgStress, readiness: avgReadiness)
    }

    /// Recent week vs the week before, as a percentage. Nil until both halves
    /// hold at least two sessions.
    private func sevenDayTrend(_ validSessions: [HRVSession]) -> Double? {
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let recentWeek = validSessions.filter { $0.startDate >= sevenDaysAgo }
        let olderWeek = validSessions.filter { $0.startDate < sevenDaysAgo }
        var trend7Day: Double?
        if recentWeek.count >= 2, olderWeek.count >= 2 {
            let recentRmssdValues = recentWeek.compactMap(\.rmssd)
            let olderRmssdValues = olderWeek.compactMap(\.rmssd)
            let recentAvg = recentRmssdValues.isEmpty ? 0 : recentRmssdValues.reduce(0, +) / Double(recentRmssdValues.count)
            let olderAvg = olderRmssdValues.isEmpty ? 0 : olderRmssdValues.reduce(0, +) / Double(olderRmssdValues.count)
            if olderAvg > 0 {
                trend7Day = ((recentAvg - olderAvg) / olderAvg) * 100
            }
        }

        return trend7Day
    }

    var trendInsight: String {
        let stats = trendStats
        guard stats.hasData else { return "Record more sessions to see trends." }

        var insights: [String] = []
        let currentRMSSD = displayResult.timeDomain.rmssd
        let currentHR = displayResult.timeDomain.meanHR
        let currentStress = displayResult.ansMetrics?.stressIndex

        guard stats.avgRMSSD > 0 else { return "Record more sessions to see trends." }
        let rmssdPct = (currentRMSSD - stats.avgRMSSD) / stats.avgRMSSD * 100

        insights.append(contentsOf: rmssdTrendInsights(rmssdPct: rmssdPct, stats: stats, currentRMSSD: currentRMSSD))
        insights.append(contentsOf: heartRateTrendInsights(currentHR: currentHR, currentStress: currentStress, stats: stats))
        insights.append(contentsOf: sevenDayTrendInsights(stats: stats))

        if stats.sessionCount < MorningResultsConstants.minSessionsForAccurateTrends {
            insights.append(String(localized: "With \(stats.sessionCount) sessions recorded, trends will become more accurate over time.", bundle: LanguageManager.appBundle))
        }

        return insights.joined(separator: " ")
    }

    var analysisSummary: AnalysisSummaryGenerator.AnalysisSummary {
        let summary = summaryGenerator.generate()
        // Share with the Assistant so it can reference any session the user has
        // ever opened in MorningResultsView (today, history reviews, etc.).
        AppDependencies.current.assistant.analysisSummaryCache.set(summary, forSessionId: displaySession.id)
        return summary
    }

    /// `liveLoadSnapshot` feeds the cumulative-load gate the live
    /// snapshot: free on @MainActor, and it lets the gate reflect every archive
    /// write since the last cache refresh rather than the frozen value captured
    /// at session acceptance.
    ///
    /// `canonicalBaseline*` (#2) threads the canonical score baseline
    /// (geometric ln(RMSSD) mean + meanHRBaseline) so the narrative agrees with
    /// the score instead of recomputing an arithmetic mean that reads high.
    private var summaryGenerator: AnalysisSummaryGenerator {
        let currentSettings = settings
        return AnalysisSummaryGenerator(
            result: displayResult,
            session: displaySession,
            recentSessions: recentSessions,
            selectedTags: selectedTags,
            sleep: AnalysisSleepInput(from: healthKitSleep),
            sleepTrend: AnalysisSleepTrendInput(from: sleepTrendStats),
            trainingContext: displaySession.trainingSnapshot ?? displayResult.trainingContext ?? liveTrainingContext,
            userAge: currentSettings.age,
            biologicalSex: currentSettings.biologicalSex,
            liveLoadSnapshot: TrainingLoadRegistry.live(),
            canonicalBaselineRMSSD: baselineStats.map { exp($0.lnRmssdMean) },
            canonicalBaselineHR: baselineStats.map(\.meanHRBaseline)
        )
    }

    // MARK: - Services

    private let settingsManager: SettingsManager
    let healthKit: HealthKitManager
    private var cancellables = Set<AnyCancellable>()

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

    /// No snapshot yet (pre-acceptance) — fetch live from HealthKit.
    private func loadLiveSleep() async {
        do {
            // Opening a result is not a request for access. After "Skip for
            // now" the fetch reads nothing and the RR estimate below stands in.
            if !healthKit.isAccessSkipped {
                try await healthKit.requestAuthorization()
            }
            let recoveryWindow = HRVSession.sleepFetchWindow(for: session, allSessions: recentSessions)
            let sleep = try await healthKit.fetchSleepData(
                for: recoveryWindow.start,
                recordingEnd: recoveryWindow.end,
                rrPoints: session.rrSeries?.points
            )
            guard let resolved = await resolveSleep(sleep, window: recoveryWindow) else { return }
            healthKitSleep = resolved
            isSleepLoading = false
        } catch {
            debugLog("[MorningResultsVM] Sleep fetch failed: \(error)")
            isSleepLoading = false
        }
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

    // MARK: - Day TRIMP

    /// Fetch the total TRIMP for the session's day so we can display training readiness.
    private func fetchDayTrimp(for referenceDate: Date) async {
        guard settings.enableTrainingLoadIntegration, !settings.isOnTrainingBreak else { return }

        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: referenceDate)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return }

        let workouts = await healthKit.fetchRecentWorkouts(days: 1, relativeTo: dayEnd)
        let trimp = workouts
            .filter { calendar.isDate($0.date, inSameDayAs: dayStart) }
            .reduce(0.0) { $0 + $1.calculateTrimp() }
        dayTrimp = trimp
    }

    // MARK: - Live Training Load

    private func fetchLiveTrainingContext(relativeTo referenceDate: Date = Date()) async {
        guard settings.enableTrainingLoadIntegration else {
            debugLog("[MorningResultsVM] Training load integration disabled in settings")
            return
        }
        guard !settings.isOnTrainingBreak else {
            debugLog("[MorningResultsVM] Training break is active — skipping live training context")
            return
        }
        let load = await healthKit.calculateTrainingLoad(forMorningReading: true, relativeTo: referenceDate)
        debugLog("[MorningResultsVM] Training load fetched: \(load.recentWorkouts.count) workouts, metrics=\(load.metrics != nil)")
        guard var context = TrainingContext(from: load, relativeTo: referenceDate) else {
            debugLog("[MorningResultsVM] No training metrics available")
            return
        }
        applyVO2MaxOverride(to: &context)
        liveTrainingContext = context
    }

    /// TrainingContext copies the HealthKit VO2max, but the user's manual
    /// entry takes priority — and turning the HealthKit source off clears it.
    private func applyVO2MaxOverride(to context: inout TrainingContext) {
        if let override = settings.vo2MaxOverride {
            context.vo2Max = override
        } else if !settings.useHealthKitVO2Max {
            context.vo2Max = nil
        }
    }

    // MARK: - Actions

    func reanalyze(using method: WindowSelectionMethod, handler: ((HRVSession, WindowSelectionMethod) async -> HRVSession?)?) async {
        guard let handler else { return }

        isReanalyzing = true
        defer { isReanalyzing = false }

        if let newSession = await handler(displaySession, method) {
            reanalyzedSession = newSession
        }
    }

    func updateTags(_ tags: Set<ReadingTag>, notes: String?, handler: (([ReadingTag], String?) -> Void)?) {
        selectedTags = tags
        if let notes {
            self.notes = notes
        }
        handler?(Array(tags), notes)
    }

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

// MARK: - File-scope helpers
//
// Kept out of MorningResultsView. Each names no member of the
// type and calls nothing inside it, so none needs to be a member.
// `private` at file scope is fileprivate, so every call site in this
// file resolves the same way.

/// Baselines prefer the sessions the user tagged "Morning" — a same-time-of-day
/// comparison — and fall back to every valid session when there are none.
private func baselineAverages(_ validSessions: [HRVSession]) -> (rmssd: Double?, hr: Double?, stress: Double?) {
    let morningReadings = validSessions.filter { $0.tags.contains { $0.name == "Morning" } }
    let baselineSessions = morningReadings.isEmpty ? validSessions : morningReadings
    let baselineRMSSDValues = baselineSessions.count >= 3 ? baselineSessions.suffix(5).compactMap(\.rmssd) : []
    let baselineRMSSD: Double? = baselineRMSSDValues.isEmpty ? nil : baselineRMSSDValues.reduce(0, +) / Double(baselineRMSSDValues.count)
    let baselineHRValues = baselineSessions.count >= 3 ? baselineSessions.suffix(5).compactMap(\.meanHR) : []
    let baselineHR: Double? = baselineHRValues.isEmpty ? nil : baselineHRValues.reduce(0, +) / Double(baselineHRValues.count)
    let baselineStressValues = baselineSessions.count >= 3 ? baselineSessions.suffix(5).compactMap(\.stressIndex) : []
    let baselineStress: Double? = baselineStressValues.isEmpty ? nil : baselineStressValues.reduce(0, +) / Double(baselineStressValues.count)

    return (baselineRMSSD, baselineHR, baselineStress)
}

private func rmssdTrendInsights(rmssdPct: Double, stats: AnalysisSummaryGenerator.TrendStats, currentRMSSD: Double) -> [String] {
    var insights: [String] = []
    if abs(rmssdPct) < MorningResultsConstants.TrendThresholds.consistent {
        insights.append("Your HRV is consistent with your recent average (\(String(format: "%.0f", locale: .current, stats.avgRMSSD))ms).")
    } else if rmssdPct > MorningResultsConstants.TrendThresholds.significant {
        insights.append("Your HRV is significantly higher than your average of \(String(format: "%.0f", locale: .current, stats.avgRMSSD))ms (+\(String(format: "%.0f", locale: .current, rmssdPct))%), suggesting excellent recovery today.")
    } else if rmssdPct > MorningResultsConstants.TrendThresholds.consistent {
        insights.append("Your HRV is above your average of \(String(format: "%.0f", locale: .current, stats.avgRMSSD))ms (+\(String(format: "%.0f", locale: .current, rmssdPct))%), indicating good recovery.")
    } else if rmssdPct < -MorningResultsConstants.TrendThresholds.significant {
        insights.append("Your HRV is significantly below your average of \(String(format: "%.0f", locale: .current, stats.avgRMSSD))ms (\(String(format: "%.0f", locale: .current, rmssdPct))%). Consider taking it easy today.")
    } else if rmssdPct < -MorningResultsConstants.TrendThresholds.consistent {
        insights.append("Your HRV is below your average of \(String(format: "%.0f", locale: .current, stats.avgRMSSD))ms (\(String(format: "%.0f", locale: .current, rmssdPct))%). Below your usual range.")
    }

    insights.append(contentsOf: baselineDeviationInsights(stats: stats, currentRMSSD: currentRMSSD))
    return insights
}

private func baselineDeviationInsights(stats: AnalysisSummaryGenerator.TrendStats, currentRMSSD: Double) -> [String] {
    var insights: [String] = []
    if let baseline = stats.baselineRMSSD {
        let baselineDiff = ((currentRMSSD - baseline) / baseline) * 100
        if baselineDiff < -MorningResultsConstants.TrendThresholds.baselineDeviation {
            insights.append("This is \(String(format: "%.0f", locale: .current, abs(baselineDiff)))% below your personal baseline.")
        } else if baselineDiff > MorningResultsConstants.TrendThresholds.baselineDeviation {
            insights.append("This is \(String(format: "%.0f", locale: .current, baselineDiff))% above your baseline—you're in great shape.")
        }
    }
    return insights
}

private func heartRateTrendInsights(currentHR: Double, currentStress: Double?, stats: AnalysisSummaryGenerator.TrendStats) -> [String] {
    var insights: [String] = []
    let hrDiff = currentHR - stats.avgHR
    if hrDiff > MorningResultsConstants.hrDiffThreshold {
        insights.append("Resting heart rate is elevated at \(String(format: "%.0f", locale: .current, currentHR)) bpm (avg: \(String(format: "%.0f", locale: .current, stats.avgHR)) bpm), which may indicate stress, dehydration, or incomplete recovery.")
    } else if hrDiff < -MorningResultsConstants.hrDiffThreshold {
        insights.append("Resting heart rate is lower than average at \(String(format: "%.0f", locale: .current, currentHR)) bpm (avg: \(String(format: "%.0f", locale: .current, stats.avgHR)) bpm), suggesting good cardiovascular fitness or deep rest.")
    }

    if let stress = currentStress, let avgStress = stats.avgStress {
        if stress > avgStress * MorningResultsConstants.stressMultiplierThreshold, stress > MorningResultsConstants.stressAbsoluteThreshold {
            insights.append("Stress markers are elevated compared to your norm. Consider stress management today.")
        }
    }
    return insights
}

private func sevenDayTrendInsights(stats: AnalysisSummaryGenerator.TrendStats) -> [String] {
    var insights: [String] = []
    if let trend = stats.trend7Day {
        if trend > MorningResultsConstants.trendThreshold {
            insights.append("Your 7-day HRV trend is improving (+\(String(format: "%.0f", locale: .current, trend))%)—keep doing what you're doing!")
        } else if trend < -MorningResultsConstants.trendThreshold {
            insights.append("Your 7-day HRV trend shows a decline (\(String(format: "%.0f", locale: .current, trend))%). Consider prioritizing recovery.")
        }
    }
    return insights
}
