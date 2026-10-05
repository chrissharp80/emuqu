import Foundation

/// A detected probable cause with confidence level and explanation. `cause`
/// and `explanation` are written in `NarrativeLanguage`.
struct DetectedCause {
    let cause: String
    let confidence: CauseConfidence
    let explanation: String
    /// ORDERING KEY ONLY. Not a probability, not a confidence, not a
    /// likelihood — it exists so `detectCauses` can sort candidate
    /// explanations and take the top few, and it is never shown to a user.
    ///
    /// Named `rankingWeight`, not `weight`: the illness rules carry values
    /// like 0.88 and 0.99, and numbers of that shape, on rules that have never
    /// been prospectively evaluated, read as calibrated probabilities to
    /// anyone who encounters them. The name does not calibrate them; it stops
    /// them from claiming to be calibrated. If a future version wants a real
    /// probability here it needs an outcome dataset first, and this field
    /// should be a different type when it does.
    let rankingWeight: Double

    /// How strongly the observed data matched this rule's pattern — shown to
    /// the user beside the explanation.
    ///
    /// The raw values are not "Critical", "Very High", "High",
    /// "Moderate" and so on. Beside a sentence about illness, that scale reads
    /// as confidence THAT THE CAUSE IS TRUE, which none of these rules can
    /// support: they are hand-authored thresholds with no outcome dataset
    /// behind them. The labels describe how completely the pattern
    /// matched, which is the only thing the rule actually knows.
    enum CauseConfidence: String {
        case critical = "Full pattern match"
        case veryHigh = "Strong pattern match"
        case high = "Clear pattern match"
        case moderateHigh = "Partial pattern match"
        case moderate = "Partial match"
        case lowModerate = "Weak match"
        case low = "Faint match"
        case pattern = "Pattern"
        case contributingFactor = "Contributing Factor"
        case goodSign = "Good Sign"
        case excellent = "Excellent"

        /// The label shown beside the explanation, in `NarrativeLanguage`.
        /// The raw value stays English: views key the badge colour on it.
        var label: String {
            switch self {
            case .critical: String(localized: "Full pattern match", bundle: NarrativeLanguage.bundle)
            case .veryHigh: String(localized: "Strong pattern match", bundle: NarrativeLanguage.bundle)
            case .high: String(localized: "Clear pattern match", bundle: NarrativeLanguage.bundle)
            case .moderateHigh: String(localized: "Partial pattern match", bundle: NarrativeLanguage.bundle)
            case .moderate: String(localized: "Partial match", bundle: NarrativeLanguage.bundle)
            case .lowModerate: String(localized: "Weak match", bundle: NarrativeLanguage.bundle)
            case .low: String(localized: "Faint match", bundle: NarrativeLanguage.bundle)
            case .pattern: String(localized: "Pattern", bundle: NarrativeLanguage.bundle)
            case .contributingFactor: String(localized: "Contributing Factor", bundle: NarrativeLanguage.bundle)
            case .goodSign: String(localized: "Good Sign", bundle: NarrativeLanguage.bundle)
            case .excellent: String(localized: "Excellent", bundle: NarrativeLanguage.bundle)
            }
        }
    }
}

/// Context containing all data needed for cause detection
struct CauseDetectionContext {
    let rmssd: Double
    let stressIndex: Double
    let lfHfRatio: Double
    let dfaAlpha1: Double
    let pnn50: Double
    let isGoodReading: Bool
    let isExcellentReading: Bool
    let selectedTags: Set<ReadingTag>
    let trendStats: AnalysisSummaryGenerator.TrendStats
    let sleepInput: AnalysisSleepInput
    let sleepTrend: AnalysisSleepTrendInput?
    let session: HRVSession
    let recentSessions: [HRVSession]

    /// Last night's mean heart rate. The elevated-HR causes compared two
    /// historical averages with each other, so whether they fired had
    /// nothing to do with the night being read.
    var currentHR: Double? {
        session.analysisResult?.timeDomain.meanHR
    }

    var isShortSleep: Bool {
        sleepInput.isShortSleep
    }

    var isGoodSleep: Bool {
        sleepInput.isGoodSleep
    }

    var isFragmented: Bool {
        sleepInput.isFragmented
    }
}

/// Protocol for cause detection strategies
/// Following Open/Closed Principle: open for extension, closed for modification
protocol CauseDetectionStrategy {
    /// Detect causes related to this strategy's domain
    func detectCauses(in context: CauseDetectionContext) -> [DetectedCause]
}

/// Aggregates all cause detection strategies and returns combined results
final class CauseDetector {
    private let strategies: [CauseDetectionStrategy]

    /// Initialize with default strategies
    init() {
        strategies = [
            PositiveCauseDetector(),
            SevereCauseDetector(),
            TagBasedCauseDetector(),
            SleepCauseDetector(),
            MetricBasedCauseDetector(),
            PatternCauseDetector()
        ]
    }

    /// Initialize with custom strategies (useful for testing)
    init(strategies: [CauseDetectionStrategy]) {
        self.strategies = strategies
    }

    /// Detect all probable causes and return top results.
    ///
    /// For good/excellent readings, only positive causes are returned (matching the
    /// early-return behavior of the original inline implementation).
    func detectCauses(in context: CauseDetectionContext, limit: Int = 3) -> [DetectedCause] {
        if context.isGoodReading || context.isExcellentReading {
            return detectPositiveCausesOnly(in: context, limit: limit)
        }

        var allCauses: [DetectedCause] = []

        for strategy in strategies {
            let causes = strategy.detectCauses(in: context)
            allCauses.append(contentsOf: causes)
        }

        // Sort by weight (highest first) and return top results
        return Array(allCauses.sorted { $0.rankingWeight > $1.rankingWeight }.prefix(limit))
    }

    /// For good/excellent readings, only collect positive causes from the
    /// PositiveCauseDetector and SleepCauseDetector (which returns positive
    /// sleep causes when reading is good).
    private func detectPositiveCausesOnly(in context: CauseDetectionContext, limit: Int) -> [DetectedCause] {
        var positiveCauses: [DetectedCause] = []

        for strategy in strategies {
            if strategy is PositiveCauseDetector || strategy is SleepCauseDetector {
                positiveCauses.append(contentsOf: strategy.detectCauses(in: context))
            }
        }

        return Array(positiveCauses.sorted { $0.rankingWeight > $1.rankingWeight }.prefix(limit))
    }
}

// MARK: - Helper Extensions

extension DetectedCause {
    /// Convert to the format expected by AnalysisSummaryGenerator
    func toProbableCause() -> AnalysisSummaryGenerator.ProbableCause {
        AnalysisSummaryGenerator.ProbableCause(
            cause: cause,
            confidence: confidence.rawValue,
            explanation: explanation
        )
    }
}
