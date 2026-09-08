import Foundation

/// Pure HRV analysis pipeline — no UI state, no archive, no device interaction.
/// Extracted from RRCollector to isolate analysis computation from collection orchestration.
///
/// All functions take explicit inputs and return results. The only async dependency
/// is a HealthKit service (injected via protocol) for daytime resting HR used in
/// nocturnal HR dip calculation.
final class HRVAnalysisPipeline: Sendable {
    // MARK: - Dependencies

    // Internal, not private: the computation half lives in
    // HRVAnalysisPipeline+Metrics.swift, and Swift's `private` does not reach
    // across files even within the same type.
    let artifactDetector: ArtifactDetector
    let windowSelector: WindowSelector
    let healthKit: HealthKitServiceProtocol

    // MARK: - Initialization

    init(
        artifactDetector: ArtifactDetector,
        windowSelector: WindowSelector,
        healthKit: HealthKitServiceProtocol
    ) {
        self.artifactDetector = artifactDetector
        self.windowSelector = windowSelector
        self.healthKit = healthKit
    }

    // MARK: - Configuration for ANS Metrics

    /// Settings needed for ANS metric computation, provided by the caller.
    struct ANSConfiguration {
        let baselineRMSSD: Double
        let vo2Max: Double?
        let trainingLoadAdjustment: Double
    }

    // MARK: - Public API

    /// The shared core of every analysis path: the four metric families over one
    /// index range, assembled into a result that carries no window metadata yet.
    ///
    /// Shared rather than copied into the four entry points: as copies,
    /// two of them had drifted in which errors they logged.
    private func analyzeRange(
        session: HRVSession,
        series: RRSeries,
        flags: [ArtifactFlags],
        start windowStart: Int,
        end windowEnd: Int,
        ansConfig: ANSConfiguration
    ) async -> HRVAnalysisResult? {
        let sessionId = session.id
        guard let td = computeTimeDomain(series: series, flags: flags, start: windowStart, end: windowEnd) else {
            logPipelineError(.timeDomainFailed(sessionId: sessionId, windowStart: windowStart, windowEnd: windowEnd))
            return nil
        }
        guard let nl = computeNonlinear(series: series, flags: flags, start: windowStart, end: windowEnd) else {
            logPipelineError(.nonlinearFailed(sessionId: sessionId, windowStart: windowStart, windowEnd: windowEnd))
            return nil
        }
        let ansMetrics = await ansMetrics(
            session: session, series: series, flags: flags,
            start: windowStart, end: windowEnd,
            domains: (td, nl), config: ansConfig
        )
        return rangeResult(
            series: series, flags: flags, start: windowStart, end: windowEnd,
            timeDomain: td, nonlinear: nl, ansMetrics: ansMetrics
        )
    }

    private func rangeResult(
        series: RRSeries,
        flags: [ArtifactFlags],
        start windowStart: Int,
        end windowEnd: Int,
        timeDomain td: TimeDomainMetrics,
        nonlinear nl: NonlinearMetrics,
        ansMetrics: ANSMetrics
    ) -> HRVAnalysisResult {
        return HRVAnalysisResult(
            windowStart: windowStart,
            windowEnd: windowEnd,
            timeDomain: td,
            frequencyDomain: computeFrequencyDomain(series: series, flags: flags, start: windowStart, end: windowEnd),
            nonlinear: nl,
            ansMetrics: ansMetrics,
            artifactPercentage: artifactDetector.artifactPercentage(flags, start: windowStart, end: windowEnd),
            cleanBeatCount: flags[windowStart ..< windowEnd].filter { !$0.isArtifact }.count,
            analysisDate: Date()
        )
    }

    /// ANS metrics need the user's daytime resting HR, which is an async
    /// HealthKit read — kept out of the range computation so that stays sync.
    private func ansMetrics(
        session: HRVSession,
        series: RRSeries,
        flags: [ArtifactFlags],
        start windowStart: Int,
        end windowEnd: Int,
        domains: (time: TimeDomainMetrics, nonlinear: NonlinearMetrics),
        config ansConfig: ANSConfiguration
    ) async -> ANSMetrics {
        let (td, nl) = domains
        return computeANSMetrics(
            series: series,
            flags: flags,
            windowStart: windowStart,
            windowEnd: windowEnd,
            timeDomain: td,
            nonlinear: nl,
            daytimeRestingHR: await fetchDaytimeRestingHR(for: session.startDate, sessionId: session.id),
            config: ansConfig
        )
    }

