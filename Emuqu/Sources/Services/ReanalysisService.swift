import Foundation

/// Owns all re-analysis, manual window selection, sleep retro-apply, and
/// session mutation logic.
///
/// Dependencies are injected explicitly so the service is testable without
/// an `RRCollector` instance. One exception: `persist` drops the session's
/// entry from `AppDependencies.current.app.organizedZonesCache`.
@MainActor
final class ReanalysisService {
    // MARK: - Shared Readiness Computation

    /// The insufficient-data rule (rule 1 of
    /// `SessionAcceptanceService.classifyHRVQuality`) for the morning
    /// pre-score gate and the insufficient-data migration. It delegates to
    /// `SessionAcceptanceService.isInsufficientData`, the one implementation
    /// acceptance also uses, so the paths cannot disagree. Returns `true`
    /// iff the session has too little signal for a reliable HRV score:
    /// either the analysed span (the window, or the whole session when no
    /// window was found) is shorter than the minimum reliable window, or
    /// there's no organized-recovery evidence and the session itself is
    /// shorter than the overnight-minimum duration. Reanalysis re-runs the
    /// whole classifier (`reclassifyHRVQuality`), not just this rule.
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
        let sessionEnd = session.endDate ?? session.startDate
        return SessionAcceptanceService.isInsufficientData(
            result: analysisResult,
            baselineRmssd: baselineRmssd,
            sessionDuration: sessionEnd.timeIntervalSince(session.startDate)
        )
    }

    /// Compute frozen readiness from a composite score and training context,
    /// with todayTrimp = 0, as SessionAcceptanceService does, so every freeze
    /// point produces the same result.
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

    /// Closure returning the ANS configuration for analysing a session: its
    /// own day's training load and the baseline of the nights before it.
    let ansConfigProvider: (HRVSession) -> HRVAnalysisPipeline.ANSConfiguration

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
        ansConfigProvider: @escaping (HRVSession) -> HRVAnalysisPipeline.ANSConfiguration,
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

    /// Artifact detection and window selection, off the main actor.
    ///
    /// Both are pure CPU passes over 20k+ RR points. Running them on the main
    /// actor froze the UI behind the reanalysis spinner, so the inputs are
    /// captured here and the scan runs on a detached task.
    private func detectAndSelectWindow(
        series: RRSeries,
        method: WindowSelectionMethod,
        sleepStartMs: Int64?,
        wakeTimeMs: Int64?,
        baselineStats: BaselineTracker.RecoveryBaselineStats?
    ) async -> (flags: [ArtifactFlags], result: WindowSelector.WindowSelectionResult) {
        // Artifact detection + window selection are pure CPU work over 20k+
        // RR points. Run them off the main actor so the UI stays responsive
        // while reanalysis runs. The service is @MainActor (for archive/UI
        // callback safety); detaching here is the opt-out for heavy compute.
        let artifactDetector = artifactDetector
        let windowSelector = windowSelector
        return await Task.detached(priority: .userInitiated) {
            let flags = artifactDetector.detectArtifacts(in: series)
            let windowResult = Self.selectWindow(
                method: method, series: series, flags: flags,
                sleepStartMs: sleepStartMs, wakeTimeMs: wakeTimeMs,
                selector: windowSelector, baselineStats: baselineStats
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
    /// Like the scorer, it leaves out the session's own night: a reading is
    /// compared with the nights before it, never with itself.
    func scoringBaseline(for session: HRVSession) -> BaselineTracker.RecoveryBaselineStats? {
        baselineTracker.recoveryBaselineStats(
            excludingNightOf: session, sleepSchedule: settingsProvider().sleepSchedule
        )
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

    /// Re-analyze a session with current algorithms.
    /// - Parameter preserveManualWindows: When true (batch mode), sessions with
    ///   `windowUserAdjusted == true` are skipped to preserve manual picks.
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
            sleepStartMs: bounds.sleepStartMs, wakeTimeMs: bounds.wakeTimeMs,
            baselineStats: scoringBaseline(for: session)
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
    /// The new window's result is classified again, so the dashboard shows
    /// SubjectiveReadinessCard instead of a misleading score when the data is
    /// insufficient, and a mark that no longer applies clears.
    private func applyAnalysis(_ analysisResult: HRVAnalysisResult, to session: inout HRVSession) {
        session.analysisResult = analysisResult
        session.analysisResult?.isReanalysis = true
        session.windowUserAdjusted = nil
        reclassifyHRVQuality(of: &session, result: analysisResult)
    }

    /// Runs the acceptance classifier (`SessionAcceptanceService
    /// .classifyHRVQuality`, every rule: insufficient data, no sleep overlap,
    /// short session below baseline) against `result`, the session's current
    /// sleep snapshot and the nights before this one — the baseline the window
    /// and the score use — so a re-scored session is classified exactly as
    /// acceptance would classify it now. Every path that changes the window
    /// result or the sleep calls it before re-scoring.
    func reclassifyHRVQuality(of session: inout HRVSession, result: HRVAnalysisResult) {
        let previous = session.hrvDataQuality
        session.hrvDataQuality = SessionAcceptanceService.classifyHRVQuality(
            result: result, sleepData: session.sleepSnapshot, baselineStats: scoringBaseline(for: session),
            recordingStart: session.startDate, recordingEnd: session.endDate ?? session.startDate
        ).dataQuality
        guard session.hrvDataQuality != previous else { return }
        // Health values (RMSSD, baseline) are PHI and debugLog is
        // user-exportable — log the transition without the numeric values.
        debugLog("[ReanalysisService] HRV data quality \(previous?.rawValue ?? "unset") → \(session.hrvDataQuality?.rawValue ?? "unset")")
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
            originalSession: session
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
        // ATL / CTL are PHI and debugLog is user-exportable: log that the
        // snapshot was restored, not the values.
        debugLog("[ReanalysisService] Reanalyze: restored the wake-time trainingSnapshot (it differed from the stored one)")
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
        originalSession: HRVSession
    ) {
        if let frozen = frozenTraining {
            session.analysisResult?.trainingContext = frozen
        }
        let scored = deterministicRecoveryScore(for: session, result: analysisResult)
        session.recoveryScore = scored.score
        session.scoreBreakdown = scored.breakdown
        session.frozenReadiness = Self.computeFrozenReadiness(
            compositeScore: scored.breakdown.compositeScore,
            trainingContext: frozenTraining
        )
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
                let timeStyle = Date.FormatStyle(date: .omitted, time: .shortened).locale(LanguageManager.appLocale)
                let startStr = startDate.formatted(timeStyle)
                let endStr = endDate.formatted(timeStyle)
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
    /// Training heal: when the frozen snapshot is the all-zero pattern, the
    /// context is rebuilt as of the session's wake with the reconstruction
    /// `reanalyzeSession` uses (`wakeTimeTraining`), so the night is never
    /// scored on today's load. Builds the score with the healed context. If nothing actually changed
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
        let healedTraining = await healedTrainingContext(for: session, result: result)
        guard let updated = rescored(session, result: result, training: healedTraining) else { return nil }
        return persistRescore(updated, previous: Self.scoreFingerprint(of: session))
    }

    /// `session` with the healed training context stamped on and the score,
    /// breakdown and frozen readiness rebuilt against it. Nil when the
    /// composite is NaN/Inf, so the stored score is left in place rather
    /// than archived and uploaded broken.
    private func rescored(
        _ session: HRVSession, result: HRVAnalysisResult, training: TrainingContext?
    ) -> HRVSession? {
        var updated = session
        if let healed = training {
            updated.trainingSnapshot = healed
            updated.analysisResult?.trainingContext = healed
        }
        let breakdown = rescoredBreakdown(
            of: session, result: result, training: training, referenceDate: session.endDate ?? session.startDate
        )
        guard breakdown.compositeScore.isFinite else {
            debugLog("[ReanalysisService] recomputeScoreOnly: composite score was NaN/Inf — leaving the stored score in place")
            return nil
        }
        updated.recoveryScore = RecoveryScoreCalculator.toTenScale(breakdown.compositeScore)
        updated.scoreBreakdown = breakdown
        updated.frozenReadiness = Self.computeFrozenReadiness(compositeScore: breakdown.compositeScore, trainingContext: training)
        return updated
    }

    /// The frozen training context, or — when it is the all-zero pattern of
    /// a corrupted snapshot — the context rebuilt as of the session's wake.
    /// Not the live cache: that includes today's training, which would
    /// change a historical night's score with what the user did since.
    private func healedTrainingContext(
        for session: HRVSession, result: HRVAnalysisResult
    ) async -> TrainingContext? {
        let frozenCandidate = session.trainingSnapshot ?? result.trainingContext
        if let candidate = frozenCandidate, candidate.atl > 0 || candidate.ctl > 0 { return candidate }
        let sessionEndDate = session.endDate ?? session.startDate.addingTimeInterval(12 * 60 * 60)
        return await wakeTimeTraining(candidate: frozenCandidate, sessionEndDate: sessionEndDate)
    }

    /// Mirrors the acceptance path's ANS-balance term (pns − sns). Omitting it
    /// made a re-score drift by the HRV-factor's ANS adjustment (up to ~4
    /// composite points) for a reason unrelated to what changed. The one
    /// copy every re-score and acceptance read.
    static func ansBalance(of result: HRVAnalysisResult) -> Double? {
        guard let pns = result.ansMetrics?.pnsIndex, let sns = result.ansMetrics?.snsIndex else { return nil }
        return pns - sns
    }

    /// The vitals a re-score reads, with the strap's nocturnal heart rate in
    /// place of Apple Health's daytime resting HR — the swap the acceptance
    /// path makes before it freezes the snapshot.
    ///
    /// A snapshot written by another path (an iCloud backfill on a second
    /// device stores `fetchRecoveryVitals` as-is) still carries the daytime
    /// value, and re-scoring it compared daytime HR with a nocturnal baseline:
    /// the same night scored differently on each device. Applying the swap
    /// here makes every re-score read the same physiology whichever path
    /// wrote the snapshot; on a snapshot that already has it, it is a no-op.
    static func scoringVitals(of session: HRVSession, result: HRVAnalysisResult) -> RecoveryVitals? {
        session.vitalsSnapshot?.withStrapNocturnalRHR(result.timeDomain.meanHR)
    }

    /// The one re-score every reanalysis path runs: `result`'s metrics, the
    /// session's frozen sleep and vitals snapshots, the nights before it,
    /// the current scoring config, and `training`. Baseline HRV stands in for
    /// the session's own whenever the session is not reliable for aggregates
    /// (`.insufficient` or `.preSleep`), so an untrustworthy night can't drift
    /// up on re-score. `referenceDate` anchors the staleness penalty to the
    /// session, not the wall clock, so re-scoring the same night is
    /// deterministic.
    func rescoredBreakdown(
        of session: HRVSession, result: HRVAnalysisResult, training: TrainingContext?, referenceDate: Date
    ) -> RecoveryScoreCalculator.ScoreBreakdown {
        RecoveryScoreCalculator.calculateWithBreakdown(
            RecoveryScoreCalculator.ScoreInputs(
                hrvReadiness: result.ansMetrics?.readinessScore, rmssd: result.timeDomain.rmssd,
                meanHR: result.timeDomain.meanHR, dfaAlpha1: result.nonlinear.dfaAlpha1,
                baselineStats: scoringBaseline(for: session), sleepData: session.sleepSnapshot,
                vitals: Self.scoringVitals(of: session, result: result), typicalSleepHours: settingsProvider().typicalSleepHours
            ),
            trainingContext: training,
            config: scoringConfigProvider(),
            useBaselineHRV: !session.isReliableForHRVAggregates,
            perceivedReadiness: session.perceivedReadiness,
            ansBalance: Self.ansBalance(of: result),
            referenceDate: referenceDate
        )
    }

    /// What the recompute log compares before/after: the score, and the
    /// training load it was scored on. The load is read from the snapshot,
    /// not found among the breakdown's factors by label — the labels are in
    /// the app's language.
    private static func scoreFingerprint(of session: HRVSession) -> (score: Double, trainingLoad: [Double]) {
        (session.recoveryScore ?? -1, [session.trainingSnapshot?.atl ?? -1, session.trainingSnapshot?.ctl ?? -1])
    }

    /// Recovery score / training factor / ATL / CTL are PHI and debugLog is
    /// user-exportable. Log that a score recompute occurred and whether the
    /// score changed, without the numeric health values.
    private func persistRescore(
        _ updated: HRVSession, previous: (score: Double, trainingLoad: [Double])
    ) -> HRVSession? {
        do {
            try archive.archive(updated)
            onArchiveChanged()
            let sessionToUpload = updated
            Task { [onSessionUploaded] in onSessionUploaded(sessionToUpload) }
            let current = Self.scoreFingerprint(of: updated)
            let scoreChanged = current.score != previous.score
            let loadChanged = current.trainingLoad != previous.trainingLoad
            debugLog("[ReanalysisService] recomputeScoreOnly: recomputed (score \(scoreChanged ? "changed" : "unchanged"), training load \(loadChanged ? "changed" : "unchanged"))")
            return updated
        } catch {
            debugLog("[ReanalysisService] recomputeScoreOnly: archive write failed: \(error)")
            return nil
        }
    }

    /// Deterministic/local recovery score recompute for reanalysis paths:
    /// `rescoredBreakdown` against the frozen training context (the stored
    /// snapshot, else the result's, else the one built for the session date),
    /// anchored to the session date. No live HealthKit fetches.
    /// Returns (score on 0-10 scale, breakdown).
    func deterministicRecoveryScore(for session: HRVSession, result: HRVAnalysisResult) -> (score: Double, breakdown: RecoveryScoreCalculator.ScoreBreakdown) {
        let sessionDate = session.endDate ?? session.startDate
        let trainingContext = session.trainingSnapshot ?? result.trainingContext ?? trainingContextProvider(sessionDate)
        let breakdown = rescoredBreakdown(
            of: session, result: result, training: trainingContext, referenceDate: sessionDate
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

    /// Re-analyze all sessions with current algorithms, each through this
    /// service's own `reanalyzeSession`, which reads the training load only
    /// from what the caller has already loaded. Prefer
    /// `reanalyzeAllSessions(sessions:from:to:reanalyzeOne:progress:)` with
    /// the coordinator's per-session pass.
    /// Returns (updated, skipped) where skipped counts sessions with manual window overrides.
    func reanalyzeAllSessions(
        sessions: [HRVSession],
        from: Date? = nil,
        to: Date? = nil,
        progress: @escaping (Int, Int) -> Void = { _, _ in }
    ) async -> (updated: Int, skipped: Int) {
        await reanalyzeAllSessions(
            sessions: sessions, from: from, to: to,
            reanalyzeOne: { await self.reanalyzeSession($0, preserveManualWindows: true) },
            progress: progress
        )
    }

    /// Re-analyze all sessions with current algorithms, `reanalyzeOne` running
    /// each session's pass. The collector's coordinator passes its own
    /// `reanalyzeSession`, which loads the session's past-day training load
    /// first and holds the in-flight guard, so a bulk pass scores a night
    /// exactly as single-session Reanalyze does.
    /// Returns (updated, skipped) where skipped counts sessions with manual window overrides.
    func reanalyzeAllSessions(
        sessions: [HRVSession],
        from: Date?,
        to: Date?,
        reanalyzeOne: (HRVSession) async -> HRVSession?,
        progress: @escaping (Int, Int) -> Void
    ) async -> (updated: Int, skipped: Int) {
        let filtered = Self.sessionsInRange(sessions, from: from, to: to)

        var successCount = 0
        var skippedCount = 0

        for (index, session) in filtered.enumerated() {
            if Task.isCancelled { break }
            if session.windowUserAdjusted == true {
                skippedCount += 1
            } else if await reanalyzeOne(session) != nil {
                successCount += 1
            }
            progress(index + 1, filtered.count)
        }

        debugLog("[ReanalysisService] Re-analyzed \(successCount)/\(filtered.count) sessions, \(skippedCount) manual windows preserved\(Task.isCancelled ? " (cancelled)" : "")")
        return (updated: successCount, skipped: skippedCount)
    }
}
