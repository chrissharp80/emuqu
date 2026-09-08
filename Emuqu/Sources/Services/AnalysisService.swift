import Foundation

/// Centralized HRV analysis service
/// Coordinates artifact detection, window selection, and metric computation
final class AnalysisService {
    // MARK: - Dependencies

    private let artifactDetector: ArtifactDetector
    private let windowSelector: WindowSelector
    private let verification: Verification
    private let diagnosticScorer: DiagnosticScorer

    // MARK: - Initialization

    init(
        artifactDetector: ArtifactDetector = ArtifactDetector(),
        windowSelector: WindowSelector = WindowSelector(),
        verification: Verification = Verification(),
        diagnosticScorer: DiagnosticScorer = DiagnosticScorer()
    ) {
        self.artifactDetector = artifactDetector
        self.windowSelector = windowSelector
        self.verification = verification
        self.diagnosticScorer = diagnosticScorer
    }

    /// Create with relaxed config for streaming mode
    static func forStreaming() -> AnalysisService {
        AnalysisService(
            verification: Verification(config: Verification.Config(
                minPoints: HRVConstants.MinimumBeats.forStreaming,
                minDurationHours: 0.025,
                maxArtifactPercent: HRVConstants.Artifacts.maxPercentForAnalysis,
                warnArtifactPercent: HRVConstants.Artifacts.warnPercentThreshold
            ))
        )
    }

    // MARK: - Analysis operations

    func detectArtifacts(in series: RRSeries) -> [ArtifactFlags] {
        artifactDetector.detectArtifacts(in: series)
    }

    func findRecoveryWindow(
        in series: RRSeries,
        flags: [ArtifactFlags],
        sleepStartMs: Int64?,
        wakeTimeMs: Int64?
    ) -> WindowSelector.RecoveryWindow? {
        let result = windowSelector.findBestWindow(
            in: series,
            flags: flags,
            sleepStartMs: sleepStartMs,
            wakeTimeMs: wakeTimeMs
        )
        debugLog("[AnalysisService] findRecoveryWindow session=\(series.sessionId.uuidString.prefix(8)) found=\(result != nil)")
        return result
    }

    func findRecoveryWindowWithCapacity(
        in series: RRSeries,
        flags: [ArtifactFlags],
        sleepStartMs: Int64?,
        wakeTimeMs: Int64?
    ) -> WindowSelector.WindowSelectionResult? {
        let result = windowSelector.findBestWindowWithCapacity(
            in: series,
            flags: flags,
            sleepStartMs: sleepStartMs,
            wakeTimeMs: wakeTimeMs
        )
        debugLog("[AnalysisService] findRecoveryWindowWithCapacity session=\(series.sessionId.uuidString.prefix(8)) hasWindow=\(result?.recoveryWindow != nil) hasPeakCapacity=\(result?.peakCapacity != nil)")
        return result
    }

    func analyzeWindow(
        in series: RRSeries,
        flags: [ArtifactFlags],
        window: WindowSelector.RecoveryWindow
    ) -> HRVAnalysisResult? {
        debugLog("[AnalysisService] analyzeWindow session=\(series.sessionId.uuidString.prefix(8)) window=[\(window.startIndex)-\(window.endIndex)]")
        let result = analyzeFullSeries(
            series,
            flags: flags,
            windowStart: window.startIndex,
            windowEnd: window.endIndex
        )
        if result == nil {
            debugLog("[AnalysisService] analyzeWindow failed session=\(series.sessionId.uuidString.prefix(8))", level: .warning)
        }
        return result
    }

    func analyzeFullSeries(
        _ series: RRSeries,
        flags: [ArtifactFlags],
        windowStart: Int = 0,
        windowEnd: Int,
        trainingContext: TrainingContext? = nil
    ) -> HRVAnalysisResult? {
        let sessionId = series.sessionId
        let effectiveEnd = windowEnd > 0 ? windowEnd : series.points.count
        let window = "[\(windowStart)-\(effectiveEnd)]"
        guard let timeDomain = TimeDomainAnalyzer.computeTimeDomain(series, flags: flags, windowStart: windowStart, windowEnd: effectiveEnd) else {
            debugLog("[AnalysisService] Time domain analysis failed session=\(sessionId.uuidString.prefix(8)) window=\(window)", level: .warning); return nil
        }
        guard let nonlinearMetrics = NonlinearAnalyzer.computeNonlinear(series, flags: flags, windowStart: windowStart, windowEnd: effectiveEnd) else {
            debugLog("[AnalysisService] Nonlinear analysis failed session=\(sessionId.uuidString.prefix(8)) window=\(window)", level: .warning); return nil
        }
        let clean = Self.cleanBeats(in: series, flags: flags, windowStart: windowStart, windowEnd: effectiveEnd)
        var result = HRVAnalysisResult(
            windowStart: windowStart, windowEnd: effectiveEnd, timeDomain: timeDomain,
            frequencyDomain: FrequencyDomainAnalyzer.computeFrequencyDomain(series, flags: flags, windowStart: windowStart, windowEnd: effectiveEnd),
            nonlinear: nonlinearMetrics, ansMetrics: Self.ansMetrics(from: clean.rrs),
            artifactPercentage: clean.artifactPercent, cleanBeatCount: clean.count,
            analysisDate: Date()
        )
        result.trainingContext = trainingContext
        return result
    }

