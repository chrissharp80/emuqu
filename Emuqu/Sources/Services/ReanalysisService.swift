import Foundation

/// Owns all re-analysis, manual window selection, sleep retro-apply, and
/// session mutation logic.
///
/// Dependencies are injected explicitly so the service is testable without
/// an `RRCollector` instance and does not reach into singletons.
@MainActor
final class ReanalysisService {
    // MARK: - Shared Readiness Computation

    /// Compute frozen readiness from a composite score and training context.
    /// Uses the same EWMA step + todayTrimp=0 logic as SessionAcceptanceService
    /// so all freeze points produce identical results.
    /// Compute frozen readiness from a composite score and training context.
    ///
    /// Freezes the morning waking state BEFORE the day's EWMA decay.
    /// The training context's ATL/CTL are through yesterday
    /// (forMorningReading=true) — use them as-is. No EWMA step, no
    /// dissipation bonus: those represent intra-day recovery that hasn't
    /// happened yet at acceptance time.
    ///
    /// The dashboard's live path (forMorningReading=false) applies the
    /// step, giving the dissipation bonus and a higher readiness as the
    /// day progresses on rest days.
    /// Shared insufficient-data classifier. Used by both reanalysis and the
    /// initial morning-processing pipeline so a session can't be marked
    /// `.insufficient` on one path and `.ok` on the other. Returns `true`
    /// iff the session has too little signal for a reliable HRV score:
    /// either the analysis window is shorter than the minimum reliable
    /// window, or there's no organized-recovery evidence and the session
    /// itself is shorter than the overnight-minimum duration.
    ///
    /// Only applied when the measured RMSSD is below the user's baseline —
    /// a clean, high RMSSD reading on a short session is still useful to show
    /// the user. That asymmetry is deliberate and is pinned by
    /// `SessionAcceptanceQualityTests`. It governs DISPLAY only: baseline
    /// admission is gated structurally in `BaselineTracker.update`, because
    /// the two decisions are not the same question.
    static func hasInsufficientData(
        session: HRVSession,
        analysisResult: HRVAnalysisResult,
        baselineRmssd: Double
    ) -> Bool {
        let rmssd = analysisResult.timeDomain.rmssd
        guard rmssd < baselineRmssd else { return false }

        let windowTooShort: Bool = if let wsMs = analysisResult.windowStartMs, let weMs = analysisResult.windowEndMs {
            (weMs - wsMs) < HRVConstants.MinimumDuration.forReliableWindowMs
        } else {
            false
        }

        let sessionEnd = session.endDate ?? session.startDate
        let sessionDuration = sessionEnd.timeIntervalSince(session.startDate)
        let noRecoveryZoneData = analysisResult.isOrganizedRecovery != true
            && sessionDuration < HRVConstants.MinimumDuration.forOvernightSessionSeconds

        return windowTooShort || noRecoveryZoneData
    }

