import Foundation

/// Shared analysis summary generator used by both MorningResultsView and PDFReportGenerator
/// This ensures the PDF contains 100% of the same analysis content as the app
final class AnalysisSummaryGenerator {
    // MARK: - Output Models

    struct AnalysisSummary {
        let analysisTitle: String
        let diagnosticIcon: String
        let diagnosticScore: Double
        let analysisExplanation: String
        let probableCauses: [ProbableCause]
        let keyFindings: [String]
        let actionableSteps: [String]
        let trendInsight: String
    }

    struct ProbableCause {
        let cause: String
        let confidence: String
        let explanation: String
    }

    struct TrendStats {
        let hasData: Bool
        let avgRMSSD: Double
        let baselineRMSSD: Double?
        let avgHR: Double
        let baselineHR: Double?
        let avgStress: Double?
        let baselineStress: Double?
        let avgReadiness: Double?
        let sessionCount: Int
        let daySpan: Int
        let trend7Day: Double?
        let trend30Day: Double?

        static let empty = TrendStats(
            hasData: false, avgRMSSD: 0, baselineRMSSD: nil, avgHR: 0,
            baselineHR: nil, avgStress: nil, baselineStress: nil,
            avgReadiness: nil, sessionCount: 0, daySpan: 0,
            trend7Day: nil, trend30Day: nil
        )
    }

    // MARK: - Input

    let result: HRVAnalysisResult
    let session: HRVSession
    let recentSessions: [HRVSession]
    let selectedTags: Set<ReadingTag>
    let sleep: AnalysisSleepInput
    let sleepTrend: AnalysisSleepTrendInput?
    let trainingContext: TrainingContext?
    let userAge: Int?
    let biologicalSex: UserSettings.BiologicalSex?
    /// Live training readiness (0-100). When provided and significantly below
    /// the morning recovery score, actionable steps are replaced with
    /// post-exercise recovery tips instead of the morning's "push" advice.
    let currentReadiness: Double?
    /// Today's accumulated TRIMP from workouts. Used to gate post-exercise
    /// tips — without meaningful exercise today, the readiness-vs-recovery
    /// gap is from accumulated training load, not a same-day session.
    let todayTrimp: Double
    /// Live training-load snapshot captured by the caller on MainActor.
    /// Exists so generate() need not read `TrainingLoadRegistry.live()`
    /// under `MainActor.assumeIsolated`. The generator can
    /// run from off-main paths (AssistantContextSource async pipeline,
    /// PDF render Task.detached), where assumeIsolated would trap.
    /// Caller resolves on MainActor before instantiating.
    let liveLoadSnapshot: TrainingLoadRegistry.TrainingLoad?
    /// "Now" for trend-window math (7-day split in computeTrendStats).
    /// Injected so trend stats are deterministic; defaults to the wall
    /// clock at init, which matches the previous inline Date() reads.
    private let referenceDate: Date

    /// Canonical HRV baseline the RECOVERY SCORE is computed against — the
    /// geometric mean exp(BaselineTracker.recoveryBaselineStats.lnRmssdMean).
    /// When non-nil it anchors the trend narrative so "What This Means" agrees
    /// with the score instead of an unbounded arithmetic mean (Jensen made the
    /// arithmetic mean higher → false "below baseline"). nil keeps every
    /// existing caller source-compatible; the PDF path (no BaselineTracker)
    /// falls back to an in-generator GEOMETRIC mean, still ln-consistent.
    private let canonicalBaselineRMSSD: Double?
    /// Canonical resting-HR baseline (BaselineTracker.meanHRBaseline) the
    /// score's RHR adjustment uses — reconciles the narrative RHR delta with
    /// the Vitals card (#9). nil → fall back to arithmetic avgHR.
    private let canonicalBaselineHR: Double?

    /// Computed once
    lazy var stats: TrendStats = computeTrendStats(referenceDate: referenceDate)

    // MARK: - Init

