import SwiftUI

/// Training load dashboard card showing ATL/CTL/TSB and the Acute:Chronic
/// Ratio gauge bar.
struct TrainingLoadCard: View {
    let training: TrainingContext

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            trainingLoadHeader

            acrGauge
            loadPills
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    private var trainingLoadHeader: some View {
        HStack {
            Image(systemName: "figure.run")
                .foregroundColor(AppTheme.primary)
            Text(String(localized: "TRAINING LOAD", bundle: LanguageManager.appBundle))
                .font(.caption.weight(.semibold))
                .foregroundColor(AppTheme.textTertiary)
                .tracking(1)
            Spacer()
        }
    }

    /// ACR Gauge bar
    @ViewBuilder
    private var acrGauge: some View {
        if let acr = training.acuteChronicRatio {
            acrGaugeColumn(acr)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "Acute to chronic ratio: \(String(format: "%.2f", locale: LanguageManager.appLocale, acr)), \(ACWRBand(ratio: acr).label) zone", bundle: LanguageManager.appBundle))
        }
    }

    private func acrGaugeColumn(_ acr: Double) -> some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                acrGaugeTrack(acr: acr, width: geo.size.width)
            }
            .frame(height: 20)
            acrZoneLabels
        }
    }

    // Zone words are `ACWRBand`'s (the Training Load screen's and the PDF's):
    // descriptive ranges, not risk predictions. The gauge uses colour bands
    // for the visual information.

    /// The coloured bands' edges, `ACWRBand`'s: below 0.8, in range to 1.3
    /// (its maintenance and in-range bands share one colour), above to 1.5,
    /// then the sharp increase.
    private static let acrBelow = 0.8
    private static let acrInRange = 1.3
    private static let acrAbove = 1.5
    /// The gauge spans 0.5–1.7.
    private static let gaugeMin = 0.5
    private static let gaugeMax = 1.7

    private static func gaugeFraction(_ acr: Double) -> Double {
        min(max((acr - gaugeMin) / (gaugeMax - gaugeMin), 0), 1)
    }

    private func acrGaugeTrack(acr: Double, width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            acrZoneBands(width: width)
            acrGaugeThumb(acr: acr, width: width)
        }
    }

    private func acrZoneBands(width: CGFloat) -> some View {
        let edges = [Self.gaugeMin, Self.acrBelow, Self.acrInRange, Self.acrAbove, Self.gaugeMax].map(Self.gaugeFraction)
        let colors = [AppTheme.mist, AppTheme.sage, AppTheme.softGold, AppTheme.alert] // below, in range, above, sharp
        return HStack(spacing: 0) {
            ForEach(colors.indices, id: \.self) { i in
                Rectangle()
                    .fill(colors[i].opacity(0.3))
                    .frame(width: width * (edges[i + 1] - edges[i]))
            }
        }
        .cornerRadius(6)
    }

    private func acrGaugeThumb(acr: Double, width: CGFloat) -> some View {
        Circle()
            .fill(.white)
            .frame(width: 20, height: 20)
            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            .overlay(acrGaugeThumbLabel(acr))
            .offset(x: width * Self.gaugeFraction(acr) - 10)
    }

    private func acrGaugeThumbLabel(_ acr: Double) -> some View {
        Text(String(format: "%.1f", locale: LanguageManager.appLocale, acr))
            .scaledFont(size: 9, weight: .bold, design: .rounded)
            .foregroundColor(AppTheme.textPrimary)
    }

    /// One label per coloured band, in `ACWRBand`'s words: range
    /// descriptors, not risk verdicts.
    private var acrZoneLabels: some View {
        HStack {
            Text(verbatim: ACWRBand.belowUsual.label).font(.caption2).foregroundColor(AppTheme.mist)
            Spacer()
            Text(verbatim: ACWRBand.inRange.label).font(.caption2).foregroundColor(AppTheme.sageText)
            Spacer()
            Text(verbatim: ACWRBand.aboveUsual.label).font(.caption2).foregroundColor(AppTheme.softGold)
            Spacer()
            Text(verbatim: ACWRBand.sharpIncrease.label).font(.caption2).foregroundColor(AppTheme.alert)
        }
    }

    /// ATL / CTL / TSB pills
    private var loadPills: some View {
        HStack(spacing: 16) {
            trainingPill(label: "ATL", value: String(format: "%.0f", locale: LanguageManager.appLocale, training.atl), subtitle: String(localized: "Fatigue", bundle: LanguageManager.appBundle))
            trainingPill(label: "CTL", value: String(format: "%.0f", locale: LanguageManager.appLocale, training.ctl), subtitle: String(localized: "Fitness", bundle: LanguageManager.appBundle))
            trainingPill(label: "TSB", value: String(format: "%+.0f", locale: LanguageManager.appLocale, training.tsb), subtitle: String(localized: "Form", bundle: LanguageManager.appBundle), color: training.tsb >= 0 ? AppTheme.sage : AppTheme.terracotta)
        }
    }

    private func trainingPill(label: String, value: String, subtitle: String, color: Color? = nil) -> some View {
        let color = color ?? AppTheme.textPrimary
        return VStack(spacing: 2) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundColor(AppTheme.textTertiary)
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundColor(color)
            Text(subtitle)
                .font(.caption2)
                .foregroundColor(AppTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(subtitle): \(value)")
    }
}
