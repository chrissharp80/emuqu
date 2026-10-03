import Foundation

/// Detects the largest deviations from the user's own baseline.
/// Single Responsibility: only handles the biggest HRV / resting-HR shifts.
final class SevereCauseDetector: CauseDetectionStrategy {
    func detectCauses(in context: CauseDetectionContext) -> [DetectedCause] {
        // Skip severe detection for good readings
        if context.isGoodReading || context.isExcellentReading {
            return []
        }

        var causes: [DetectedCause] = []

        causes.append(contentsOf: detectHRVCrash(in: context))
        causes.append(contentsOf: detectElevatedHRWithLowHRV(in: context))

        return causes
    }

    // MARK: - Private Detection Methods

    private func detectHRVCrash(in context: CauseDetectionContext) -> [DetectedCause] {
        let stats = context.trendStats
        guard stats.hasData, stats.sessionCount >= 3 else { return [] }
        let deviationPercent = ((context.rmssd - stats.avgRMSSD) / stats.avgRMSSD) * 100
        // Sharp HRV drop (>50% below average).
        if deviationPercent < HRVThresholds.illnessSevereHRVCrash {
            return [DetectedCause(
                cause: "Sharp HRV Drop",
                confidence: .critical,
                explanation: "Your HRV (\(Int(context.rmssd))ms) is \(String(format: "%.0f", abs(deviationPercent)))% below your average (\(String(format: "%.0f", stats.avgRMSSD))ms). Drops this large most often follow hard training, short or poor sleep, alcohol, stress or travel, and sometimes the start of an illness; this reading cannot tell you which. Keep today easy. If you feel unwell, rest, and talk to a clinician about symptoms that concern you.",
                rankingWeight: 0.99
            )]
        }
        // Major HRV drop (>30% below average).
        guard deviationPercent < HRVThresholds.illnessMajorHRVDrop else { return [] }
        return [DetectedCause(
                cause: "Major HRV Drop",
                confidence: .veryHigh,
                explanation: "Your HRV is \(String(format: "%.0f", abs(deviationPercent)))% below your baseline (\(Int(context.rmssd))ms vs \(String(format: "%.0f", stats.avgRMSSD))ms average). This significant deviation suggests your body is under substantial stress. Take it very easy today.",
                rankingWeight: 0.92
        )]
    }

    private func detectElevatedHRWithLowHRV(in context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []
        let stats = context.trendStats

        guard stats.hasData, stats.avgHR > 0, let currentHR = context.currentHR else {
            return causes
        }

        let hrElevation = currentHR - stats.avgHR
        let hrvSuppressed = context.rmssd < stats.avgRMSSD * 0.8

        if hrElevation > HRVThresholds.hrSignificantElevation, hrvSuppressed {
            causes.append(DetectedCause(
                cause: "Elevated HR + Low HRV",
                confidence: .high,
                explanation: "Your resting HR is \(String(format: "%.0f", hrElevation)) bpm above baseline while HRV is suppressed. Both commonly move together after hard training, short sleep, alcohol, stress or travel, and sometimes at the start of an illness; this reading cannot tell you which.",
                rankingWeight: 0.70
            ))
        }

        return causes
    }
}