    /// Analyze session within a specific recovery window (primary overnight path).
    func analyzeWithWindow(
        session: HRVSession,
        window: WindowSelector.RecoveryWindow,
        flags: [ArtifactFlags],
        peakCapacity: PeakCapacity?,
        trainingContext: TrainingContext?,
        ansConfig: ANSConfiguration
    ) async -> HRVAnalysisResult? {
        let sessionId = session.id
        debugLog("[HRVAnalysisPipeline] analyzeWithWindow start session=\(sessionId.uuidString.prefix(8)) window=[\(window.startIndex)..<\(window.endIndex)]")
        guard let series = session.rrSeries else {
            logPipelineError(.noRRSeries(sessionId: sessionId))
            return nil
        }
        guard var result = await analyzeRange(
            session: session, series: series, flags: flags,
            start: window.startIndex, end: window.endIndex, ansConfig: ansConfig
        ) else { return nil }
        attachWindowMetadata(&result, window: window)
        result.peakCapacity = peakCapacity
        result.trainingContext = trainingContext
        Self.attachOvernightHRStats(&result, series: series, flags: flags)
        debugLog("[HRVAnalysisPipeline] analyzeWithWindow complete session=\(sessionId.uuidString.prefix(8)) cleanBeats=\(result.cleanBeatCount)")
        return result
    }

    /// Everything the window selector decided, carried onto the result so the
    /// UI can explain which slice of the night was read.
    private func attachWindowMetadata(_ result: inout HRVAnalysisResult, window: WindowSelector.RecoveryWindow) {
        result.windowStartMs = window.startMs
        result.windowEndMs = window.endMs
        result.windowMeanHR = window.meanHR
        result.windowHRStability = window.hrStability
        result.windowSelectionReason = window.selectionReason
        result.windowRelativePosition = window.relativePosition
        result.isConsolidated = window.isConsolidated
        result.isOrganizedRecovery = window.isOrganizedRecovery
        result.windowClassification = window.windowClassification.rawValue
    }

    /// Analyze full session when no organized recovery window detected.
    func analyzeFullSession(
        session: HRVSession,
        peakCapacity: PeakCapacity?,
        trainingContext: TrainingContext?,
        ansConfig: ANSConfiguration
    ) async -> HRVAnalysisResult? {
        let sessionId = session.id
        debugLog("[HRVAnalysisPipeline] analyzeFullSession start session=\(sessionId.uuidString.prefix(8))")
        guard let series = session.rrSeries else {
            logPipelineError(.noRRSeries(sessionId: sessionId))
            return nil
        }
        let flags = artifactDetector.detectArtifacts(in: series)
        guard var result = await analyzeRange(
            session: session, series: series, flags: flags,
            start: 0, end: series.points.count, ansConfig: ansConfig
        ) else { return nil }
        attachFullSessionMetadata(&result, series: series)
        result.peakCapacity = peakCapacity
        result.trainingContext = trainingContext
        Self.attachOvernightHRStats(&result, series: series, flags: flags)
        debugLog("[HRVAnalysisPipeline] analyzeFullSession complete session=\(sessionId.uuidString.prefix(8)) beats=\(series.points.count)")
        return result
    }

    /// No window was chosen, so the "window" is the whole recording and the
    /// window-quality fields are deliberately nil rather than misleading.
    private func attachFullSessionMetadata(_ result: inout HRVAnalysisResult, series: RRSeries) {
        result.windowStartMs = series.points.first?.t_ms ?? 0
        result.windowEndMs = series.points.last?.endMs ?? 0
        result.windowMeanHR = nil
        result.windowHRStability = nil
        result.windowSelectionReason = "No consolidated recovery detected"
        result.windowRelativePosition = nil
        result.isConsolidated = false
        result.isOrganizedRecovery = false
        result.windowClassification = WindowSelector.RecoveryWindow.WindowClassification.highVariability.rawValue
    }

