import Charts
import SwiftUI

// The metrics grid and trend-comparison sections, split out of
// `SessionHRVDetailView.swift` when that struct's body passed the
// 500-line ceiling. Only the declaration site moved.

extension SessionHRVDetailView {
    // MARK: - All Metrics Grid

    var metricsGridSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            timeDomainMetrics

            Divider()

            frequencyDomainMetrics

            nonlinearMetrics

            ansIndexMetrics

            Divider()

            dataQualityMetrics
        }
        .zenCard()
    }

    private var timeDomainMetrics: some View {
        VStack(alignment: .leading, spacing: 10) {
            metricSectionHeader(title: String(localized: "Time Domain", bundle: LanguageManager.appBundle), icon: "clock")
            timeDomainGrid
        }
    }

    private var timeDomainGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            metricCell(label: String(localized: "Mean RR", bundle: LanguageManager.appBundle), value: Self.measured("%.0f", result.timeDomain.meanRR, unit: Self.msUnit))
            metricCell(label: "SDNN", value: Self.measured("%.1f", result.timeDomain.sdnn, unit: Self.msUnit))
            metricCell(label: "RMSSD", value: Self.measured("%.1f", result.timeDomain.rmssd, unit: Self.msUnit))
            metricCell(label: "pNN50", value: String(format: "%.1f%%", locale: LanguageManager.appLocale, result.timeDomain.pnn50))
            metricCell(label: "SDSD", value: Self.measured("%.1f", result.timeDomain.sdsd, unit: Self.msUnit))
            metricCell(label: String(localized: "HR Range", bundle: LanguageManager.appBundle), value: String(format: "%.0f-%.0f", locale: LanguageManager.appLocale, result.timeDomain.minHR, result.timeDomain.maxHR))
            metricCell(label: String(localized: "Mean HR", bundle: LanguageManager.appBundle), value: Self.measured("%.0f", result.timeDomain.meanHR, unit: Self.bpmUnit))
            metricCell(label: String(localized: "SD HR", bundle: LanguageManager.appBundle), value: Self.measured("%.1f", result.timeDomain.sdHR, unit: Self.bpmUnit))
            if let tri = result.timeDomain.triangularIndex {
                metricCell(label: "HRV TI", value: String(format: "%.1f", locale: LanguageManager.appLocale, tri))
            }
        }
    }

    @ViewBuilder
    private var frequencyDomainMetrics: some View {
        if let fd = result.frequencyDomain {
            frequencyDomainCard(fd)

            Divider()
        }
    }

    private func frequencyDomainCard(_ fd: FrequencyDomainMetrics) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            metricSectionHeader(title: String(localized: "Frequency Domain", bundle: LanguageManager.appBundle), icon: "waveform.path")
            frequencyDomainGrid(fd)
        }
    }

    private func frequencyDomainGrid(_ fd: FrequencyDomainMetrics) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            if let vlf = fd.vlf {
                metricCell(label: "VLF", value: Self.measured("%.0f", vlf, unit: Self.msSquaredUnit))
            }
            metricCell(label: "LF", value: Self.measured("%.0f", fd.lf, unit: Self.msSquaredUnit))
            metricCell(label: "HF", value: Self.measured("%.0f", fd.hf, unit: Self.msSquaredUnit))
            metricCell(label: String(localized: "Total Power", bundle: LanguageManager.appBundle), value: Self.measured("%.0f", fd.totalPower, unit: Self.msSquaredUnit))
            if let lfNu = fd.lfNu {
                metricCell(label: "LF n.u.", value: String(format: "%.1f%%", locale: LanguageManager.appLocale, lfNu))
            }
            if let hfNu = fd.hfNu {
                metricCell(label: "HF n.u.", value: String(format: "%.1f%%", locale: LanguageManager.appLocale, hfNu))
            }
            if let ratio = fd.lfHfRatio {
                metricCell(label: "LF/HF", value: String(format: "%.2f", locale: LanguageManager.appLocale, ratio))
            }
        }
    }

    private var nonlinearMetrics: some View {
        VStack(alignment: .leading, spacing: 10) {
            metricSectionHeader(title: String(localized: "Nonlinear Analysis", bundle: LanguageManager.appBundle), icon: "point.3.filled.connected.trianglepath.dotted")
            nonlinearGrid
        }
    }

    private var nonlinearGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            metricCell(label: "SD1", value: Self.measured("%.1f", result.nonlinear.sd1, unit: Self.msUnit))
            metricCell(label: "SD2", value: Self.measured("%.1f", result.nonlinear.sd2, unit: Self.msUnit))
            metricCell(label: "SD1/SD2", value: String(format: "%.3f", locale: LanguageManager.appLocale, result.nonlinear.sd1Sd2Ratio))
            if let dfa1 = result.nonlinear.dfaAlpha1 {
                metricCell(label: "DFA α1", value: String(format: "%.2f", locale: LanguageManager.appLocale, dfa1))
            }
            if let dfa2 = result.nonlinear.dfaAlpha2 {
                metricCell(label: "DFA α2", value: String(format: "%.2f", locale: LanguageManager.appLocale, dfa2))
            }
            if let r2 = result.nonlinear.dfaAlpha1R2 {
                metricCell(label: "α1 R²", value: String(format: "%.3f", locale: LanguageManager.appLocale, r2))
            }
            if let sampEn = result.nonlinear.sampleEntropy {
                metricCell(label: "SampEn", value: String(format: "%.3f", locale: LanguageManager.appLocale, sampEn))
            }
            if let appEn = result.nonlinear.approxEntropy {
                metricCell(label: "ApEn", value: String(format: "%.3f", locale: LanguageManager.appLocale, appEn))
            }
        }
    }

    @ViewBuilder
    private var ansIndexMetrics: some View {
        if result.ansMetrics != nil {
            Divider()

            ansIndexCard
        }
    }

    private var ansIndexCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            metricSectionHeader(title: String(localized: "ANS Indexes", bundle: LanguageManager.appBundle), icon: "brain.head.profile")
            ansIndexGrid
        }
    }

    private var ansIndexGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            if let stress = result.ansMetrics?.stressIndex {
                metricCell(label: String(localized: "Stress Index", bundle: LanguageManager.appBundle), value: String(format: "%.0f", locale: LanguageManager.appLocale, stress))
            }
            if let pns = result.ansMetrics?.pnsIndex {
                metricCell(label: String(localized: "PNS Index", bundle: LanguageManager.appBundle), value: String(format: "%+.2f", locale: LanguageManager.appLocale, pns))
            }
            if let sns = result.ansMetrics?.snsIndex {
                metricCell(label: String(localized: "SNS Index", bundle: LanguageManager.appBundle), value: String(format: "%+.2f", locale: LanguageManager.appLocale, sns))
            }
            if let resp = result.ansMetrics?.respirationRate {
                metricCell(label: String(localized: "Resp Rate", bundle: LanguageManager.appBundle), value: String(format: String(localized: "%.1f br/min", bundle: LanguageManager.appBundle), locale: LanguageManager.appLocale, resp))
            }
            if let readiness = result.ansMetrics?.readinessScore {
                metricCell(label: String(localized: "Readiness", bundle: LanguageManager.appBundle), value: String(format: "%.1f /10", locale: LanguageManager.appLocale, readiness))
            }
        }
    }

    private var dataQualityMetrics: some View {
        VStack(alignment: .leading, spacing: 10) {
            metricSectionHeader(title: String(localized: "Data Quality", bundle: LanguageManager.appBundle), icon: "checkmark.seal")
            dataQualityGrid

            dataQualityNote
        }
    }

    private var dataQualityGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            metricCell(label: String(localized: "Window Beats", bundle: LanguageManager.appBundle), value: "\(result.cleanBeatCount)")
            metricCell(label: String(localized: "Artifacts", bundle: LanguageManager.appBundle), value: String(format: "%.1f%%", locale: LanguageManager.appLocale, result.artifactPercentage))
        }
    }

    /// Only shown when the metrics came from a window shorter than the
    /// recording; full-series analyses use every beat.
    @ViewBuilder
    private var dataQualityNote: some View {
        if let series = session.rrSeries, let minutes = analysisWindowMinutes,
           result.windowEnd - result.windowStart < series.points.count - 1 {
            Text(String(localized: "HRV metrics are from a \(LocalizedDuration.minutes(minutes)) analysis window, not the whole recording (\(series.points.count) beats).", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    private var analysisWindowMinutes: Int? {
        guard let start = result.windowStartMs, let end = result.windowEndMs, end > start else { return nil }
        return max(1, Int((Double(end - start) / 60_000).rounded()))
    }

    // MARK: - Trend Comparison

    var trendSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            trendHeader
            trendBody
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
    private var trendBody: some View {
        let stats = computeTrendStats()
        if stats.hasData {
            trendRows(stats)
        } else {
            trendEmptyState
        }
    }

    private func trendRows(_ stats: TrendStats) -> some View {
        VStack(spacing: 12) {
            hrvTrendRow(stats)

            restingHRTrendRow(stats)

            stressTrendRow(stats)

            readinessTrendRow(stats)
        }
    }

    private func hrvTrendRow(_ stats: TrendStats) -> some View {
        trendRow(
            metric: String(localized: "HRV (RMSSD)", bundle: LanguageManager.appBundle),
            current: result.timeDomain.rmssd,
            average: stats.avgRMSSD,
            unit: String(localized: "ms", bundle: LanguageManager.appBundle),
            higherIsBetter: true
        )
    }

    private func restingHRTrendRow(_ stats: TrendStats) -> some View {
        trendRow(
            metric: String(localized: "Resting HR", bundle: LanguageManager.appBundle),
            current: result.timeDomain.meanHR,
            average: stats.avgHR,
            unit: String(localized: "bpm", bundle: LanguageManager.appBundle),
            higherIsBetter: false
        )
    }

    @ViewBuilder
    private func stressTrendRow(_ stats: TrendStats) -> some View {
        if let currentStress = result.ansMetrics?.stressIndex, let avgStress = stats.avgStress {
            trendRow(
                metric: String(localized: "Stress Index", bundle: LanguageManager.appBundle),
                current: currentStress,
                average: avgStress,
                unit: "",
                higherIsBetter: false
            )
        }
    }

    @ViewBuilder
    private func readinessTrendRow(_ stats: TrendStats) -> some View {
        if let currentReadiness = result.ansMetrics?.readinessScore, let avgReadiness = stats.avgReadiness {
            trendRow(
                metric: String(localized: "Readiness", bundle: LanguageManager.appBundle),
                current: currentReadiness,
                average: avgReadiness,
                unit: "/10",
                higherIsBetter: true
            )
        }
    }

    private var trendEmptyState: some View {
        Text(String(localized: "More sessions needed for trend analysis", bundle: LanguageManager.appBundle))
            .font(.subheadline)
            .foregroundColor(AppTheme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding()
    }

    private func trendRow(metric: String, current: Double, average: Double, unit: String, higherIsBetter: Bool) -> some View {
        VStack(spacing: 8) {
            trendRowHeader(metric: metric, current: current, average: average, higherIsBetter: higherIsBetter)
            trendValuesRow(current: current, average: average, unit: unit)
            Divider()
        }
    }

    private func trendValuesRow(current: Double, average: Double, unit: String) -> some View {
        HStack(spacing: 16) {
            trendValue(String(localized: "Current", bundle: LanguageManager.appBundle), current, unit: unit, emphasised: true)
            trendValue(String(localized: "Average", bundle: LanguageManager.appBundle), average, unit: unit, emphasised: false)
            Spacer()
        }
    }

    private func trendRowHeader(metric: String, current: Double, average: Double, higherIsBetter: Bool) -> some View {
        let pctChange = average > 0 ? ((current - average) / average) * 100 : 0
        let isGood = higherIsBetter ? pctChange >= 0 : pctChange <= 0
        return HStack {
            Text(metric)
                .font(.subheadline.weight(.medium))
                .foregroundColor(AppTheme.textPrimary)
            Spacer()
            trendChangeBadge(pctChange: pctChange, isGood: isGood)
        }
    }

    /// The icon carries better/worse alongside the colour: the sign alone
    /// doesn't, since a higher heart rate is worse.
    private func trendChangeBadge(pctChange: Double, isGood: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: isGood ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .accessibilityHidden(true)
            Text(String(format: "%+.1f%%", locale: LanguageManager.appLocale, pctChange))
        }
        .font(.caption.weight(.bold))
        .foregroundColor(isGood ? AppTheme.sage : AppTheme.terracotta)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isGood
            ? String(localized: "Better than average", bundle: LanguageManager.appBundle)
            : String(localized: "Worse than average", bundle: LanguageManager.appBundle))
    }

    /// The "Current" column carries the headline weight; the average sits
    /// back as a secondary reference value.
    private func trendValue(_ caption: String, _ value: Double, unit: String, emphasised: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption)
                .font(.caption2)
                .foregroundColor(AppTheme.textTertiary)
            Text(String(format: "%.1f", locale: LanguageManager.appLocale, value) + " " + unit)
                .font(emphasised ? .subheadline.weight(.bold) : .subheadline)
                .foregroundColor(emphasised ? nil : AppTheme.textSecondary)
        }
    }

    // MARK: - Trend Computation

    private struct TrendStats {
        let hasData: Bool
        let avgRMSSD: Double
        let avgHR: Double
        let avgStress: Double?
        let avgReadiness: Double?
    }

    /// Overnight-only — averaging in workouts/quick readings
    /// produced impossible "vs average" figures (see TrendComparisonCard).
    /// Only nights before this one count: a night opened from History is
    /// compared with what came before it, never with later nights.
    private func computeTrendStats() -> TrendStats {
        let valid = recentSessions.filter { isPriorReliableOvernight($0) }
        guard !valid.isEmpty else {
            return TrendStats(hasData: false, avgRMSSD: 0, avgHR: 0, avgStress: nil, avgReadiness: nil)
        }
        let rmssdValues = valid.compactMap(\.rmssd)
        return TrendStats(
            hasData: !rmssdValues.isEmpty,
            avgRMSSD: Self.mean(rmssdValues) ?? 0,
            avgHR: Self.mean(valid.compactMap(\.meanHR)) ?? 0,
            avgStress: Self.mean(valid.compactMap(\.stressIndex)),
            avgReadiness: Self.mean(valid.compactMap(\.readinessScore))
        )
    }

    private func isPriorReliableOvernight(_ other: HRVSession) -> Bool {
        other.sessionType == .overnight && other.state == .complete && other.analysisResult != nil
            && other.isReliableForHRVAggregates && other.id != session.id
            && other.startDate < session.startDate
    }

    private static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    // MARK: - Helpers

    static var msUnit: String { String(localized: "ms", bundle: LanguageManager.appBundle) }
    static var bpmUnit: String { String(localized: "bpm", bundle: LanguageManager.appBundle) }
    static var msSquaredUnit: String { String(localized: "ms²", bundle: LanguageManager.appBundle) }

    /// A number in the app language followed by its translated unit.
    static func measured(_ format: String, _ value: Double, unit: String) -> String {
        String(format: format, locale: LanguageManager.appLocale, value) + " " + unit
    }

    private func metricSectionHeader(title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(AppTheme.sage)
            Text(title)
                .font(.subheadline.bold())
                .foregroundColor(AppTheme.textPrimary)
        }
    }

    private func metricCell(label: String, value: String) -> some View {
        HRVMetricCell(label: label, value: value)
    }
}
