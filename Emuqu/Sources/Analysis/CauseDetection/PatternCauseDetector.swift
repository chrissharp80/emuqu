import Foundation

/// Detects causes based on historical patterns (day-of-week, etc.)
/// Single Responsibility: only handles pattern-based cause detection
final class PatternCauseDetector: CauseDetectionStrategy {
    func detectCauses(in context: CauseDetectionContext) -> [DetectedCause] {
        // Skip for good readings
        if context.isGoodReading || context.isExcellentReading {
            return []
        }

        var causes: [DetectedCause] = []

        causes.append(contentsOf: detectDayOfWeekPattern(in: context))

        return causes
    }

    // MARK: - Day of Week Pattern

    private func detectDayOfWeekPattern(in context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []

        guard let dayImpact = calculateDayOfWeekImpact(in: context) else {
            return causes
        }

        let significantImpact = dayImpact.impact > 0.15

        if significantImpact, dayImpact.isLowDay, context.rmssd < HRVThresholds.rmssdGood {
            let percent = NarrativeLanguage.integer(Int(dayImpact.impact * 100))
            causes.append(DetectedCause(
                cause: WeekdayPatternCopy.title(weekday: dayImpact.weekday),
                confidence: .low,
                explanation: WeekdayPatternCopy.explanation(weekday: dayImpact.weekday, percent: percent),
                rankingWeight: 0.3
            ))
        }

        return causes
    }

    /// Overnight-only — day-of-week HRV patterns must compare resting nights,
    /// not workouts — and only nights whose HRV is trustworthy (no
    /// `.preSleep` / `.insufficient` awake partials).
    private func calculateDayOfWeekImpact(in context: CauseDetectionContext) -> DayOfWeekImpact? {
        let recentSessions = context.recentSessions.filter { $0.sessionType == .overnight && $0.isReliableForHRVAggregates }
        guard recentSessions.count >= 14 else { return nil }
        let calendar = Calendar.current
        let dayAverages = rmssdByWeekday(recentSessions, calendar: calendar)
        // At least three weekdays with two readings each, or the comparison is
        // against noise.
        let validDays = dayAverages.filter { $0.value.count >= 2 }
        guard validDays.count >= 3 else { return nil }
        let today = calendar.component(.weekday, from: context.session.startDate)
        guard let todayReadings = dayAverages[today], todayReadings.count >= 2 else { return nil }
        let allValues = validDays.values.flatMap { $0 }
        let overallAvg = allValues.reduce(0, +) / Double(allValues.count)
        let todayAvg = todayReadings.reduce(0, +) / Double(todayReadings.count)
        let impact = (overallAvg - todayAvg) / overallAvg
        return DayOfWeekImpact(weekday: today, impact: abs(impact), isLowDay: impact > 0)
    }

    /// Every recorded RMSSD grouped by the weekday it was recorded on.
    private func rmssdByWeekday(_ recentSessions: [HRVSession], calendar: Calendar) -> [Int: [Double]] {
        var dayAverages: [Int: [Double]] = [:]
        for session in recentSessions {
            guard let rmssd = session.rmssd else { continue }
            let day = calendar.component(.weekday, from: session.startDate)
            dayAverages[day, default: []].append(rmssd)
        }
        return dayAverages
    }
}

// MARK: - Supporting Types

private struct DayOfWeekImpact {
    /// `Calendar.component(.weekday)`: 1 is Sunday.
    let weekday: Int
    let impact: Double
    let isLowDay: Bool
}

/// The weekday-pattern cause, one sentence per weekday so each language can
/// inflect the day name.
private enum WeekdayPatternCopy {
    static func title(weekday: Int) -> String {
        switch weekday {
        case 1: String(localized: "Sunday Pattern", bundle: NarrativeLanguage.bundle)
        case 2: String(localized: "Monday Pattern", bundle: NarrativeLanguage.bundle)
        case 3: String(localized: "Tuesday Pattern", bundle: NarrativeLanguage.bundle)
        case 4: String(localized: "Wednesday Pattern", bundle: NarrativeLanguage.bundle)
        case 5: String(localized: "Thursday Pattern", bundle: NarrativeLanguage.bundle)
        case 6: String(localized: "Friday Pattern", bundle: NarrativeLanguage.bundle)
        default: String(localized: "Saturday Pattern", bundle: NarrativeLanguage.bundle)
        }
    }

    static func explanation(weekday: Int, percent: String) -> String {
        switch weekday {
        case 1: String(localized: "Historically, your HRV tends to be \(percent)% lower on Sundays. Consider what you usually do the day before.", bundle: NarrativeLanguage.bundle)
        case 2: String(localized: "Historically, your HRV tends to be \(percent)% lower on Mondays. Consider what you usually do the day before.", bundle: NarrativeLanguage.bundle)
        case 3: String(localized: "Historically, your HRV tends to be \(percent)% lower on Tuesdays. Consider what you usually do the day before.", bundle: NarrativeLanguage.bundle)
        case 4: String(localized: "Historically, your HRV tends to be \(percent)% lower on Wednesdays. Consider what you usually do the day before.", bundle: NarrativeLanguage.bundle)
        case 5: String(localized: "Historically, your HRV tends to be \(percent)% lower on Thursdays. Consider what you usually do the day before.", bundle: NarrativeLanguage.bundle)
        case 6: String(localized: "Historically, your HRV tends to be \(percent)% lower on Fridays. Consider what you usually do the day before.", bundle: NarrativeLanguage.bundle)
        default: String(localized: "Historically, your HRV tends to be \(percent)% lower on Saturdays. Consider what you usually do the day before.", bundle: NarrativeLanguage.bundle)
        }
    }
}
