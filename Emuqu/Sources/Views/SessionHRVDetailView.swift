import Charts
import SwiftUI

/// Detailed single-session HRV analysis — drills in from HRV card on Dashboard and Recovery Report.
/// Shows heart rate stats, peak capacity, trend comparison, charts (tachogram, Poincaré, frequency),
/// and full Kubios-style technical metrics.
struct SessionHRVDetailView: View {
    let session: HRVSession
    let result: HRVAnalysisResult
    var recentSessions: [HRVSession] = []

    // MARK: - Body

    var body: some View {
        ScrollView {
            detailSections
                .padding()
        }
        .background(AppTheme.background)
        .navigationTitle(String(localized: "HRV Analysis", bundle: LanguageManager.appBundle))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var detailSections: some View {
        VStack(spacing: 20) {
            summarySections
            chartSections
        }
    }

    @ViewBuilder
    private var summarySections: some View {
        // HRV Hero
        hrvHeroSection

        // Heart Rate Stats
        hrStatsRow

        // Peak Capacity
        if let peak = result.peakCapacity {
            PeakCapacityCard(capacity: peak, showInfoButton: true)
        }

        // Heart Rate Chart (non-overnight)
        if session.sessionType != .overnight {
            heartRateChartSection
        }

        // Trend Comparison
        if !recentSessions.isEmpty {
            trendSection
        }
    }

    @ViewBuilder
    private var chartSections: some View {
        // Tachogram
        tachogramSection

        // Poincaré Plot
        poincarePlotSection

        // Frequency Analysis
        if result.frequencyDomain != nil {
            frequencySection
        }

        // All Metrics
        metricsGridSection
    }

    // MARK: - HRV Hero

    private var hrvHeroSection: some View {
        VStack(spacing: 8) {
            heroRMSSDValue
            heroRMSSDCaption
            heroHRVLabel
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    private var heroRMSSDValue: some View {
        HStack(alignment: .lastTextBaseline, spacing: 4) {
            Text(String(format: "%.0f", locale: .current, result.timeDomain.rmssd))
                .scaledFont(size: 56, weight: .bold)
                .foregroundColor(AppTheme.hrvColor(result.timeDomain.rmssd))
            Text(String(localized: "ms", bundle: LanguageManager.appBundle))
                .font(.title3)
                .foregroundColor(AppTheme.textTertiary)
        }
    }

    private var heroRMSSDCaption: some View {
        Text(String(localized: "RMSSD", bundle: LanguageManager.appBundle))
            .font(.caption.weight(.semibold))
            .foregroundColor(AppTheme.textTertiary)
            .tracking(1)
    }

    private var heroHRVLabel: some View {
        Text(AppTheme.hrvLabel(result.timeDomain.rmssd))
            .font(.subheadline.weight(.medium))
            .foregroundColor(AppTheme.hrvColor(result.timeDomain.rmssd))
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(AppTheme.hrvColor(result.timeDomain.rmssd).opacity(0.15))
            .cornerRadius(12)
    }

    // MARK: - Heart Rate Stats Row

    private var hrStatsRow: some View {
        HStack(spacing: 8) {
            hrStatCard(title: String(localized: "Min", bundle: LanguageManager.appBundle), value: result.timeDomain.minHR, unit: "bpm", color: AppTheme.sage)
            hrStatCard(title: String(localized: "Avg", bundle: LanguageManager.appBundle), value: result.timeDomain.meanHR, unit: "bpm", color: AppTheme.terracotta)
            hrStatCard(title: String(localized: "Max", bundle: LanguageManager.appBundle), value: result.timeDomain.maxHR, unit: "bpm", color: AppTheme.dustyRose)
            hrStatCard(title: String(localized: "SDNN", bundle: LanguageManager.appBundle), value: result.timeDomain.sdnn, unit: "ms", color: AppTheme.sdnnColor)
        }
    }

    private func hrStatCard(title: String, value: Double, unit: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundColor(AppTheme.textTertiary)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(String(format: "%.0f", locale: .current, value))
                    .font(.system(.headline, design: .rounded).bold())
                    .foregroundColor(color)
                Text(unit)
                    .font(.caption2)
                    .foregroundColor(AppTheme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(AppTheme.sectionTint)
        .cornerRadius(AppTheme.smallCornerRadius)
    }

    // MARK: - Heart Rate Chart (non-overnight)

    private var heartRateChartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(localized: "Heart Rate Over Time", bundle: LanguageManager.appBundle))
                    .font(.headline)
                    .foregroundColor(AppTheme.textPrimary)
                Spacer()
                Text(String(localized: "\(Int(result.timeDomain.minHR))-\(Int(result.timeDomain.maxHR)) bpm", bundle: LanguageManager.appBundle))
                    .font(.caption.bold())
                    .foregroundColor(AppTheme.terracotta)
            }

            HeartRateChartView(session: session, result: result)
                .frame(height: 150)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "Heart rate over time chart", bundle: LanguageManager.appBundle))
                .accessibilityValue(String(
                    localized: "Range \(Int(result.timeDomain.minHR)) to \(Int(result.timeDomain.maxHR)) beats per minute, mean \(Int(result.timeDomain.meanHR))", bundle: LanguageManager.appBundle
                ))
        }
        .zenCard()
    }

    // MARK: - Tachogram

    private var tachogramSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(localized: "Heart Rate Variability", bundle: LanguageManager.appBundle))
                    .font(.headline)
                    .foregroundColor(AppTheme.textPrimary)
                Spacer()
                Text(String(localized: "RR Intervals", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundColor(AppTheme.textTertiary)
            }

            TachogramView(session: session, result: result)
                .frame(height: 120)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "RR interval tachogram", bundle: LanguageManager.appBundle))
                .accessibilityValue(String(
                    localized: "RMSSD \(Int(result.timeDomain.rmssd)) milliseconds, SDNN \(Int(result.timeDomain.sdnn)) milliseconds", bundle: LanguageManager.appBundle
                ))
        }
        .zenCard()
    }

    // MARK: - Poincaré Plot

    private var poincarePlotSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            poincareHeader
            poincarePlot
            poincareLegend
        }
        .zenCard()
    }

    private var poincareHeader: some View {
        HStack {
            Text(String(localized: "Poincaré Plot", bundle: LanguageManager.appBundle))
                .font(.headline)
                .foregroundColor(AppTheme.textPrimary)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(localized: "SD1: \(String(format: "%.1f", locale: .current, result.nonlinear.sd1)) ms", bundle: LanguageManager.appBundle))
                    .font(.caption)
                Text(String(localized: "SD2: \(String(format: "%.1f", locale: .current, result.nonlinear.sd2)) ms", bundle: LanguageManager.appBundle))
                    .font(.caption)
            }
            .foregroundColor(AppTheme.textSecondary)
        }
    }

    private var poincarePlot: some View {
        PoincarePlotView(session: session, result: result)
            .frame(height: 250)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "Poincaré plot", bundle: LanguageManager.appBundle))
            .accessibilityValue(String(
                localized: "SD1 \(String(format: "%.1f", locale: .current, result.nonlinear.sd1)) milliseconds, SD2 \(String(format: "%.1f", locale: .current, result.nonlinear.sd2)) milliseconds", bundle: LanguageManager.appBundle
            ))
    }

    private var poincareLegend: some View {
        HStack(spacing: 20) {
            sd1Legend
            sd2Legend
        }
    }

    private var sd1Legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(AppTheme.primary).frame(width: 8, height: 8)
                Text(String(localized: "SD1", bundle: LanguageManager.appBundle)).font(.caption.bold()).foregroundColor(AppTheme.textPrimary)
            }
            Text(String(localized: "Short-term variability", bundle: LanguageManager.appBundle))
                .font(.caption2).foregroundColor(AppTheme.textTertiary)
        }
    }

    private var sd2Legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(AppTheme.dustyRose).frame(width: 8, height: 8)
                Text(String(localized: "SD2", bundle: LanguageManager.appBundle)).font(.caption.bold()).foregroundColor(AppTheme.textPrimary)
            }
            Text(String(localized: "Long-term variability", bundle: LanguageManager.appBundle))
                .font(.caption2).foregroundColor(AppTheme.textTertiary)
        }
    }

    // MARK: - Frequency Analysis

    private var frequencySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "Frequency Analysis", bundle: LanguageManager.appBundle))
                .font(.headline)
                .foregroundColor(AppTheme.textPrimary)

            lfHfRatioSection
        }
        .zenCard()
    }

    @ViewBuilder
    private var lfHfRatioSection: some View {
        if let fd = result.frequencyDomain {
            FrequencyBandsView(frequencyDomain: fd)
                .frame(height: 100)

            LFHFRatioRow(fd: fd)
        }
    }
}
