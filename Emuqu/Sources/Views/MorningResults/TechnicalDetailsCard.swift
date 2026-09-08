import Charts
import SwiftUI

/// Comprehensive HRV metrics card showing time domain, frequency domain,
/// nonlinear analysis, ANS indexes, and data quality — Kubios Pro style.
struct TechnicalDetailsCard: View {
    let session: HRVSession
    let result: HRVAnalysisResult

    var body: some View {
        VStack(spacing: 16) {
            tachogramSection
            poincarePlotSection
            if result.frequencyDomain != nil {
                frequencySection
            }
            additionalMetricsSection
        }
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
                .accessibilityElement()
                .accessibilityLabel(Text(String(localized: "Tachogram chart of RR-interval beat-to-beat timing.", bundle: LanguageManager.appBundle)))
        }
        .zenCard()
    }

    // MARK: - Poincare Plot

    private var poincarePlotSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            poincarePlotHeader

            PoincarePlotView(session: session, result: result)
                .frame(height: 250)
                .accessibilityElement()
                .accessibilityLabel(Text(String(localized: "Poincaré plot. SD1 \(String(format: "%.1f", locale: .current, result.nonlinear.sd1)) milliseconds, SD2 \(String(format: "%.1f", locale: .current, result.nonlinear.sd2)) milliseconds.", bundle: LanguageManager.appBundle)))

            // Explanation
            explanationSection
        }
        .zenCard()
    }

    private var poincarePlotHeader: some View {
        HStack {
            Text(String(localized: "Poincare Plot", bundle: LanguageManager.appBundle))
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

    private var explanationSection: some View {
        HStack(spacing: 20) {
            legendEntry(
                color: AppTheme.primary,
                symbol: String(localized: "SD1", bundle: LanguageManager.appBundle),
                caption: String(localized: "Short-term variability", bundle: LanguageManager.appBundle)
            )
            legendEntry(
                color: AppTheme.dustyRose,
                symbol: String(localized: "SD2", bundle: LanguageManager.appBundle),
                caption: String(localized: "Long-term variability", bundle: LanguageManager.appBundle)
            )
        }
    }

    private func legendEntry(color: Color, symbol: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(symbol)
                    .font(.caption.bold())
                    .foregroundColor(AppTheme.textPrimary)
            }
            Text(caption)
                .font(.caption2)
                .foregroundColor(AppTheme.textTertiary)
        }
    }

    // MARK: - Frequency Domain

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
            // Band power bars
            FrequencyBandsView(frequencyDomain: fd)
                .frame(height: 100)
                .accessibilityElement()
                .accessibilityLabel(Text(String(localized: "Frequency band power chart. LF \(String(format: "%.0f", locale: .current, fd.lf)), HF \(String(format: "%.0f", locale: .current, fd.hf)) milliseconds squared.", bundle: LanguageManager.appBundle)))

            // LF/HF ratio
            LFHFRatioRow(fd: fd)
        }
    }

    // MARK: - Additional Metrics (Kubios Pro Style)

    private var additionalMetricsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Time Domain Section
            timeDomainSection

            Divider()

            // Frequency Domain Section
            frequencyDomainSection3
        }
        .zenCard()
    }

    @ViewBuilder
    private var frequencyDomainSection3: some View {
        frequencyDomainSection2

        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: String(localized: "Data Quality", bundle: LanguageManager.appBundle), icon: "checkmark.seal")

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                HRVMetricCell(label: "Window Beats", value: "\(result.cleanBeatCount)")
                HRVMetricCell(label: "Artifacts", value: String(format: "%.1f%%", locale: .current, result.artifactPercentage))
            }

            // Explanatory note
            Text(String(localized: "HRV metrics are from a 5-min analysis window, not the full \(session.rrSeries?.points.count ?? 0) recorded beats.", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    @ViewBuilder
    private var frequencyDomainSection2: some View {
        frequencyDomainSection

        // Nonlinear Section (Poincare & DFA)
        nonlinearSectionPoincareDfaSection

        // ANS Indexes Section
        ansIndexesSection

        // Data Quality
        Divider()
    }

    private static let metricColumns = [GridItem(.flexible()), GridItem(.flexible())]

    private var timeDomainSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: String(localized: "Time Domain", bundle: LanguageManager.appBundle), icon: "clock")

            LazyVGrid(columns: Self.metricColumns, spacing: 8) {
                timeDomainCells
            }
        }
    }

    @ViewBuilder
    private var timeDomainCells: some View {
        HRVMetricCell(label: "Mean RR", value: String(format: "%.0f ms", locale: .current, result.timeDomain.meanRR))
        HRVMetricCell(label: "SDNN", value: String(format: "%.1f ms", locale: .current, result.timeDomain.sdnn))
        HRVMetricCell(label: "RMSSD", value: String(format: "%.1f ms", locale: .current, result.timeDomain.rmssd))
        HRVMetricCell(label: "pNN50", value: String(format: "%.1f%%", locale: .current, result.timeDomain.pnn50))
        HRVMetricCell(label: "SDSD", value: String(format: "%.1f ms", locale: .current, result.timeDomain.sdsd))
        HRVMetricCell(label: "Window HR", value: String(format: "%.0f-%.0f", locale: .current, result.timeDomain.minHR, result.timeDomain.maxHR))
        HRVMetricCell(label: "Mean HR", value: String(format: "%.0f bpm", locale: .current, result.timeDomain.meanHR))
        HRVMetricCell(label: "SD HR", value: String(format: "%.1f bpm", locale: .current, result.timeDomain.sdHR))
        if let tri = result.timeDomain.triangularIndex {
            HRVMetricCell(label: "HRV TI", value: String(format: "%.1f", locale: .current, tri))
        }
    }

    @ViewBuilder
    private var frequencyDomainSection: some View {
        if let fd = result.frequencyDomain {
            frequencyDomainStack(fd)

            Divider()
        }
    }

    private func frequencyDomainStack(_ fd: FrequencyDomainMetrics) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: String(localized: "Frequency Domain", bundle: LanguageManager.appBundle), icon: "waveform.path")

            LazyVGrid(columns: Self.metricColumns, spacing: 8) {
                frequencyDomainCells(fd)
            }
        }
    }

    @ViewBuilder
    private func frequencyDomainCells(_ fd: FrequencyDomainMetrics) -> some View {
        if let vlf = fd.vlf {
            HRVMetricCell(label: "VLF", value: String(format: "%.0f ms\u{00B2}", locale: .current, vlf))
        }
        HRVMetricCell(label: "LF", value: String(format: "%.0f ms\u{00B2}", locale: .current, fd.lf))
        HRVMetricCell(label: "HF", value: String(format: "%.0f ms\u{00B2}", locale: .current, fd.hf))
        HRVMetricCell(label: "Total Power", value: String(format: "%.0f ms\u{00B2}", locale: .current, fd.totalPower))
        if let lfNu = fd.lfNu {
            HRVMetricCell(label: "LF n.u.", value: String(format: "%.1f%%", locale: .current, lfNu))
        }
        if let hfNu = fd.hfNu {
            HRVMetricCell(label: "HF n.u.", value: String(format: "%.1f%%", locale: .current, hfNu))
        }
        if let ratio = fd.lfHfRatio {
            HRVMetricCell(label: "LF/HF", value: String(format: "%.2f", locale: .current, ratio))
        }
    }

    private var nonlinearSectionPoincareDfaSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: String(localized: "Nonlinear Analysis", bundle: LanguageManager.appBundle), icon: "point.3.filled.connected.trianglepath.dotted")

            LazyVGrid(columns: Self.metricColumns, spacing: 8) {
                nonlinearCells
            }
        }
    }

    @ViewBuilder
    private var nonlinearCells: some View {
        HRVMetricCell(label: "SD1", value: String(format: "%.1f ms", locale: .current, result.nonlinear.sd1))
        HRVMetricCell(label: "SD2", value: String(format: "%.1f ms", locale: .current, result.nonlinear.sd2))
        HRVMetricCell(label: "SD1/SD2", value: String(format: "%.3f", locale: .current, result.nonlinear.sd1Sd2Ratio))
        if let dfa1 = result.nonlinear.dfaAlpha1 {
            HRVMetricCell(label: "DFA \u{03B1}1", value: String(format: "%.2f", locale: .current, dfa1))
        }
        if let dfa2 = result.nonlinear.dfaAlpha2 {
            HRVMetricCell(label: "DFA \u{03B1}2", value: String(format: "%.2f", locale: .current, dfa2))
        }
        if let r2 = result.nonlinear.dfaAlpha1R2 {
            HRVMetricCell(label: "\u{03B1}1 R\u{00B2}", value: String(format: "%.3f", locale: .current, r2))
        }
        if let sampEn = result.nonlinear.sampleEntropy {
            HRVMetricCell(label: "SampEn", value: String(format: "%.3f", locale: .current, sampEn))
        }
        if let appEn = result.nonlinear.approxEntropy {
            HRVMetricCell(label: "ApEn", value: String(format: "%.3f", locale: .current, appEn))
        }
    }

    @ViewBuilder
    private var ansIndexesSection: some View {
        if result.ansMetrics != nil {
            Divider()

            ansIndexesStack
        }
    }

    private var ansIndexesStack: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: String(localized: "ANS Indexes", bundle: LanguageManager.appBundle), icon: "brain.head.profile")

            LazyVGrid(columns: Self.metricColumns, spacing: 8) {
                ansCells
            }
        }
    }

    @ViewBuilder
    private var ansCells: some View {
        if let stress = result.ansMetrics?.stressIndex {
            HRVMetricCell(label: "Stress Index", value: String(format: "%.0f", locale: .current, stress))
        }
        if let pns = result.ansMetrics?.pnsIndex {
            HRVMetricCell(label: "PNS Index", value: String(format: "%+.2f", locale: .current, pns))
        }
        if let sns = result.ansMetrics?.snsIndex {
            HRVMetricCell(label: "SNS Index", value: String(format: "%+.2f", locale: .current, sns))
        }
        if let resp = result.ansMetrics?.respirationRate {
            HRVMetricCell(label: "Resp Rate", value: String(format: "%.1f /min", locale: .current, resp))
        }
        if let readiness = result.ansMetrics?.readinessScore {
            HRVMetricCell(label: "Readiness", value: String(format: "%.1f /10", locale: .current, readiness))
        }
    }
}

/// LF/HF ratio readout beside its sympathovagal-balance interpretation —
/// the row under the frequency-band bars on both the technical-details card
/// and the session HRV detail page.
struct LFHFRatioRow: View {
    let fd: FrequencyDomainMetrics

    var body: some View {
        HStack {
            ratioReadout

            Spacer()

            balanceSection
        }
    }

    private var ratioReadout: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "LF/HF Ratio", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
            Text(fd.lfHfRatio.map { String(format: "%.2f", locale: .current, $0) } ?? "\u{2014}")
                .font(.title3.bold())
                .foregroundColor(AppTheme.textPrimary)
        }
    }

    private var balanceSection: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(String(localized: "Sympathovagal Balance", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
            Text(AppTheme.balanceInterpretation(fd.lfHfRatio))
                .font(.subheadline.weight(.medium))
                .foregroundColor(AppTheme.balanceColor(fd.lfHfRatio))
        }
    }
}
