import SwiftUI

/// Trend comparison section showing how current HRV metrics compare against
/// recent session averages and personal baselines.
struct TrendComparisonCard: View {
    let result: HRVAnalysisResult
    let recentSessions: [HRVSession]
    /// The SAME baseline the recovery score + hero use (geometric ln(RMSSD)
    /// mean + resting-HR baseline). Passed in so this card's HRV/HR figures
    /// can't disagree with the "+2% vs your average" the rest of the screen
    /// shows. nil only before the baseline has formed (cold start).
    var baselineStats: BaselineTracker.RecoveryBaselineStats?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            trendHeader

            // Comparison stats
            comparisonStatsSection
        }
        .zenCard()
    }

    private var trendHeader: some View {
        HStack {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .foregroundColor(AppTheme.primary)
            Text(String(localized: "Trend Analysis", bundle: LanguageManager.appBundle))
                .font(.headline)
                .foregroundColor(AppTheme.textPrimary)
        }
    }

    @ViewBuilder
    private var comparisonStatsSection: some View {
        let stats = trendStats
        if stats.hasData {
            trendRows(stats)

            Divider()

            // Trend Insight
            trendInsightCard(stats)
        } else {
            Text(String(localized: "More sessions needed for trend analysis", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .foregroundColor(AppTheme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding()
        }
    }

    @ViewBuilder
    private func trendRows(_ stats: TrendStats) -> some View {
        VStack(spacing: 12) {
            hrvTrendRow(stats)
            heartRateTrendRow(stats)
            stressTrendRow(stats)
            readinessTrendRow(stats)
        }
    }

    private func hrvTrendRow(_ stats: TrendStats) -> some View {
        // RMSSD trend
        TrendComparisonRow(
            metric: String(localized: "HRV (RMSSD)", bundle: LanguageManager.appBundle),
            current: result.timeDomain.rmssd,
            average: stats.avgRMSSD,
            baseline: stats.baselineRMSSD,
            unit: String(localized: "ms", bundle: LanguageManager.appBundle),
            higherIsBetter: true
        )
    }

    private func heartRateTrendRow(_ stats: TrendStats) -> some View {
        // Heart Rate trend
        TrendComparisonRow(
            metric: String(localized: "Resting HR", bundle: LanguageManager.appBundle),
            current: result.timeDomain.meanHR,
            average: stats.avgHR,
            baseline: stats.baselineHR,
            unit: String(localized: "bpm", bundle: LanguageManager.appBundle),
            higherIsBetter: false
        )
    }

    @ViewBuilder
    private func stressTrendRow(_ stats: TrendStats) -> some View {
        // Stress Index trend
        if let currentStress = result.ansMetrics?.stressIndex, let avgStress = stats.avgStress {
            TrendComparisonRow(
                metric: String(localized: "Stress Index", bundle: LanguageManager.appBundle),
                current: currentStress,
                average: avgStress,
                baseline: stats.baselineStress,
                unit: "",
                higherIsBetter: false
            )
        }
    }

    @ViewBuilder
    private func readinessTrendRow(_ stats: TrendStats) -> some View {
        // Readiness trend
        if let currentReadiness = result.ansMetrics?.readinessScore, let avgReadiness = stats.avgReadiness {
            TrendComparisonRow(
                metric: String(localized: "Readiness", bundle: LanguageManager.appBundle),
                current: currentReadiness,
                average: avgReadiness,
                baseline: nil,
                unit: "/10",
                higherIsBetter: true
            )
        }
    }

    private func trendInsightCard(_ stats: TrendStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "brain")
                    .foregroundColor(AppTheme.primary)
                Text(String(localized: "Trend Insight", bundle: LanguageManager.appBundle))
                    .font(.subheadline.bold())
                    .foregroundColor(AppTheme.textPrimary)
            }

            Text(trendInsight(for: stats))
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .background(AppTheme.primary.opacity(0.08))
        .cornerRadius(AppTheme.smallCornerRadius)
    }

    // MARK: - Trend Computation

    private struct TrendStats {
        let hasData: Bool
        let avgRMSSD: Double
        let baselineRMSSD: Double?
        let avgHR: Double
        let baselineHR: Double?
        let avgStress: Double?
        let baselineStress: Double?
        let avgReadiness: Double?
        let sessionCount: Int
        /// The last 7 days against the earlier readings, in percent, present
        /// only when the shared trend verdict calls a trend.
        let trend7Day: Double?
    }

    private var trendStats: TrendStats {
        // MUST be overnight-only. `recentSessions` is mixed-type; averaging in
        // workouts / daytime quick readings produced impossible "averages"
        // (resting-HR avg 83, stress avg 714) and an HRV "+38% vs avg" that
        // flatly contradicted the hero's "+2% vs your average" (geometric
        // baseline).
        // Also exclude untrustworthy-HRV sessions (see
        // HRVSession.isReliableForHRVAggregates).
        let validSessions = recentSessions.filter {
            $0.sessionType == .overnight && $0.state == .complete && $0.analysisResult != nil && $0.isReliableForHRVAggregates
        }
        guard validSessions.count >= 2 else {
            return TrendStats(hasData: false, avgRMSSD: 0, baselineRMSSD: nil, avgHR: 0, baselineHR: nil, avgStress: nil, baselineStress: nil, avgReadiness: nil, sessionCount: 0, trend7Day: nil)
        }
        return populatedStats(validSessions)
    }

    private func populatedStats(_ validSessions: [HRVSession]) -> TrendStats {
        let averages = trendAverages(validSessions)
        return TrendStats(
            hasData: true,
            avgRMSSD: averages.avgRMSSD,
            baselineRMSSD: averages.baselineRMSSD,
            avgHR: averages.avgHR,
            baselineHR: averages.baselineHR,
            avgStress: averages.avgStress,
            baselineStress: averages.baselineStress,
            avgReadiness: averages.avgReadiness,
            sessionCount: validSessions.count,
            trend7Day: averages.trend7Day
        )
    }

    // HRV and HR reference the SAME baseline the recovery score + hero use
    // (geometric ln(RMSSD) mean; resting-HR baseline), so this card's
    // figures are IDENTICAL to the "+2% vs your average" shown above —
    // no second/third number for the same metric. Fall back to the
    // overnight arithmetic mean only before the tracker baseline exists.

    // "Baseline" = the same geometric/HR baseline, so the rows' "vs average"
    // and "vs baseline" resolve to ONE number, and the insight states it once.
    // Stress has no tracker baseline → omit rather than invent one.
    private func trendAverages(_ validSessions: [HRVSession]) -> TrendAverages {
        let rmssdValues = validSessions.compactMap(\.rmssd)
        let hrValues = validSessions.compactMap(\.meanHR)
        let stressValues = validSessions.compactMap(\.stressIndex)
        let readinessValues = validSessions.compactMap(\.readinessScore)
        let geomBaseline = baselineStats.map { exp($0.lnRmssdMean) }
        return TrendAverages(
            avgRMSSD: geomBaseline ?? (rmssdValues.isEmpty ? 0 : rmssdValues.reduce(0, +) / Double(rmssdValues.count)),
            avgHR: baselineStats?.meanHRBaseline ?? (hrValues.isEmpty ? 0 : hrValues.reduce(0, +) / Double(hrValues.count)),
            avgStress: stressValues.isEmpty ? nil : stressValues.reduce(0, +) / Double(stressValues.count),
            avgReadiness: readinessValues.isEmpty ? nil : readinessValues.reduce(0, +) / Double(readinessValues.count),
            baselineRMSSD: geomBaseline,
            baselineHR: baselineStats?.meanHRBaseline,
            baselineStress: nil,
            trend7Day: TrendVerdict.weeklyRMSSDChange(validSessions)
        )
    }

    /// Trailing-window averages and the baselines the hero card uses.
    private struct TrendAverages {
        let avgRMSSD: Double
        let avgHR: Double
        let avgStress: Double?
        let avgReadiness: Double?
        let baselineRMSSD: Double?
        let baselineHR: Double?
        let baselineStress: Double?
        let trend7Day: Double?
    }

    private func trendInsight(for stats: TrendStats) -> String {
        guard stats.hasData else { return String(localized: "Record more sessions to see trends.", bundle: LanguageManager.appBundle) }
        return [
            rmssdInsight(stats),
            heartRateInsight(stats),
            stressInsight(stats),
            weeklyTrendInsight(stats),
            sessionCountInsight(stats)
        ].compactMap { $0 }.joined(separator: " ")
    }

    /// Today's RMSSD against the recent average (the personal baseline once it
    /// exists). Within ±10 % reads as "consistent"; the bands beyond that get
    /// progressively stronger wording. Exactly ±10 % falls through every band
    /// and says nothing. A large rise is not called "excellent recovery": a
    /// one-off jump well above baseline can also follow heavy training
    /// (parasympathetic saturation, Plews 2012), so it is flagged for context.
    private func rmssdInsight(_ stats: TrendStats) -> String? {
        let avg = String(format: "%.0f", locale: LanguageManager.appLocale, stats.avgRMSSD)
        let rmssdPct = ((result.timeDomain.rmssd - stats.avgRMSSD) / stats.avgRMSSD) * 100
        let pct = String(format: "%.0f", locale: LanguageManager.appLocale, rmssdPct)
        if abs(rmssdPct) < 10 {
            return String(localized: "Your HRV is consistent with your recent average (\(avg)ms).", bundle: LanguageManager.appBundle)
        }
        if rmssdPct > 10 { return rmssdAboveAverage(pct: pct, avg: avg, strong: rmssdPct > 20) }
        if rmssdPct < -10 { return rmssdBelowAverage(pct: pct, avg: avg, strong: rmssdPct < -20) }
        return nil
    }

    private func rmssdAboveAverage(pct: String, avg: String, strong: Bool) -> String {
        strong
            ? String(localized: "Your HRV is well above your average of \(avg)ms (+\(pct)%). Read a jump this large alongside how you feel and your recent training.", bundle: LanguageManager.appBundle)
            : String(localized: "Your HRV is above your average of \(avg)ms (+\(pct)%), indicating good recovery.", bundle: LanguageManager.appBundle)
    }

    private func rmssdBelowAverage(pct: String, avg: String, strong: Bool) -> String {
        strong
            ? String(localized: "Your HRV is significantly below your average of \(avg)ms (\(pct)%). Consider taking it easy today.", bundle: LanguageManager.appBundle)
            : String(localized: "Your HRV is below your average of \(avg)ms (\(pct)%). Below your usual range.", bundle: LanguageManager.appBundle)
    }

    private func heartRateInsight(_ stats: TrendStats) -> String? {
        let currentHR = result.timeDomain.meanHR
        let hrDiff = currentHR - stats.avgHR
        guard abs(hrDiff) > 5 else { return nil }
        let now = String(format: "%.0f", locale: LanguageManager.appLocale, currentHR)
        let avg = String(format: "%.0f", locale: LanguageManager.appLocale, stats.avgHR)
        if hrDiff > 5 {
            return String(localized: "Resting heart rate is elevated at \(now) bpm (avg: \(avg) bpm), which may indicate stress, dehydration, or incomplete recovery.", bundle: LanguageManager.appBundle)
        }
        return String(localized: "Resting heart rate is lower than average at \(now) bpm (avg: \(avg) bpm), suggesting good cardiovascular fitness or deep rest.", bundle: LanguageManager.appBundle)
    }

    private func stressInsight(_ stats: TrendStats) -> String? {
        guard let stress = result.ansMetrics?.stressIndex, let avgStress = stats.avgStress,
              stress > avgStress * 1.3, stress > 200
        else { return nil }
        return String(localized: "Stress markers are elevated compared to your norm. Consider stress management today.", bundle: LanguageManager.appBundle)
    }

    private func weeklyTrendInsight(_ stats: TrendStats) -> String? {
        guard let trend = stats.trend7Day else { return nil }
        let pct = String(format: "%.0f", locale: LanguageManager.appLocale, trend)
        if trend > 0 {
            return String(localized: "Your 7-day HRV trend is improving (+\(pct)%)—keep doing what you're doing!", bundle: LanguageManager.appBundle)
        }
        if trend < 0 {
            return String(localized: "Your 7-day HRV trend shows a decline (\(pct)%). Consider prioritizing recovery.", bundle: LanguageManager.appBundle)
        }
        return nil
    }

    private func sessionCountInsight(_ stats: TrendStats) -> String? {
        guard stats.sessionCount < 7 else { return nil }
        return String(localized: "With \(stats.sessionCount) sessions recorded, trends will become more accurate over time.", bundle: LanguageManager.appBundle)
    }
}
