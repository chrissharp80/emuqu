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
            metricCell(label: String(localized: "Mean RR", bundle: LanguageManager.appBundle), value: String(format: "%.0f ms", locale: .current, result.timeDomain.meanRR))
            metricCell(label: "SDNN", value: String(format: "%.1f ms", locale: .current, result.timeDomain.sdnn))
            metricCell(label: "RMSSD", value: String(format: "%.1f ms", locale: .current, result.timeDomain.rmssd))
            metricCell(label: "pNN50", value: String(format: "%.1f%%", locale: .current, result.timeDomain.pnn50))
            metricCell(label: "SDSD", value: String(format: "%.1f ms", locale: .current, result.timeDomain.sdsd))
            metricCell(label: String(localized: "HR Range", bundle: LanguageManager.appBundle), value: String(format: "%.0f-%.0f", locale: .current, result.timeDomain.minHR, result.timeDomain.maxHR))
            metricCell(label: String(localized: "Mean HR", bundle: LanguageManager.appBundle), value: String(format: "%.0f bpm", locale: .current, result.timeDomain.meanHR))
            metricCell(label: String(localized: "SD HR", bundle: LanguageManager.appBundle), value: String(format: "%.1f bpm", locale: .current, result.timeDomain.sdHR))
            if let tri = result.timeDomain.triangularIndex {
                metricCell(label: "HRV TI", value: String(format: "%.1f", locale: .current, tri))
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
                metricCell(label: "VLF", value: String(format: "%.0f ms²", locale: .current, vlf))
            }
            metricCell(label: "LF", value: String(format: "%.0f ms²", locale: .current, fd.lf))
            metricCell(label: "HF", value: String(format: "%.0f ms²", locale: .current, fd.hf))
            metricCell(label: String(localized: "Total Power", bundle: LanguageManager.appBundle), value: String(format: "%.0f ms²", locale: .current, fd.totalPower))
            if let lfNu = fd.lfNu {
                metricCell(label: "LF n.u.", value: String(format: "%.1f%%", locale: .current, lfNu))
            }
            if let hfNu = fd.hfNu {
                metricCell(label: "HF n.u.", value: String(format: "%.1f%%", locale: .current, hfNu))
            }
            if let ratio = fd.lfHfRatio {
                metricCell(label: "LF/HF", value: String(format: "%.2f", locale: .current, ratio))
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
            metricCell(label: "SD1", value: String(format: "%.1f ms", locale: .current, result.nonlinear.sd1))
            metricCell(label: "SD2", value: String(format: "%.1f ms", locale: .current, result.nonlinear.sd2))
            metricCell(label: "SD1/SD2", value: String(format: "%.3f", locale: .current, result.nonlinear.sd1Sd2Ratio))
            if let dfa1 = result.nonlinear.dfaAlpha1 {
                metricCell(label: "DFA α1", value: String(format: "%.2f", locale: .current, dfa1))
            }
            if let dfa2 = result.nonlinear.dfaAlpha2 {
                metricCell(label: "DFA α2", value: String(format: "%.2f", locale: .current, dfa2))
            }
            if let r2 = result.nonlinear.dfaAlpha1R2 {
                metricCell(label: "α1 R²", value: String(format: "%.3f", locale: .current, r2))
            }
            if let sampEn = result.nonlinear.sampleEntropy {
                metricCell(label: "SampEn", value: String(format: "%.3f", locale: .current, sampEn))
            }
            if let appEn = result.nonlinear.approxEntropy {
                metricCell(label: "ApEn", value: String(format: "%.3f", locale: .current, appEn))
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
                metricCell(label: String(localized: "Stress Index", bundle: LanguageManager.appBundle), value: String(format: "%.0f", locale: .current, stress))
            }
            if let pns = result.ansMetrics?.pnsIndex {
                metricCell(label: String(localized: "PNS Index", bundle: LanguageManager.appBundle), value: String(format: "%+.2f", locale: .current, pns))
            }
            if let sns = result.ansMetrics?.snsIndex {
                metricCell(label: String(localized: "SNS Index", bundle: LanguageManager.appBundle), value: String(format: "%+.2f", locale: .current, sns))
            }
            if let resp = result.ansMetrics?.respirationRate {
                metricCell(label: String(localized: "Resp Rate", bundle: LanguageManager.appBundle), value: String(format: "%.1f /min", locale: .current, resp))
            }
            if let readiness = result.ansMetrics?.readinessScore {
                metricCell(label: String(localized: "Readiness", bundle: LanguageManager.appBundle), value: String(format: "%.1f /10", locale: .current, readiness))
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
            metricCell(label: String(localized: "Artifacts", bundle: LanguageManager.appBundle), value: String(format: "%.1f%%", locale: .current, result.artifactPercentage))
        }
    }

    @ViewBuilder
    private var dataQualityNote: some View {
        if let series = session.rrSeries {
            Text(String(localized: "HRV metrics are from a 5-min analysis window, not the full \(series.points.count) recorded beats.", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundColor(AppTheme.textSecondary)
        }
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
            baseline: stats.baselineRMSSD,
            unit: "ms",
            higherIsBetter: true
        )
    }

    private func restingHRTrendRow(_ stats: TrendStats) -> some View {
        trendRow(
            metric: String(localized: "Resting HR", bundle: LanguageManager.appBundle),
            current: result.timeDomain.meanHR,
            average: stats.avgHR,
            baseline: stats.baselineHR,
            unit: "bpm",
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
                baseline: stats.baselineStress,
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
                baseline: nil,
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

    private func trendRow(metric: String, current: Double, average: Double, baseline: Double?, unit: String, higherIsBetter: Bool) -> some View {
        VStack(spacing: 8) {
            trendRowHeader(metric: metric, current: current, average: average, higherIsBetter: higherIsBetter)
            trendValuesRow(current: current, average: average, baseline: baseline, unit: unit)
            Divider()
        }
    }

    @ViewBuilder
    private func trendValuesRow(current: Double, average: Double, baseline: Double?, unit: String) -> some View {
        HStack(spacing: 16) {
            trendValue(String(localized: "Current", bundle: LanguageManager.appBundle), current, unit: unit, emphasised: true)
            trendValue(String(localized: "Average", bundle: LanguageManager.appBundle), average, unit: unit, emphasised: false)
            if let b = baseline {
                trendValue(String(localized: "Baseline", bundle: LanguageManager.appBundle), b, unit: unit, emphasised: false)
            }
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
            Text(String(format: "%+.1f%%", locale: .current, pctChange))
                .font(.caption.weight(.bold))
                .foregroundColor(isGood ? AppTheme.sage : AppTheme.terracotta)
        }
    }

    /// The "Current" column carries the headline weight; average and baseline
    /// sit back as secondary reference values.
    private func trendValue(_ caption: String, _ value: Double, unit: String, emphasised: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption)
                .font(.caption2)
                .foregroundColor(AppTheme.textTertiary)
            Text(String(format: "%.1f", locale: .current, value) + " " + unit)
                .font(emphasised ? .subheadline.weight(.bold) : .subheadline)
                .foregroundColor(emphasised ? nil : AppTheme.textSecondary)
        }
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
    }

    /// Overnight-only — averaging in workouts/quick readings
    /// produced impossible "vs average" figures (see TrendComparisonCard).
    private func computeTrendStats() -> TrendStats {
        let valid = recentSessions
            .filter { $0.sessionType == .overnight && $0.state == .complete && $0.analysisResult != nil && $0.isReliableForHRVAggregates && $0.id != session.id }
            .sorted { $0.startDate < $1.startDate }
        guard !valid.isEmpty else {
            return TrendStats(hasData: false, avgRMSSD: 0, baselineRMSSD: nil, avgHR: 0, baselineHR: nil, avgStress: nil, baselineStress: nil, avgReadiness: nil)
        }
        let rmssdValues = valid.compactMap(\.rmssd)
        // Baseline from the oldest 5 sessions, and only when there are at
        // least 3 of them — fewer than that is not a baseline, it's noise.
        let baselineSessions = Array(valid.prefix(5))
        return TrendStats(
            hasData: !rmssdValues.isEmpty,
            avgRMSSD: Self.mean(rmssdValues) ?? 0,
            baselineRMSSD: Self.baselineMean(baselineSessions.compactMap(\.rmssd), count: baselineSessions.count),
            avgHR: Self.mean(valid.compactMap(\.meanHR)) ?? 0,
            baselineHR: Self.baselineMean(baselineSessions.compactMap(\.meanHR), count: baselineSessions.count),
            avgStress: Self.mean(valid.compactMap(\.stressIndex)),
            baselineStress: nil,
            avgReadiness: Self.mean(valid.compactMap(\.readinessScore))
        )
    }

    private static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    private static func baselineMean(_ values: [Double], count: Int) -> Double? {
        guard count >= 3 else { return nil }
        return mean(values)
    }

    // MARK: - Helpers

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