    /// Fallback: analyze session with automatic window selection and optional HealthKit boundaries.
    ///
    /// `baselineStats` — when provided, organized-recovery-window selection
    /// ranks by Tier 1 recovery score (z-score + DFA + RHR) instead of raw
    /// RMSSD. Without baseline, selection falls back to RMSSD ranking. Pass
    /// the same baseline the scorer will use, otherwise the auto-pick and
    /// the displayed score can disagree.
    func analyzeWithAutoWindow(
        session: HRVSession,
        sleepStartMs: Int64?,
        wakeTimeMs: Int64?,
        trainingContext: TrainingContext?,
        ansConfig: ANSConfiguration,
        baselineStats: BaselineTracker.RecoveryBaselineStats? = nil
    ) async -> HRVAnalysisResult? {
        let sessionId = session.id
        debugLog("[HRVAnalysisPipeline] analyzeWithAutoWindow start session=\(sessionId.uuidString.prefix(8))")
        guard let series = session.rrSeries else {
            logPipelineError(.noRRSeries(sessionId: sessionId))
            return nil
        }
        let flags = artifactDetector.detectArtifacts(in: series)
        guard let windowResult = windowSelector.findBestWindowWithCapacity(
            in: series, flags: flags, sleepStartMs: sleepStartMs,
            wakeTimeMs: wakeTimeMs, baselineStats: baselineStats
        ) else {
            logPipelineError(.windowSelectionFailed(sessionId: sessionId))
            return nil
        }
        // Capture organized zones before the next call overwrites them; they
        // become the chart's green overlay.
        let organizedZones = windowSelector.lastOrganizedZones
        var result = await analyzeSelectedWindow(session: session, flags: flags, windowResult: windowResult, trainingContext: trainingContext, ansConfig: ansConfig)
        result?.organizedRecoveryZones = organizedZones.isEmpty ? nil : organizedZones
        return result
    }

    /// Runs whichever path the selector's verdict calls for.
    private func analyzeSelectedWindow(
        session: HRVSession,
        flags: [ArtifactFlags],
        windowResult: WindowSelector.WindowSelectionResult,
        trainingContext: TrainingContext?,
        ansConfig: ANSConfiguration
    ) async -> HRVAnalysisResult? {
        guard let recoveryWindow = windowResult.recoveryWindow else {
            return await analyzeFullSession(
                session: session,
                peakCapacity: windowResult.peakCapacity,
                trainingContext: trainingContext,
                ansConfig: ansConfig
            )
        }
        return await analyzeWithWindow(
            session: session,
            window: recoveryWindow,
            flags: flags,
            peakCapacity: windowResult.peakCapacity,
            trainingContext: trainingContext,
            ansConfig: ansConfig
        )
    }

    /// Analyze full series without window selection (streaming mode).
    func analyzeFullSeries(
        series: RRSeries,
        flags: [ArtifactFlags],
        windowStart: Int = 0,
        windowEnd: Int? = nil,
        trainingContext: TrainingContext? = nil,
        ansConfig: ANSConfiguration? = nil
    ) -> HRVAnalysisResult? {
        let sessionId = series.sessionId
        let windowEndIdx = windowEnd ?? series.points.count
        let effectiveStart = max(0, min(windowStart, series.points.count))
        let effectiveEnd = min(windowEndIdx, series.points.count)
        guard effectiveEnd > effectiveStart else {
            logPipelineError(.insufficientRange(sessionId: sessionId, start: effectiveStart, end: effectiveEnd))
            return nil
        }
        debugLog("[HRVAnalysisPipeline] analyzeFullSeries session=\(sessionId.uuidString.prefix(8)) range=[\(effectiveStart)..<\(effectiveEnd)]")
        guard var result = fullSeriesResult(
            series: series, flags: flags,
            start: effectiveStart, end: effectiveEnd,
            windowStart: windowStart, windowEnd: windowEndIdx,
            ansConfig: ansConfig
        ) else { return nil }
        result.trainingContext = trainingContext
        Self.attachOvernightHRStats(&result, series: series, flags: flags)
        return result
    }