    static func computeFrozenReadiness(compositeScore: Double, trainingContext: TrainingContext?) -> Double {
        let atl = trainingContext?.atl ?? 0
        let ctl = trainingContext?.ctl ?? 0
        let acr: Double? = ctl > 0 ? atl / ctl : nil
        let readiness = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: compositeScore,
            todayTrimp: 0,
            ctl: ctl,
            atl: atl,
            morningATL: atl,
            acuteChronicRatio: acr
        )
        return RecoveryScoreCalculator.toTenScale(readiness)
    }

    // MARK: - Dependencies

    let archive: SessionArchive
    let healthKit: HealthKitServiceProtocol
    let analysisPipeline: HRVAnalysisPipeline
    private let windowSelector: WindowSelector
    private let artifactDetector: ArtifactDetector
    let baselineTracker: BaselineTracker

    /// Closure returning the current user settings snapshot.
    let settingsProvider: () -> UserSettings

    /// Closure returning the current scoring configuration.
    let scoringConfigProvider: () -> RecoveryScoreCalculator.ScoringConfiguration

    /// Closure returning the current ANS balance configuration.
    let ansConfigProvider: () -> HRVAnalysisPipeline.ANSConfiguration

    /// Closure to build a `TrainingContext` relative to a given date.
    let trainingContextProvider: (Date) -> TrainingContext?

    /// Closure to run HRV analysis with a specific window (delegates to `RRCollector.analyze`).
    private let analyzeWithWindow: (HRVSession, WindowSelector.RecoveryWindow, [ArtifactFlags], PeakCapacity?) async -> HRVAnalysisResult?

    /// Closure to run HRV analysis on the full session (delegates to `RRCollector.analyze`).
    private let analyzeFullSession: (HRVSession, PeakCapacity?) async -> HRVAnalysisResult?

    // MARK: - Callbacks

    /// Notifies the owner that the archive has changed (e.g. `archiveVersion += 1`).
    let onArchiveChanged: () -> Void

    /// Uploads a session via CloudKit sync.
    let onSessionUploaded: (HRVSession) -> Void

    // MARK: - Initialization

    init(
        archive: SessionArchive,
        healthKit: HealthKitServiceProtocol,
        analysisPipeline: HRVAnalysisPipeline,
        windowSelector: WindowSelector,
        artifactDetector: ArtifactDetector,
        baselineTracker: BaselineTracker,
        settingsProvider: @escaping () -> UserSettings,
        scoringConfigProvider: @escaping () -> RecoveryScoreCalculator.ScoringConfiguration,
        ansConfigProvider: @escaping () -> HRVAnalysisPipeline.ANSConfiguration,
        trainingContextProvider: @escaping (Date) -> TrainingContext?,
        analyzeWithWindow: @escaping (HRVSession, WindowSelector.RecoveryWindow, [ArtifactFlags], PeakCapacity?) async -> HRVAnalysisResult?,
        analyzeFullSession: @escaping (HRVSession, PeakCapacity?) async -> HRVAnalysisResult?,
        onArchiveChanged: @escaping () -> Void,
        onSessionUploaded: @escaping (HRVSession) -> Void
    ) {
        self.archive = archive
        self.healthKit = healthKit
        self.analysisPipeline = analysisPipeline
        self.windowSelector = windowSelector
        self.artifactDetector = artifactDetector
        self.baselineTracker = baselineTracker
        self.settingsProvider = settingsProvider
        self.scoringConfigProvider = scoringConfigProvider
        self.ansConfigProvider = ansConfigProvider
        self.trainingContextProvider = trainingContextProvider
        self.analyzeWithWindow = analyzeWithWindow
        self.analyzeFullSession = analyzeFullSession
        self.onArchiveChanged = onArchiveChanged
        self.onSessionUploaded = onSessionUploaded
    }

    // MARK: - Re-Analysis

    /// Defensive hydration. Several call sites (the morning
    /// sheet's `presentation.session`, dashboard cached snapshots, etc.)
    /// can pass a "lightweight" session whose `rrSeries` was stripped at
    /// decode time to keep memory footprints small. Without this guard:
    ///   1. `reanalyzeAtPosition` returns nil immediately ("No RR series"
    ///      in the log) — the user picks a window on the chart and
    ///      nothing happens.
    ///   2. `applyManualAnalysis` would silently re-archive the session
    ///      with `rrSeries == nil` (encodeIfPresent omits the field),
    ///      destroying the raw beat data on disk and breaking ALL future
    ///      reanalysis for that session.
    /// Hydrating from the archive by ID is cheap (one JSON decode) and
    /// makes both bugs disappear regardless of how the lightweight
    /// session got handed in.
    func hydrated(_ session: HRVSession) -> HRVSession {
        if let series = session.rrSeries, !series.points.isEmpty {
            return session
        }
        guard let stored = try? archive.retrieve(session.id),
              let storedSeries = stored.rrSeries,
              !storedSeries.points.isEmpty
        else {
            return session
        }
        debugLog("[ReanalysisService] Hydrated lightweight session \(session.id.uuidString.prefix(8)) from archive (\(storedSeries.points.count) RR points)")
        var hydrated = session
        hydrated.rrSeries = storedSeries
        if hydrated.artifactFlags == nil { hydrated.artifactFlags = stored.artifactFlags }
        return hydrated
    }

    /// Re-analyze a session with current algorithms.
    /// - Parameter preserveManualWindows: When true (batch mode), sessions with
    ///   `windowUserAdjusted == true` are skipped to preserve manual picks.
    /// Artifact detection and window selection, off the main actor.
    ///
    /// Both are pure CPU passes over 20k+ RR points. Running them on the main
    /// actor froze the UI behind the reanalysis spinner, so the inputs are
    /// captured here and the scan runs on a detached task.
    private func detectAndSelectWindow(
        series: RRSeries,
        method: WindowSelectionMethod,
        sleepStartMs: Int64?,
        wakeTimeMs: Int64?
    ) async -> (flags: [ArtifactFlags], result: WindowSelector.WindowSelectionResult) {
        // Artifact detection + window selection are pure CPU work over 20k+
        // RR points. Run them off the main actor so the UI stays responsive
        // while reanalysis runs. The service is @MainActor (for archive/UI
        // callback safety); detaching here is the opt-out for heavy compute.
        let artifactDetector = artifactDetector
        let windowSelector = windowSelector
        let baselineStatsForWindow = baselineStatsForWindowRanking
        return await Task.detached(priority: .userInitiated) {
            let flags = artifactDetector.detectArtifacts(in: series)
            let windowResult = Self.selectWindow(
                method: method, series: series, flags: flags,
                sleepStartMs: sleepStartMs, wakeTimeMs: wakeTimeMs,
                selector: windowSelector, baselineStats: baselineStatsForWindow
            )
            return (flags, windowResult)
        }.value
    }

    /// Reanalyze selects the recovery window with the
    /// SAME rule as the initial ("morning") analyze: ranked against the
    /// rolling baseline (calculateTier1), exactly like MorningProcessingService.
    /// Passing `baselineStats: nil` here makes reanalyze rank by raw RMSSD
    /// (highest HRV wins) while morning ranks baseline-relative, so reanalyze
    /// systematically chooses a higher-HRV window and produces a higher score
    /// than the accepted morning score — which trains the user to reanalyze
    /// every day.
    /// Read on the actor so the all-value struct can be captured into the
    /// detached task. Peak-metric methods (.peakRMSSD etc.) still select their
    /// window via selectWindowByMethod, which is baseline-agnostic by
    /// definition — the baseline here only feeds the companion capacity scan,
    /// matching the morning path.
    private var baselineStatsForWindowRanking: BaselineTracker.RecoveryBaselineStats? {
        baselineTracker.recoveryBaselineStats
    }

    /// The consolidated-recovery path ranks candidate windows; every other
    /// method picks by its own metric and borrows only the capacity scan.
    nonisolated private static func selectWindow(
        method: WindowSelectionMethod,
        series: RRSeries,
        flags: [ArtifactFlags],
        sleepStartMs: Int64?,
        wakeTimeMs: Int64?,
        selector: WindowSelector,
        baselineStats: BaselineTracker.RecoveryBaselineStats?
    ) -> WindowSelector.WindowSelectionResult {
        let withCapacity = selector.findBestWindowWithCapacity(
            in: series, flags: flags,
            sleepStartMs: sleepStartMs, wakeTimeMs: wakeTimeMs,
            baselineStats: baselineStats
        )
        guard method != .consolidatedRecovery else {
            if let withCapacity { return withCapacity }
            debugLog("[ReanalysisService] No valid consolidated window; falling back to full-session analysis")
            return WindowSelector.WindowSelectionResult(recoveryWindow: nil, peakCapacity: nil)
        }
        return WindowSelector.WindowSelectionResult(
            recoveryWindow: selector.selectWindowByMethod(
                method, in: series, flags: flags, sleepStartMs: sleepStartMs, wakeTimeMs: wakeTimeMs
            ),
            peakCapacity: withCapacity?.peakCapacity
        )
    }

    func reanalyzeSession(_ inputSession: HRVSession, method: WindowSelectionMethod = .consolidatedRecovery, preserveManualWindows: Bool = false) async -> HRVSession? {
        if preserveManualWindows, inputSession.windowUserAdjusted == true {
            debugLog("[ReanalysisService] Skipping session \(inputSession.id.uuidString.prefix(8)) — manual window preserved")
            return nil
        }
        let session = hydrated(inputSession)
        guard let series = session.rrSeries, !series.points.isEmpty else {
            debugLog("[ReanalysisService] Cannot re-analyze: no RR data in session")
            return nil
        }
        return await reanalyze(session, series: series, method: method)
    }

    /// The analysis pass itself, after the guards.
    private func reanalyze(
        _ session: HRVSession, series: RRSeries, method: WindowSelectionMethod
    ) async -> HRVSession? {
        debugLog("[ReanalysisService] Re-analyzing session \(session.id) with \(series.points.count) points")
        // Copy the original session and update only what reanalysis changes.
        let sessionEndDate = session.endDate ?? session.startDate.addingTimeInterval(12 * 60 * 60)
        let bounds = Self.analysisBounds(for: session, sessionEndDate: sessionEndDate)
        let heavy = await detectAndSelectWindow(
            series: series, method: method,
            sleepStartMs: bounds.sleepStartMs, wakeTimeMs: bounds.wakeTimeMs
        )
        var updatedSession = session
        updatedSession.rrSeries = series
        updatedSession.artifactFlags = heavy.flags
        guard let analysisResult = await analysisResult(for: updatedSession, heavy: heavy) else {
            debugLog("[ReanalysisService] Analysis failed during re-analysis")
            return nil
        }
        applyAnalysis(analysisResult, to: &updatedSession)
        await rescore(&updatedSession, analysisResult: analysisResult, original: session, sessionEndDate: sessionEndDate)
        guard await persist(updatedSession) else { return nil }
        return updatedSession
    }

    /// Use STORED sleep boundaries for window selection so reanalysis is
    /// deterministic. HealthKit retroactively refines sleep analysis, so
    /// re-fetching boundaries shifts the 30-70% search band and selects a
    /// different "best" window each run — causing HRV to jump (e.g. 77->57)
    /// even though the RR data hasn't changed. Stored boundaries reflect the
    /// original analysis or user adjustments and are stable across runs.
    ///
    /// Reanalysis is a deterministic math pass over stored RR/session data. Do
    /// not block on live HealthKit queries here; those can lag and make
    /// reanalysis appear "stuck" even though RR analysis itself is local.
    private static func analysisBounds(
        for session: HRVSession, sessionEndDate: Date
    ) -> (sleepStartMs: Int64?, wakeTimeMs: Int64?) {
        let recordedSpanMs = MillisecondOffset.between(sessionEndDate, and: session.startDate, fallback: 0)
        guard session.sleepStartMs != nil || session.sleepEndMs != nil else {
            // No stored boundaries (legacy session) — analyze across the recorded span.
            return (0, recordedSpanMs)
        }
        return (session.sleepStartMs ?? 0, session.sleepEndMs ?? recordedSpanMs)
    }

    /// Re-run the metrics over the selected window, or the full session when
    /// no recovery window was found.
    private func analysisResult(
        for session: HRVSession, heavy: (flags: [ArtifactFlags], result: WindowSelector.WindowSelectionResult)
    ) async -> HRVAnalysisResult? {
        guard let window = heavy.result.recoveryWindow else {
            return await analyzeFullSession(session, heavy.result.peakCapacity)
        }
        return await analyzeWithWindow(session, window, heavy.flags, heavy.result.peakCapacity)
    }

    /// Individual reanalysis clears the manual window flag — the user is
    /// explicitly choosing to let the algorithm select a new window.
    ///
    /// Gate: if there's insufficient data for reliable scoring, mark the
    /// session insufficient so the dashboard shows SubjectiveReadinessCard
    /// instead of a misleading score. Uses the shared classifier so reanalysis
    /// and initial scoring agree.
    private func applyAnalysis(_ analysisResult: HRVAnalysisResult, to session: inout HRVSession) {
        session.analysisResult = analysisResult
        session.analysisResult?.isReanalysis = true
        session.windowUserAdjusted = nil
        let baselineRmssd = baselineTracker.recoveryBaselineStats.map { exp($0.lnRmssdMean) } ?? 0
        guard Self.hasInsufficientData(session: session, analysisResult: analysisResult, baselineRmssd: baselineRmssd) else {
            return
        }
        session.hrvDataQuality = .insufficient
        // Health values (RMSSD, baseline) are PHI and debugLog is
        // user-exportable — log that the insufficient-data transition
        // occurred without the numeric values.
        debugLog("[ReanalysisService] Marked session insufficient (window too short or no organized recovery)")
    }

    /// Re-score against the wake-time training context, then label which sleep
    /// segment the analysis window falls in.
    private func rescore(
        _ updatedSession: inout HRVSession,
        analysisResult: HRVAnalysisResult,
        original session: HRVSession,
        sessionEndDate: Date
    ) async {
        let frozenCandidate = session.trainingSnapshot ?? session.analysisResult?.trainingContext
        let frozenTraining = await wakeTimeTraining(candidate: frozenCandidate, sessionEndDate: sessionEndDate)
        healTrainingSnapshot(&updatedSession, to: frozenTraining, from: frozenCandidate)
        applyRecoveryScore(
            to: &updatedSession,
            analysisResult: analysisResult,
            frozenTraining: frozenTraining,
            originalSession: session,
            // Baseline-score both untrustworthy classes
            // (`.insufficient` + `.preSleep`); see isReliableForHRVAggregates.
            useBaselineHRV: !updatedSession.isReliableForHRVAggregates
        )
        labelAnalysisSegment(
            session: &updatedSession,
            analysisResult: analysisResult,
            originalSession: session
        )
    }

    /// Re-score against the WAKE-TIME training context, and
    /// RECONSTRUCT it rather than trusting the stored snapshot.
    ///
    /// The recovery score is frozen at wake by design. Refreshing training
    /// on every reanalyze from the LIVE cache
    /// (`AppDependencies.current.analysis.trainingMetricsCache.current`), which INCLUDES today's
    /// workouts, drags the score DOWN on each reanalyze as the day's
    /// load accumulates (TSB only gets more negative), "always lower, never
    /// higher." That is not intended.
    ///
    /// Reconstruct via `calculateTrainingLoad(relativeTo: sessionEndDate)`,
    /// which is `forMorningReading: true` — it computes ATL/CTL through
    /// YESTERDAY and is day-stable, so it EXCLUDES today's load and
    /// reproduces the wake number no matter when the user reanalyzes. This
    /// also HEALS a session whose stored snapshot was overwritten with the
    /// live (includes-today) value — it snaps back to wake on the next
    /// reanalyze. Only used when training-load integration is on and
    /// it returns real values; otherwise the existing frozen snapshot
    /// stands (nil is intentional when integration is off).
    private func wakeTimeTraining(candidate: TrainingContext?, sessionEndDate: Date) async -> TrainingContext? {
        guard settingsProvider().enableTrainingLoadIntegration else { return candidate }
        let wakeLoad = await healthKit.calculateTrainingLoad(relativeTo: sessionEndDate)
        guard let wakeContext = TrainingContext(from: wakeLoad, relativeTo: sessionEndDate),
              wakeContext.atl > 0 || wakeContext.ctl > 0 else { return candidate }
        return wakeContext
    }

    /// Persist the wake context when it differs from what's stored (heals
    /// a drifted snapshot); a no-op when it already matches.
    private func healTrainingSnapshot(
        _ session: inout HRVSession, to frozenTraining: TrainingContext?, from frozenCandidate: TrainingContext?
    ) {
        guard let healed = frozenTraining,
              healed.atl != frozenCandidate?.atl || healed.ctl != frozenCandidate?.ctl else { return }
        debugLog("[ReanalysisService] Reanalyze: restored wake-time trainingSnapshot to atl=\(String(format: "%.1f", healed.atl))/ctl=\(String(format: "%.1f", healed.ctl)) (was atl=\(String(format: "%.1f", frozenCandidate?.atl ?? -1))/ctl=\(String(format: "%.1f", frozenCandidate?.ctl ?? -1)))")
        session.trainingSnapshot = healed
    }

    /// Archive write also runs off main — overnight sessions serialize
    /// to 1.5 MB+ JSON and blocked the UI noticeably on the main actor.
    /// SessionArchive is NSLock-protected internally.
    private func persist(_ updatedSession: HRVSession) async -> Bool {
        let archive = archive
        let sessionToArchive = updatedSession
        do {
            try await Task.detached(priority: .userInitiated) {
                _ = try archive.archive(sessionToArchive)
            }.value
        } catch {
            debugLog("[ReanalysisService] Failed to save re-analyzed session: \(error)")
            return false
        }
        // Cached on-demand zones computed by the chart view are now stale
        // (the window has changed). Drop them so the next chart render
        // recomputes against the new window.
        AppDependencies.current.app.organizedZonesCache.invalidate(updatedSession.id)
        baselineTracker.update(with: updatedSession, sleepSchedule: settingsProvider().sleepSchedule)
        onArchiveChanged()
        Task { onSessionUploaded(sessionToArchive) }
        debugLog("[ReanalysisService] Re-analysis complete")
        return true
    }

    private func applyRecoveryScore(
        to session: inout HRVSession,
        analysisResult: HRVAnalysisResult,
        frozenTraining: TrainingContext?,
        originalSession: HRVSession,
        useBaselineHRV: Bool = false
    ) {
        if let frozen = frozenTraining {
            session.analysisResult?.trainingContext = frozen
        }
        if let result = deterministicRecoveryScore(for: session, result: analysisResult, useBaselineHRV: useBaselineHRV) {
            session.recoveryScore = result.score
            session.scoreBreakdown = result.breakdown
            session.frozenReadiness = Self.computeFrozenReadiness(
                compositeScore: result.breakdown.compositeScore,
                trainingContext: frozenTraining
            )
        }
        applyScoreFallbacks(to: &session, analysisResult: analysisResult, originalSession: originalSession)
    }

    /// Fallback chain: never let a reanalyzed session end up without a
    /// readiness score.
    private func applyScoreFallbacks(
        to session: inout HRVSession, analysisResult: HRVAnalysisResult, originalSession: HRVSession
    ) {
        if let score = session.recoveryScore, score.isNaN || score.isInfinite {
            debugLog("[ReanalysisService] Recovery score was NaN/Inf — falling back")
            session.recoveryScore = originalSession.recoveryScore
            session.scoreBreakdown = originalSession.scoreBreakdown
            session.frozenReadiness = originalSession.frozenReadiness
        }
        if session.recoveryScore == nil, let readiness = analysisResult.ansMetrics?.readinessScore {
            debugLog("[ReanalysisService] No composite score — using ANS readiness: \(String(format: "%.1f", readiness))")
            session.recoveryScore = readiness
        }
    }

    /// Determine which sleep segment the analysis window falls in and label it.
    private func labelAnalysisSegment(
        session: inout HRVSession,
        analysisResult: HRVAnalysisResult,
        originalSession: HRVSession
    ) {
        guard let windowStartMs = analysisResult.windowStartMs,
              let segments = originalSession.sleepSegments,
              segments.count > 1 else { return }

        for (i, seg) in segments.enumerated() {
            if windowStartMs >= seg.startMs, windowStartMs <= seg.endMs {
                let startDate = originalSession.startDate.addingTimeInterval(TimeInterval(seg.startMs) / 1000)
                let endDate = originalSession.startDate.addingTimeInterval(TimeInterval(seg.endMs) / 1000)
                let startStr = startDate.formatted(date: .omitted, time: .shortened)
                let endStr = endDate.formatted(date: .omitted, time: .shortened)
                session.analysisResult?.analysisSegmentLabel = String(localized: "Segment \(i + 1) (\(startStr)–\(endStr))", bundle: LanguageManager.appBundle)
                break
            }
        }
    }

    /// Score-only rebuild — no HRV reanalysis. Use when the existing
    /// `analysisResult` is fine and only the score breakdown needs to be
    /// recomputed (e.g. corrupted training snapshot got healed by the
    /// live cache, sleep landed late, vitals synced after acceptance).
    ///
    /// Why a separate path: `reanalyzeSession` requires a non-empty
    /// `rrSeries` and runs window-selection / artifact-detection over
    /// 20k+ RR points. That's overkill (and silently fails) when the
    /// only thing that changed is the training context. Crash-recovered
    /// sessions in particular sometimes land with empty `rrSeries` —
    /// reanalyze returns nil and the broken score is left in place
    /// forever. This path skips the RR work entirely.
    ///
    /// Same training-corruption heal as `reanalyzeSession`: when the
    /// frozen snapshot is the all-zero pattern, fall back to the live
    /// `AppDependencies.current.analysis.trainingMetricsCache.current`.
    /// Builds the score with the healed context. If nothing actually changed
    /// (no corruption to fix, no other input changes), the computed score
    /// matches the existing one and we just save the same values — cheap.
    func recomputeScoreOnly(sessionId: UUID) async -> HRVSession? {
        guard let session = try? archive.retrieve(sessionId) else {
            debugLog("[ReanalysisService] recomputeScoreOnly: session \(sessionId.uuidString.prefix(8)) not in archive")
            return nil
        }
        guard let result = session.analysisResult else {
            debugLog("[ReanalysisService] recomputeScoreOnly: session has no analysisResult — nothing to score from")
            return nil
        }
        let healedTraining = Self.healedTrainingContext(for: session, result: result)
        var updated = session
        if let healed = healedTraining {
            updated.trainingSnapshot = healed
            updated.analysisResult?.trainingContext = healed
        }
        let breakdown = rescoreBreakdown(session: session, result: result, training: healedTraining)
        updated.recoveryScore = RecoveryScoreCalculator.toTenScale(breakdown.compositeScore)
        updated.scoreBreakdown = breakdown
        updated.frozenReadiness = Self.computeFrozenReadiness(compositeScore: breakdown.compositeScore, trainingContext: healedTraining)
        return persistRescore(updated, previous: Self.scoreFingerprint(of: session))
    }

    /// Heal corrupted frozen training (same logic as in reanalyzeSession;
    /// kept separate so this path is self-contained). When the
    /// frozen snapshot is the all-zero pattern, fall back to the live
    /// `AppDependencies.current.analysis.trainingMetricsCache.current`.
    private static func healedTrainingContext(
        for session: HRVSession, result: HRVAnalysisResult
    ) -> TrainingContext? {
        let frozenCandidate = session.trainingSnapshot ?? result.trainingContext
        if let candidate = frozenCandidate, candidate.atl > 0 || candidate.ctl > 0 { return candidate }
        guard let live = AppDependencies.current.analysis.trainingMetricsCache.current, live.atl > 0 || live.ctl > 0 else {
            return frozenCandidate
        }
        return TrainingContext(
            atl: live.atl,
            ctl: live.ctl,
            tsb: live.tsb,
            yesterdayTrimp: live.todayTrimp,
            vo2Max: frozenCandidate?.vo2Max,
            daysSinceHardWorkout: frozenCandidate?.daysSinceHardWorkout,
            recentWorkouts: frozenCandidate?.recentWorkouts
        )
    }

    /// Mirrors the acceptance path's ANS-balance term (pns − sns). Omitting it
    /// made a re-score drift by the HRV-factor's ANS adjustment (up to ~4
    /// composite points) for a reason unrelated to what changed.
    private static func ansBalance(of result: HRVAnalysisResult) -> Double? {
        guard let pns = result.ansMetrics?.pnsIndex, let sns = result.ansMetrics?.snsIndex else { return nil }
        return pns - sns
    }

    private func rescoreBreakdown(
        session: HRVSession, result: HRVAnalysisResult, training: TrainingContext?
    ) -> RecoveryScoreCalculator.ScoreBreakdown {
        return RecoveryScoreCalculator.calculateWithBreakdown(
            RecoveryScoreCalculator.ScoreInputs(
                hrvReadiness: result.ansMetrics?.readinessScore, rmssd: result.timeDomain.rmssd,
                meanHR: result.timeDomain.meanHR, dfaAlpha1: result.nonlinear.dfaAlpha1,
                baselineStats: baselineTracker.recoveryBaselineStats, sleepData: session.sleepSnapshot,
                vitals: session.vitalsSnapshot, typicalSleepHours: settingsProvider().typicalSleepHours
            ),
            trainingContext: training,
            config: scoringConfigProvider(),
            // §13.3: see deriveUseBaselineHRVOnRescore.
            useBaselineHRV: !session.isReliableForHRVAggregates,
            ansBalance: Self.ansBalance(of: result),
            // Anchor staleness penalty to the session, not the
            // wall clock, so re-scoring the same night is deterministic.
            referenceDate: session.endDate ?? session.startDate
        )
    }

    /// The two numbers the recompute log compares before/after. Factor lookup
    /// is by label match — `factors` is an [ScoreFactor] (label/score/weight
    /// tuples), not a struct with named fields.
    private static func scoreFingerprint(of session: HRVSession) -> (score: Double, trainingFactor: Double) {
        (
            session.recoveryScore ?? -1,
            session.scoreBreakdown?.factors.first { $0.label.lowercased().contains("training") }?.score ?? -1
        )
    }

    /// Recovery score / training factor / ATL / CTL are PHI and debugLog is
    /// user-exportable. Log that a score recompute occurred and whether the
    /// score changed, without the numeric health values.
    private func persistRescore(
        _ updated: HRVSession, previous: (score: Double, trainingFactor: Double)
    ) -> HRVSession? {
        do {
            try archive.archive(updated)
            onArchiveChanged()
            let sessionToUpload = updated
            Task { [onSessionUploaded] in onSessionUploaded(sessionToUpload) }
            let current = Self.scoreFingerprint(of: updated)
            let scoreChanged = current.score != previous.score
            let factorChanged = current.trainingFactor != previous.trainingFactor
            debugLog("[ReanalysisService] recomputeScoreOnly: recomputed (score \(scoreChanged ? "changed" : "unchanged"), training factor \(factorChanged ? "changed" : "unchanged"))")
            return updated
        } catch {
            debugLog("[ReanalysisService] recomputeScoreOnly: archive write failed: \(error)")
            return nil
        }
    }

    /// Deterministic/local recovery score recompute for reanalysis paths.
    /// Uses persisted snapshots and current baselines/config, avoiding live HealthKit fetches.
    /// Returns (score on 0-10 scale, breakdown) or nil if no analysis result.
    ///
    /// `ansBalance` mirrors the acceptance path's (pns − sns) term so a
    /// deterministic re-score matches the frozen score instead of drifting by
    /// the HRV-factor ANS adjustment.
    ///
    /// §13.3: `useBaselineHRV` is derived from the session so an
    /// untrustworthy night can't drift up on re-score. Flag off → honor the
    /// passed param.
    ///
    /// Deterministic re-score anchors `referenceDate` to the
    /// session date rather than the wall clock.
    func deterministicRecoveryScore(for session: HRVSession, result: HRVAnalysisResult?, useBaselineHRV: Bool = false) -> (score: Double, breakdown: RecoveryScoreCalculator.ScoreBreakdown)? {
        guard let result else { return nil }
        let sessionDate = session.endDate ?? session.startDate
        let trainingContext = session.trainingSnapshot ?? result.trainingContext ?? trainingContextProvider(sessionDate)

        let breakdown = RecoveryScoreCalculator.calculateWithBreakdown(
            RecoveryScoreCalculator.ScoreInputs(
                hrvReadiness: result.ansMetrics?.readinessScore, rmssd: result.timeDomain.rmssd,
                meanHR: result.timeDomain.meanHR, dfaAlpha1: result.nonlinear.dfaAlpha1,
                baselineStats: baselineTracker.recoveryBaselineStats, sleepData: session.sleepSnapshot,
                vitals: session.vitalsSnapshot, typicalSleepHours: settingsProvider().typicalSleepHours
            ),
            trainingContext: trainingContext,
            config: scoringConfigProvider(),
            useBaselineHRV: !session.isReliableForHRVAggregates,
            ansBalance: Self.ansBalance(of: result),
            referenceDate: sessionDate
        )
        return (RecoveryScoreCalculator.toTenScale(breakdown.compositeScore), breakdown)
    }

    /// Sessions with RR data, optionally bounded by a date range.
    ///
    /// The upper bound is inclusive to the END of `to`'s day — a user picking
    /// "up to the 14th" means through the 14th, not up to midnight starting it.
    static func sessionsInRange(_ sessions: [HRVSession], from: Date?, to: Date?) -> [HRVSession] {
        var filtered = sessions.filter { $0.rrSeries != nil && !($0.rrSeries?.points.isEmpty ?? true) }
        if let from {
            filtered = filtered.filter { $0.startDate >= from }
        }
        if let to {
            let endOfDay = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: to) ?? to
            filtered = filtered.filter { $0.startDate <= endOfDay }
        }
        return filtered
    }

    /// Re-analyze all sessions with current algorithms.
    /// Returns (updated, skipped) where skipped counts sessions with manual window overrides.
    func reanalyzeAllSessions(
        sessions: [HRVSession],
        from: Date? = nil,
        to: Date? = nil,
        progress: @escaping (Int, Int) -> Void = { _, _ in }
    ) async -> (updated: Int, skipped: Int) {
        let filtered = Self.sessionsInRange(sessions, from: from, to: to)

        var successCount = 0
        var skippedCount = 0

        for (index, session) in filtered.enumerated() {
            if Task.isCancelled { break }
            if session.windowUserAdjusted == true {
                skippedCount += 1
            } else if await reanalyzeSession(session, preserveManualWindows: true) != nil {
                successCount += 1
            }
            progress(index + 1, filtered.count)
        }

        debugLog("[ReanalysisService] Re-analyzed \(successCount)/\(filtered.count) sessions, \(skippedCount) manual windows preserved\(Task.isCancelled ? " (cancelled)" : "")")
        return (updated: successCount, skipped: skippedCount)
    }
}