    /// Clean RR intervals for the ANS metrics, with bounds safety, plus the
    /// artifact percentage over the same window.
    private static func cleanBeats(
        in series: RRSeries, flags: [ArtifactFlags], windowStart: Int, windowEnd: Int
    ) -> (rrs: [Double], count: Int, artifactPercent: Double) {
        let safeEnd = min(windowEnd, flags.count, series.points.count)
        let safeStart = min(windowStart, safeEnd)
        var cleanRRs: [Double] = []
        for i in safeStart ..< safeEnd where !flags[i].isArtifact {
            cleanRRs.append(Double(series.points[i].rr_ms))
        }
        let windowSize = safeEnd - safeStart
        let cleanCount = flags[safeStart ..< safeEnd].filter { !$0.isArtifact }.count
        let artifactPercent = windowSize > 0
            ? Double(windowSize - cleanCount) / Double(windowSize) * 100
            : 0
        return (cleanRRs, cleanCount, artifactPercent)
    }

    /// Stress and respiration are the only ANS terms this pass computes; the
    /// rest are filled in later by the pipeline that knows about baselines.
    private static func ansMetrics(from cleanRRs: [Double]) -> ANSMetrics {
        ANSMetrics(
            stressIndex: StressAnalyzer.computeStressIndex(cleanRRs),
            pnsIndex: nil,
            snsIndex: nil,
            readinessScore: nil,
            respirationRate: RespirationAnalyzer.estimateRespirationRate(cleanRRs),
            nocturnalHRDip: nil,
            daytimeRestingHR: nil,
            nocturnalMedianHR: nil
        )
    }

    func verify(_ series: RRSeries, flags: [ArtifactFlags]) -> Verification.Result {
        let result = verification.verify(series, flags: flags)
        debugLog("[AnalysisService] verify session=\(series.sessionId.uuidString.prefix(8)) passed=\(result.passed) points=\(series.points.count)")
        return result
    }

    // MARK: - Full Analysis Pipeline

    private func passesVerification(_ series: RRSeries, flags: [ArtifactFlags], sessionId: UUID) -> Bool {
        let verified = verify(series, flags: flags)
        guard verified.passed else {
            debugLog("[AnalysisService] Verification failed session=\(sessionId.uuidString.prefix(8)) summary=\(verified.summary)", level: .warning)
            return false
        }
        return true
    }

    @MainActor func analyze(
        session: inout HRVSession,
        sleepStartMs: Int64? = nil,
        wakeTimeMs: Int64? = nil
    ) -> HRVAnalysisResult? {
        let sessionId = session.id
        let tag = sessionId.uuidString.prefix(8)
        debugLog("[AnalysisService] analyze start session=\(tag)")
        guard let series = session.rrSeries else {
            debugLog("[AnalysisService] No RR series for session=\(tag)", level: .warning); return nil
        }
        let flags = detectArtifacts(in: series)
        session.artifactFlags = flags
        guard passesVerification(series, flags: flags, sessionId: sessionId) else { return nil }
        let windowResult = findRecoveryWindowWithCapacity(in: series, flags: flags, sleepStartMs: sleepStartMs, wakeTimeMs: wakeTimeMs)
        guard let windowResult, let window = windowResult.recoveryWindow else {
            debugLog("[AnalysisService] No recovery window for session=\(tag)", level: .warning); return nil
        }
        guard var result = analyzeWindow(in: series, flags: flags, window: window) else {
            debugLog("[AnalysisService] Window analysis failed session=\(tag) window=[\(window.startIndex)-\(window.endIndex)]", level: .warning); return nil
        }
        Self.attachWindowMetadata(to: &result, window: window, windowResult: windowResult, series: series)
        Self.apply(result, to: &session, tag: tag)
        return result
    }

    /// Store the finished analysis on the session and log completion.
    @MainActor private static func apply(
        _ result: HRVAnalysisResult,
        to session: inout HRVSession,
        tag: Substring
    ) {
        session.analysisResult = result
        session.recoveryScore = result.ansMetrics?.readinessScore
        debugLog("[AnalysisService] analyze complete session=\(tag) rmssd=\(String(format: "%.1f", result.timeDomain.rmssd))")
    }

    /// Window metadata, bounds-safe against a series shorter than the window
    /// indices claim.
    private static func attachWindowMetadata(
        to result: inout HRVAnalysisResult,
        window: WindowSelector.RecoveryWindow,
        windowResult: WindowSelector.WindowSelectionResult,
        series: RRSeries
    ) {
        result.windowStartMs = window.startIndex < series.points.count
            ? series.points[window.startIndex].t_ms
            : 0
        result.windowEndMs = window.endIndex > 0 && window.endIndex - 1 < series.points.count
            ? series.points[window.endIndex - 1].endMs
            : (series.points.last?.endMs ?? 0)
        result.windowMeanHR = window.meanHR
        result.windowHRStability = window.hrStability
        result.windowSelectionReason = window.selectionReason
        result.windowRelativePosition = window.relativePosition
        result.windowClassification = window.windowClassification.rawValue
        result.isOrganizedRecovery = window.windowClassification == .organizedRecovery
        result.peakCapacity = windowResult.peakCapacity
    }

    // MARK: - Diagnostic Scoring

    func computeDiagnosticScore(from result: HRVAnalysisResult) -> DiagnosticResult {
        let metrics = DiagnosticMetrics(from: result)
        return diagnosticScorer.computeScore(from: metrics)
    }
}