    /// The sync (streaming) counterpart of `analyzeRange` — no HealthKit read,
    /// so no daytime resting HR to fold into the ANS metrics.
    private func fullSeriesResult(
        series: RRSeries,
        flags: [ArtifactFlags],
        start effectiveStart: Int,
        end effectiveEnd: Int,
        windowStart: Int,
        windowEnd windowEndIdx: Int,
        ansConfig: ANSConfiguration?
    ) -> HRVAnalysisResult? {
        let sessionId = series.sessionId
        guard let td = computeTimeDomain(series: series, flags: flags, start: effectiveStart, end: effectiveEnd) else {
            logPipelineError(.timeDomainFailed(sessionId: sessionId, windowStart: effectiveStart, windowEnd: effectiveEnd))
            return nil
        }
        guard let nl = computeNonlinear(series: series, flags: flags, start: effectiveStart, end: effectiveEnd) else {
            logPipelineError(.nonlinearFailed(sessionId: sessionId, windowStart: effectiveStart, windowEnd: effectiveEnd))
            return nil
        }
        let ansMetrics = computeANSMetrics(
            series: series, flags: flags, windowStart: effectiveStart, windowEnd: effectiveEnd,
            timeDomain: td, nonlinear: nl,
            config: ansConfig ?? ANSConfiguration(baselineRMSSD: 40.0, vo2Max: nil, trainingLoadAdjustment: 0)
        )
        return streamingResult(
            series: series, flags: flags,
            range: effectiveStart ..< effectiveEnd,
            reportedWindow: windowStart ..< windowEndIdx,
            metrics: RangeMetrics(timeDomain: td, nonlinear: nl, ans: ansMetrics)
        )
    }

    private func streamingResult(
        series: RRSeries,
        flags: [ArtifactFlags],
        range: Range<Int>,
        reportedWindow: Range<Int>,
        metrics: RangeMetrics
    ) -> HRVAnalysisResult {
        let (effectiveStart, effectiveEnd) = (range.lowerBound, range.upperBound)
        let (windowStart, windowEndIdx) = (reportedWindow.lowerBound, reportedWindow.upperBound)
        let (td, nl, ansMetrics) = (metrics.timeDomain, metrics.nonlinear, metrics.ans)
        let clipped = min(effectiveEnd, flags.count)
        return HRVAnalysisResult(
            windowStart: windowStart,
            windowEnd: windowEndIdx,
            timeDomain: td,
            frequencyDomain: computeFrequencyDomain(series: series, flags: flags, start: effectiveStart, end: effectiveEnd),
            nonlinear: nl,
            ansMetrics: ansMetrics,
            artifactPercentage: artifactDetector.artifactPercentage(flags, start: effectiveStart, end: clipped),
            cleanBeatCount: flags[effectiveStart ..< clipped].filter { !$0.isArtifact }.count,
            analysisDate: Date()
        )
    }

    /// Analyze full series with peak capacity metadata (overnight streaming without organized recovery).
    func analyzeFullSeriesWithCapacity(
        series: RRSeries,
        flags: [ArtifactFlags],
        peakCapacity: PeakCapacity,
        trainingContext: TrainingContext?,
        ansConfig: ANSConfiguration? = nil
    ) -> HRVAnalysisResult? {
        let sessionId = series.sessionId
        debugLog("[HRVAnalysisPipeline] analyzeFullSeriesWithCapacity session=\(sessionId.uuidString.prefix(8))")
        let bounds = peakCapacityBounds(series: series, peakCapacity: peakCapacity)
        guard var result = analyzeFullSeries(
            series: series, flags: flags,
            windowStart: bounds.startIdx, windowEnd: bounds.endIdx,
            ansConfig: ansConfig
        ) else { return nil }
        result.peakCapacity = peakCapacity
        result.trainingContext = trainingContext
        attachPeakCapacityWindow(&result, bounds: bounds, peakCapacity: peakCapacity, sessionId: sessionId)
        return result
    }

    /// Where the peak-capacity window sits — beat indices for the analysis,
    /// wall-clock offsets for the chart.
    struct PeakWindowBounds {
        let startIdx: Int
        let endIdx: Int
        let startMs: Int64?
        let endMs: Int64?
    }

    /// The three metric families computed over one range, kept together so
    /// they travel as one argument rather than three.
    struct RangeMetrics {
        let timeDomain: TimeDomainMetrics
        let nonlinear: NonlinearMetrics
        let ans: ANSMetrics
    }