    init(
        result: HRVAnalysisResult,
        session: HRVSession,
        recentSessions: [HRVSession] = [],
        selectedTags: Set<ReadingTag> = [],
        sleep: AnalysisSleepInput = .empty,
        sleepTrend: AnalysisSleepTrendInput? = nil,
        trainingContext: TrainingContext? = nil,
        userAge: Int? = nil,
        biologicalSex: UserSettings.BiologicalSex? = nil,
        currentReadiness: Double? = nil,
        todayTrimp: Double = 0,
        liveLoadSnapshot: TrainingLoadRegistry.TrainingLoad? = nil,
        canonicalBaselineRMSSD: Double? = nil,
        canonicalBaselineHR: Double? = nil,
        referenceDate: Date = Date()
    ) {
        self.result = result
        self.session = session
        self.recentSessions = recentSessions
        self.selectedTags = selectedTags
        self.sleep = sleep
        self.sleepTrend = sleepTrend
        self.trainingContext = trainingContext
        self.userAge = userAge
        self.biologicalSex = biologicalSex
        self.currentReadiness = currentReadiness
        self.todayTrimp = todayTrimp
        self.liveLoadSnapshot = liveLoadSnapshot
        self.canonicalBaselineRMSSD = canonicalBaselineRMSSD
        self.canonicalBaselineHR = canonicalBaselineHR
        self.referenceDate = referenceDate
    }

    // MARK: - Public API

    func generate() -> AnalysisSummary {
        AnalysisSummary(
            analysisTitle: analysisTitle,
            diagnosticIcon: diagnosticIcon,
            diagnosticScore: computeDiagnosticScore(),
            analysisExplanation: analysisExplanation,
            probableCauses: probableCauses,
            keyFindings: keyFindings,
            actionableSteps: actionableSteps,
            trendInsight: trendInsight
        )
    }

    // MARK: - Trend Stats Computation

    private func computeTrendStats(referenceDate: Date = Date()) -> TrendStats {
        // Overnight-only. This generator feeds the morning summary,
        // the PDF, AND the AI assistant's context — averaging in workouts/quick
        // readings gave impossible "averages" (resting-HR 83, stress 714) and a
        // "+38% vs average" that contradicted the geometric-baseline "+2%".
        // Excludes untrustworthy-HRV sessions (`.insufficient` /
        // `.preSleep`) so this "vs average" block isn't skewed by awake partials.
        let validSessions = recentSessions.filter {
            $0.sessionType == .overnight && $0.state == .complete
                && $0.analysisResult != nil && $0.isReliableForHRVAggregates
        }
        guard validSessions.count >= 2 else { return TrendStats.empty }
        return trendStats(for: validSessions, referenceDate: referenceDate)
    }

    private func trendStats(for validSessions: [HRVSession], referenceDate: Date) -> TrendStats {
        let averages = sessionAverages(validSessions)
        let baselines = sessionBaselines(validSessions)
        let dates = validSessions.map(\.startDate)
        return TrendStats(
            hasData: true,
            avgRMSSD: averages.rmssd, baselineRMSSD: baselines.rmssd,
            avgHR: averages.hr, baselineHR: baselines.hr,
            avgStress: averages.stress, baselineStress: baselines.stress,
            avgReadiness: averages.readiness,
            sessionCount: validSessions.count,
            daySpan: Calendar.current.dateComponents(
                [.day], from: dates.min() ?? referenceDate, to: dates.max() ?? referenceDate
            ).day ?? 0,
            trend7Day: sevenDayTrend(validSessions, referenceDate: referenceDate),
            trend30Day: nil
        )
    }

    /// #2 — anchors the trend narrative to the CANONICAL baseline the score uses
    /// (geometric ln(RMSSD) mean) so "What This Means" agrees with the score.
    /// When it isn't threaded in (the PDF path), this falls back to a GEOMETRIC
    /// mean of the recent sessions — still ln-consistent, avoiding the Jensen gap
    /// that makes an arithmetic mean read high.
    ///
    /// #9 — prefers the canonical meanHRBaseline so the narrative RHR delta
    /// matches the Vitals card.
    /// The four period averages the summary quotes. `stress` and `readiness`
    /// are optional because a period can contain sessions that produced
    /// neither.
    struct SessionAverages {
        let rmssd: Double
        let hr: Double
        let stress: Double?
        let readiness: Double?
    }

