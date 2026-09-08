import Foundation

/// Protocol for computing diagnostic scores from HRV analysis results
/// Following Single Responsibility Principle: scoring logic is separate from reporting
protocol DiagnosticScoring {
    func computeScore(from metrics: DiagnosticMetrics) -> DiagnosticResult
}

/// Input metrics required for diagnostic scoring
struct DiagnosticMetrics {
    let rmssd: Double
    let stressIndex: Double?
    let lfHfRatio: Double?
    let dfaAlpha1: Double?
    let isConsolidated: Bool

    init(from result: HRVAnalysisResult) {
        rmssd = result.timeDomain.rmssd
        stressIndex = result.ansMetrics?.stressIndex
        lfHfRatio = result.frequencyDomain?.lfHfRatio
        dfaAlpha1 = result.nonlinear.dfaAlpha1
        isConsolidated = result.isConsolidated ?? false
    }

    init(
        rmssd: Double,
        stressIndex: Double? = nil,
        lfHfRatio: Double? = nil,
        dfaAlpha1: Double? = nil,
        isConsolidated: Bool = false
    ) {
        self.rmssd = rmssd
        self.stressIndex = stressIndex
        self.lfHfRatio = lfHfRatio
        self.dfaAlpha1 = dfaAlpha1
        self.isConsolidated = isConsolidated
    }
}

/// Output of diagnostic scoring
struct DiagnosticResult {
    let score: Double
    let title: String
    let icon: String
    let status: RecoveryStatus

    enum RecoveryStatus: String {
        case wellRecovered = "Well Recovered"
        case adequateRecovery = "Adequate Recovery"
        case incompleteRecovery = "Incomplete Recovery"
        case significantStress = "Significant Stress Load"
        case recoveryNeeded = "Recovery Needed"
    }
}

/// Default implementation of diagnostic scoring
/// Uses evidence-based thresholds for HRV interpretation
final class DiagnosticScorer: DiagnosticScoring {
    private let config: DiagnosticScoringConfig

    init(config: DiagnosticScoringConfig = .default) {
        self.config = config
    }

    func computeScore(from metrics: DiagnosticMetrics) -> DiagnosticResult {
        let score = calculateScore(from: metrics)
        let status = determineStatus(from: score)
        let title = status.rawValue
        let icon = determineIcon(for: status)

        return DiagnosticResult(
            score: score,
            title: title,
            icon: icon,
            status: status
        )
    }

    // MARK: - Private Methods

    private func calculateScore(from metrics: DiagnosticMetrics) -> Double {
        var score = config.baseScore

        score += rmssdContribution(metrics.rmssd)
        score += stressContribution(metrics.stressIndex)
        score += lfHfContribution(metrics.lfHfRatio)
        score += dfaContribution(metrics.dfaAlpha1)

        return clampScore(score)
    }

    // RMSSD diagnostic ranges (distinct from HRVThresholds interpretation scale)
    private static let rmssdExcellentThreshold = 60.0
    private static let rmssdGoodThreshold = 45.0
    private static let rmssdModerateThreshold = 30.0
    private static let rmssdReducedThreshold = 20.0

    private func rmssdContribution(_ rmssd: Double) -> Double {
        switch rmssd {
        case Self.rmssdExcellentThreshold...:
            config.rmssdScores.excellent
        case Self.rmssdGoodThreshold ..< Self.rmssdExcellentThreshold:
            config.rmssdScores.good
        case Self.rmssdModerateThreshold ..< Self.rmssdGoodThreshold:
            config.rmssdScores.moderate
        case Self.rmssdReducedThreshold ..< Self.rmssdModerateThreshold:
            config.rmssdScores.reduced
        default:
            config.rmssdScores.low
        }
    }

    private func stressContribution(_ stress: Double?) -> Double {
        guard let stress else { return 0 }

        switch stress {
        case ..<HRVThresholds.stressIndexLow:
            return config.stressScores.veryLow
        case HRVThresholds.stressIndexLow ..< HRVThresholds.stressIndexNormal:
            return config.stressScores.low
        case HRVThresholds.stressIndexNormal ..< HRVThresholds.stressIndexElevated:
            return config.stressScores.moderate
        case HRVThresholds.stressIndexElevated ..< HRVThresholds.stressIndexHigh:
            return config.stressScores.elevated
        default:
            return config.stressScores.high
        }
    }

    private func lfHfContribution(_ ratio: Double?) -> Double {
        guard let ratio else { return 0 }

        switch ratio {
        case HRVThresholds.lfHfParasympatheticDominance ... HRVThresholds.lfHfOptimalUpper:
            return config.lfHfScores.optimal
        case ..<HRVThresholds.lfHfParasympatheticDominance:
            return config.lfHfScores.parasympathetic
        case HRVThresholds.lfHfOptimalUpper ... HRVThresholds.lfHfModerateSympatheticUpper:
            return config.lfHfScores.mildSympathetic
        default:
            return config.lfHfScores.highSympathetic
        }
    }

    private func dfaContribution(_ alpha1: Double?) -> Double {
        guard let alpha1 else { return 0 }

        switch alpha1 {
        case HRVThresholds.dfaAlpha1OptimalLower ... HRVThresholds.dfaAlpha1OptimalUpper:
            return config.dfaScores.optimal
        case HRVThresholds.dfaAlpha1OptimalUpper ... 1.15:
            return config.dfaScores.acceptable
        default:
            return config.dfaScores.elevated
        }
    }

    private func clampScore(_ score: Double) -> Double {
        min(100, max(0, score))
    }

    private func determineStatus(from score: Double) -> DiagnosticResult.RecoveryStatus {
        switch score {
        case HRVThresholds.scoreWellRecovered...:
            .wellRecovered
        case HRVThresholds.scoreAdequateRecovery ..< HRVThresholds.scoreWellRecovered:
            .adequateRecovery
        case HRVThresholds.scoreIncompleteRecovery ..< HRVThresholds.scoreAdequateRecovery:
            .incompleteRecovery
        case HRVThresholds.scoreSignificantStress ..< HRVThresholds.scoreIncompleteRecovery:
            .significantStress
        default:
            .recoveryNeeded
        }
    }

    private func determineIcon(for status: DiagnosticResult.RecoveryStatus) -> String {
        switch status {
        case .wellRecovered:
            "checkmark.circle.fill"
        case .adequateRecovery:
            "hand.thumbsup.fill"
        case .incompleteRecovery, .significantStress:
            "exclamationmark.triangle.fill"
        case .recoveryNeeded:
            "bed.double.fill"
        }
    }
}