    /// Whole-night HR summary over artifact-clean beats.
    struct OvernightHRStats {
        let minHR: Double
        let maxHR: Double
        let meanHR: Double
        let nadirTimeMs: Int64
    }

    /// Where the peak-capacity window sits, as both beat indices and wall-clock
    /// offsets. Falls back to the whole series when the capacity carries no
    /// relative position.
    private func peakCapacityBounds(
        series: RRSeries,
        peakCapacity: PeakCapacity
    ) -> PeakWindowBounds {
        var windowStartIdx = 0
        var windowEndIdx = series.points.count
        var windowStartMs: Int64?
        var windowEndMs: Int64?

        if let relPos = peakCapacity.windowRelativePosition, !series.points.isEmpty,
           let firstPoint = series.points.first, let lastPoint = series.points.last {
            let totalDurationMs = lastPoint.endMs - firstPoint.t_ms
            let windowDurationMs = Int64(peakCapacity.windowDurationMinutes * 60000)
            let windowCenterMs = firstPoint.t_ms + Int64(Double(totalDurationMs) * relPos)

            let startMs = windowCenterMs - (windowDurationMs / 2)
            let endMs = windowCenterMs + (windowDurationMs / 2)
            windowStartMs = startMs
            windowEndMs = endMs

            (windowStartIdx, windowEndIdx) = indexRange(in: series.points, fromMs: startMs, toMs: endMs)
        }
        return PeakWindowBounds(startIdx: windowStartIdx, endIdx: windowEndIdx, startMs: windowStartMs, endMs: windowEndMs)
    }

    /// First beat at or after `fromMs`, and the first at or after `toMs`.
    private func indexRange(in points: [RRPoint], fromMs startMs: Int64, toMs endMs: Int64) -> (Int, Int) {
        var startIdx = 0
        var endIdx = points.count
        var foundStart = false
        for (idx, point) in points.enumerated() {
            if point.t_ms >= startMs, !foundStart {
                startIdx = idx
                foundStart = true
            }
            if point.t_ms >= endMs {
                endIdx = idx
                break
            }
        }
        return (startIdx, endIdx)
    }

    private func attachPeakCapacityWindow(
        _ result: inout HRVAnalysisResult,
        bounds: PeakWindowBounds,
        peakCapacity: PeakCapacity,
        sessionId: UUID
    ) {
        guard let wsMs = bounds.startMs, let weMs = bounds.endMs,
              let relPos = peakCapacity.windowRelativePosition else { return }
        result.windowStartMs = wsMs
        result.windowEndMs = weMs
        result.windowRelativePosition = relPos
        result.windowClassification = "Peak Capacity"
        debugLog("[HRVAnalysisPipeline] Peak capacity window session=\(sessionId.uuidString.prefix(8)) indices=[\(bounds.startIdx)..<\(bounds.endIdx)]")
    }

    /// Reanalyze at a specific position (manual window selection from graph interaction).
    func reanalyzeAtPosition(
        session: HRVSession,
        targetMs: Int64,
        trainingContext: TrainingContext?,
        ansConfig: ANSConfiguration
    ) async -> HRVAnalysisResult? {
        let sessionId = session.id
        debugLog("[HRVAnalysisPipeline] reanalyzeAtPosition session=\(sessionId.uuidString.prefix(8)) targetMs=\(targetMs)")
        guard let series = session.rrSeries else {
            logPipelineError(.noRRSeries(sessionId: sessionId))
            return nil
        }
        let flags = artifactDetector.detectArtifacts(in: series)
        guard let window = windowSelector.analyzeAtPosition(in: series, flags: flags, targetMs: targetMs) else {
            debugLog("[HRVAnalysisPipeline] reanalyzeAtPosition failed: no window at \(targetMs)ms session=\(sessionId.uuidString.prefix(8))")
            return nil
        }
        debugLog("[HRVAnalysisPipeline] Manual reanalysis session=\(sessionId.uuidString.prefix(8)) window=[\(window.startIndex)-\(window.endIndex)]")
        return await analyzeWithWindow(
            session: session,
            window: window,
            flags: flags,
            peakCapacity: nil,
            trainingContext: trainingContext,
            ansConfig: ansConfig
        )
    }

}