    private func sessionAverages(
        _ validSessions: [HRVSession]
    ) -> SessionAverages {
        let rmssdValues = validSessions.compactMap { $0.analysisResult?.timeDomain.rmssd }
        let hrValues = validSessions.compactMap { $0.analysisResult?.timeDomain.meanHR }
        let stressValues = validSessions.compactMap { $0.analysisResult?.ansMetrics?.stressIndex }
        let readinessValues = validSessions.compactMap { $0.analysisResult?.ansMetrics?.readinessScore }
        return SessionAverages(
            rmssd: canonicalBaselineRMSSD ?? Self.geometricMean(rmssdValues),
            hr: canonicalBaselineHR ?? (hrValues.isEmpty ? 0 : hrValues.reduce(0, +) / Double(hrValues.count)),
            stress: stressValues.isEmpty ? nil : stressValues.reduce(0, +) / Double(stressValues.count),
            readiness: readinessValues.isEmpty ? nil : readinessValues.reduce(0, +) / Double(readinessValues.count)
        )
    }

    /// Falls back to the arithmetic mean when nothing is positive to take a log
    /// of.
    private static func geometricMean(_ values: [Double]) -> Double {
        let arithmetic = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        let lnValues = values.filter { $0 > 0 }.map { log($0) }
        guard !lnValues.isEmpty else { return arithmetic }
        return exp(lnValues.reduce(0, +) / Double(lnValues.count))
    }

    /// Recent week against the week before it, as a percentage.
    private func sevenDayTrend(_ validSessions: [HRVSession], referenceDate: Date) -> Double? {
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: referenceDate) ?? referenceDate
        let recentWeek = validSessions.filter { $0.startDate >= sevenDaysAgo }
        let olderWeek = validSessions.filter { $0.startDate < sevenDaysAgo }
        var trend7Day: Double?
        if recentWeek.count >= 2, olderWeek.count >= 2 {
            let recentAvg = recentWeek.compactMap { $0.analysisResult?.timeDomain.rmssd }.reduce(0, +) / Double(recentWeek.count)
            let olderAvg = olderWeek.compactMap { $0.analysisResult?.timeDomain.rmssd }.reduce(0, +) / Double(olderWeek.count)
            if olderAvg > 0 {
                trend7Day = ((recentAvg - olderAvg) / olderAvg) * 100
            }
        }
        return trend7Day
    }
}

// MARK: - File-scope helpers
//
// Moved out of AnalysisSummaryGenerator. Each names no member of the
// type and calls nothing that stayed behind, so none needed to be inside
// it. `private` at file scope is fileprivate, so every call site in this
// file resolves exactly as before.

/// Baselines prefer tagged "Morning" readings, falling back to every valid
/// session when the user doesn't tag.
private func sessionBaselines(
    _ validSessions: [HRVSession]
) -> (rmssd: Double?, hr: Double?, stress: Double?) {
    let morningReadings = validSessions.filter { $0.tags.contains { $0.name == "Morning" } }
    let baselineSessions = morningReadings.isEmpty ? validSessions : morningReadings
    let baselineRMSSD = baselineSessions.count >= 3 ? baselineSessions.suffix(5).compactMap { $0.analysisResult?.timeDomain.rmssd }.reduce(0, +) / Double(min(5, baselineSessions.count)) : nil
    let baselineHR = baselineSessions.count >= 3 ? baselineSessions.suffix(5).compactMap { $0.analysisResult?.timeDomain.meanHR }.reduce(0, +) / Double(min(5, baselineSessions.count)) : nil
    let baselineStress = baselineSessions.count >= 3 ? baselineSessions.suffix(5).compactMap { $0.analysisResult?.ansMetrics?.stressIndex }.reduce(0, +) / Double(min(5, baselineSessions.count)) : nil
    return (baselineRMSSD, baselineHR, baselineStress)
}
