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
            .accessibilityLabel(String(localized: "Acute to chronic ratio: \(String(format: "%.2f", locale: .current, acr)), \(acrZone(acr)) zone", bundle: LanguageManager.appBundle))
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

    /// Zone labels are descriptive ranges, not risk predictions. The gauge
    /// uses colour bands for the visual information; the text under each
    /// band is honest about what the number means — it describes where the user
    /// is, it doesn't predict consequences.
    private func acrZone(_ acr: Double) -> String {
        if acr < 0.8 { return String(localized: "below range", bundle: LanguageManager.appBundle) }
        if acr <= 1.3 { return String(localized: "in range", bundle: LanguageManager.appBundle) }
        if acr <= 1.5 { return String(localized: "above range", bundle: LanguageManager.appBundle) }
        return String(localized: "sharp increase", bundle: LanguageManager.appBundle)
    }

    private func acrGaugeTrack(acr: Double, width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            acrZoneBands
            acrGaugeThumb(acr: acr, width: width)
        }
    }

    private var acrZoneBands: some View {
        HStack(spacing: 0) {
            Rectangle().fill(AppTheme.mist.opacity(0.3)) // Detraining
            Rectangle().fill(AppTheme.sage.opacity(0.3)) // Optimal
            Rectangle().fill(AppTheme.softGold.opacity(0.3)) // Pushing
            Rectangle().fill(AppTheme.alert.opacity(0.3)) // Risk
        }
        .cornerRadius(6)
    }

    private func acrGaugeThumb(acr: Double, width: CGFloat) -> some View {
        let position = min(max((acr - 0.5) / 1.2, 0), 1)
        return Circle()
            .fill(.white)
            .frame(width: 20, height: 20)
            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            .overlay(acrGaugeThumbLabel(acr))
            .offset(x: width * position - 10)
    }

    private func acrGaugeThumbLabel(_ acr: Double) -> some View {
        Text(String(format: "%.1f", locale: .current, acr))
            .scaledFont(size: 9, weight: .bold, design: .rounded)
            .foregroundColor(AppTheme.textPrimary)
    }

    private var acrZoneLabels: some View {
        HStack {
            // Gauge-bar end labels are range descriptors,
            // not risk verdicts.
            Text(String(localized: "Below", bundle: LanguageManager.appBundle)).font(.caption2).foregroundColor(AppTheme.mist)
            Spacer()
            Text(String(localized: "In range", bundle: LanguageManager.appBundle)).font(.caption2).foregroundColor(AppTheme.sage)
            Spacer()
            Text(String(localized: "Sharp jump", bundle: LanguageManager.appBundle)).font(.caption2).foregroundColor(AppTheme.alert)
        }
    }

    /// ATL / CTL / TSB pills
    private var loadPills: some View {
        HStack(spacing: 16) {
            trainingPill(label: "ATL", value: String(format: "%.0f", locale: .current, training.atl), subtitle: String(localized: "Fatigue", bundle: LanguageManager.appBundle))
            trainingPill(label: "CTL", value: String(format: "%.0f", locale: .current, training.ctl), subtitle: String(localized: "Fitness", bundle: LanguageManager.appBundle))
            trainingPill(label: "TSB", value: String(format: "%+.0f", locale: .current, training.tsb), subtitle: String(localized: "Form", bundle: LanguageManager.appBundle), color: training.tsb >= 0 ? AppTheme.sage : AppTheme.terracotta)
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
