import Foundation

/// Calculate sleep trend statistics
struct SleepTrendStats {
    let averageSleepMinutes: Double
    let averageDeepSleepMinutes: Double?
    let averageEfficiency: Double?
    let trend: SleepTrend // improving, declining, stable
    let nightsAnalyzed: Int

    enum SleepTrend: String {
        case improving
        case declining
        case stable
        case insufficient = "insufficient data"
    }
}

// The trend is built from the sleep each archived overnight session stored
// with it (`sleepSnapshot`), not read from HealthKit: the HealthKit reader
// was never called, so every caller passed nothing and the summary's
// multi-night findings and the report's trend section never appeared. The
// archive already holds the nights the report is judged against, for a past
// night as for today's.
extension SleepTrendStats {
    /// The nights in the `days` before `session`, or nil when there are none.
    /// The session's own night is left out, so "tonight against your recent
    /// average" compares it with the nights before it rather than with an
    /// average it is part of.
    static func recentNights(before session: HRVSession, in sessions: [HRVSession], days: Int = 7) -> SleepTrendStats? {
        let nights = priorNights(before: session, in: sessions, days: days)
        return nights.isEmpty ? nil : SleepTrendStats(nights: nights)
    }

    /// `nights` newest first. Two or more nights get a direction; average
    /// efficiency covers only the nights whose wake was measured.
    init(nights: [SleepData]) {
        let deepValues = nights.compactMap(\.deepSleepMinutes)
        averageSleepMinutes = nights.map { Double($0.nightSleepMinutes) }.reduce(0, +) / Double(max(1, nights.count))
        averageDeepSleepMinutes = deepValues.isEmpty ? nil : Double(deepValues.reduce(0, +)) / Double(deepValues.count)
        averageEfficiency = HealthWriteAndObserve.averageMeasuredEfficiency(nights)
        trend = nights.count >= 2 ? Self.direction(nights) : .insufficient
        nightsAnalyzed = nights.count
    }

    /// One snapshot per night (the longest, when a split night's segments
    /// each carry one), newest first. Only overnight sessions with measured
    /// sleep count; the session's own night and its linked segments do not.
    static func priorNights(before session: HRVSession, in sessions: [HRVSession], days: Int) -> [SleepData] {
        let calendar = Calendar.current
        let windowStart = calendar.date(byAdding: .day, value: -days, to: session.startDate) ?? session.startDate
        let excluded = Set([session.id] + (session.linkedSessionIds ?? []))
        let ownNight = session.sleepSnapshot.map { calendar.startOfDay(for: $0.date) }
        let snapshots = sessions
            .filter { $0.sessionType == .overnight && !excluded.contains($0.id) }
            .filter { $0.startDate < session.startDate && $0.startDate >= windowStart }
            .compactMap(\.sleepSnapshot)
            .filter { $0.nightSleepMinutes > 0 && calendar.startOfDay(for: $0.date) != ownNight }
        let byNight = Dictionary(grouping: snapshots) { calendar.startOfDay(for: $0.date) }
        return byNight.values
            .compactMap { night in night.max { $0.nightSleepMinutes < $1.nightSleepMinutes } }
            .sorted { $0.date > $1.date }
    }

    /// The newer half of the nights against the older half (`nights` is
    /// newest first). ±10 % reads as "stable".
    private static func direction(_ nights: [SleepData]) -> SleepTrend {
        let midpoint = nights.count / 2
        let newerAverage = averageMinutes(nights.prefix(midpoint))
        let olderAverage = averageMinutes(nights.suffix(from: midpoint))
        let changePercent = olderAverage > 0 ? (newerAverage - olderAverage) / olderAverage * 100 : 0
        if changePercent > 10 { return .improving }
        if changePercent < -10 { return .declining }
        return .stable
    }

    private static func averageMinutes(_ nights: ArraySlice<SleepData>) -> Double {
        nights.map { Double($0.nightSleepMinutes) }.reduce(0, +) / Double(max(1, nights.count))
    }
}
