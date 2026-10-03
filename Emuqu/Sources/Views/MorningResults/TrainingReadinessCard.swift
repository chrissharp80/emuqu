import SwiftUI

/// Training readiness gauge showing how ready the athlete is for today's
/// session, combining recovery score with current day's accumulated load.
struct TrainingReadinessCard: View {
    let recoveryScore: Double
    let dayTrimp: Double
    let trainingContext: TrainingContext?
    /// Explicit morning ATL for fatigue dissipation bonus. When provided, the
    /// difference between this value and the context's ATL drives the freshness
    /// gain. Pass the snapshot (through-yesterday) ATL here when the context
    /// already has the today-stepped ATL applied.
    var snapshotATL: Double?
    /// Frozen readiness (0-10 scale) from acceptance. When provided, the card
    /// displays this value directly instead of recomputing from training metrics.
    /// This ensures history always matches the dashboard's acceptance-time value.
    var frozenReadiness: Double?
    var translate: (String) -> String = { $0 }

    /// Readiness on 0-10 scale (frozen or computed)
    private var computedReadiness: Double {
        if let frozen = frozenReadiness { return frozen }
        let ctl = trainingContext?.ctl ?? 0
        let atlVal = trainingContext?.atl ?? 0
        let acrVal = trainingContext?.acuteChronicRatio
        let r100 = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: recoveryScore,
            todayTrimp: dayTrimp,
            ctl: ctl,
            atl: atlVal,
            morningATL: snapshotATL ?? atlVal,
            acuteChronicRatio: acrVal
        )
        return RecoveryScoreCalculator.toTenScale(r100)
    }

    var body: some View {
        let readiness = computedReadiness
        let readiness100 = readiness * 10.0
        let readinessColor = AppTheme.readinessColor(readiness)
        return VStack(alignment: .leading, spacing: 10) {
            readinessHeader(readiness, readinessColor)
            readinessGauge(readiness, readiness100, readinessColor)
            readinessMessage(readiness)
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Training readiness: \(String(format: "%.1f", locale: .current, readiness)) out of 10, \(translate(RecoveryScoreCalculator.readinessLabel(for: readiness)))", bundle: LanguageManager.appBundle))
    }

    private func readinessHeader(_ readiness: Double, _ readinessColor: Color) -> some View {
        HStack {
            Image(systemName: "bolt.fill")
                .foregroundColor(readinessColor)
            Text(String(localized: "TRAINING READINESS", bundle: LanguageManager.appBundle))
                .font(.caption.weight(.semibold))
                .foregroundColor(AppTheme.textTertiary)
                .tracking(1)
            Spacer()
            Text(translate(RecoveryScoreCalculator.readinessLabel(for: readiness)))
                .font(.subheadline.weight(.bold))
                .foregroundColor(readinessColor)
        }
    }

    /// Score + gauge (FITIV-style — big number + thick gradient bar).
    private func readinessGauge(
        _ readiness: Double,
        _ readiness100: Double,
        _ readinessColor: Color
    ) -> some View {
        HStack(spacing: 14) {
            Text(String(format: "%.1f", locale: .current, readiness))
                .scaledFont(size: 38, weight: .bold, design: .default)
                .foregroundColor(readinessColor)
            readinessBarColumn(readiness100)
        }
    }

    private func readinessBarColumn(_ readiness100: Double) -> some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                readinessBar(geo: geo, readiness100: readiness100)
            }
            .frame(height: 20)
            zoneLabels
        }
    }

    /// Zone boundaries aligned with the label thresholds (0–100 scale):
    /// Rest 0–20, Fatigued 20–45, Moderate 45–70, Ready 70–100.
    private func readinessBar(geo: GeometryProxy, readiness100: Double) -> some View {
        ZStack(alignment: .leading) {
            zoneBackground(geo: geo)
            zoneFill(geo: geo, readiness100: readiness100)
            indicatorDot(geo: geo, readiness100: readiness100)
        }
    }

    /// Background zones, widths 20% / 25% / 25% / 30%.
    private func zoneBackground(geo: GeometryProxy) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(AppTheme.dustyRose.opacity(0.3))
                .frame(width: geo.size.width * 0.20)
            Rectangle().fill(AppTheme.terracotta.opacity(0.3))
                .frame(width: geo.size.width * 0.25)
            Rectangle().fill(AppTheme.softGold.opacity(0.3))
                .frame(width: geo.size.width * 0.25)
            Rectangle().fill(AppTheme.sage.opacity(0.3))
                .frame(width: geo.size.width * 0.30)
        }
        .frame(height: 14)
        .cornerRadius(7)
    }

    /// Coloured fill, positioned on the same 0–100 scale as the labels.
    private func zoneFill(geo: GeometryProxy, readiness100: Double) -> some View {
        let fill = min(max(readiness100, 0), 100) / 100.0
        return HStack(spacing: 0) {
            zoneFillSegment(geo: geo, fill: fill, from: 0, width: 0.20, color: AppTheme.dustyRose)
            zoneFillSegment(geo: geo, fill: fill, from: 0.20, width: 0.25, color: AppTheme.terracotta)
            zoneFillSegment(geo: geo, fill: fill, from: 0.45, width: 0.25, color: AppTheme.softGold)
            zoneFillSegment(geo: geo, fill: fill, from: 0.70, width: 0.30, color: AppTheme.sage)
        }
        .frame(height: 14)
        .cornerRadius(7)
    }

    @ViewBuilder
    private func zoneFillSegment(
        geo: GeometryProxy,
        fill: Double,
        from: Double,
        width: Double,
        color: Color
    ) -> some View {
        if fill > from {
            Rectangle().fill(color)
                .frame(width: geo.size.width * min(fill - from, width))
        }
    }

    private func indicatorDot(geo: GeometryProxy, readiness100: Double) -> some View {
        let position = min(max(readiness100, 0), 100) / 100.0
        return Circle()
            .fill(.white)
            .frame(width: 20, height: 20)
            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            .offset(x: geo.size.width * position - 10)
    }

    /// Zone labels (bigger, bolder).
    private var zoneLabels: some View {
        HStack {
            Text(String(localized: "Rest", bundle: LanguageManager.appBundle)).font(.caption.weight(.medium)).foregroundColor(AppTheme.dustyRoseText)
            Spacer()
            Text(String(localized: "Fatigued", bundle: LanguageManager.appBundle)).font(.caption.weight(.medium)).foregroundColor(AppTheme.terracottaText)
            Spacer()
            Text(String(localized: "Moderate", bundle: LanguageManager.appBundle)).font(.caption.weight(.medium)).foregroundColor(AppTheme.softGoldText)
            Spacer()
            Text(String(localized: "Ready", bundle: LanguageManager.appBundle)).font(.caption.weight(.medium)).foregroundColor(AppTheme.sageText)
        }
    }

    private func readinessMessage(_ readiness: Double) -> some View {
        Text(translate(RecoveryScoreCalculator.readinessMessage(for: readiness, acuteChronicRatio: trainingContext?.acuteChronicRatio)))
            .font(.caption)
            .foregroundColor(AppTheme.textSecondary)
    }
}
