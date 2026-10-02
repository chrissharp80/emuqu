import SwiftUI

/// Full-width sleep card showing sleep/wake times, stage proportions bar,
/// and efficiency. The one card that tells the whole sleep story.
struct SleepCard: View {
    let sleep: SleepData

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sleepWindowRow
            stageSummary
            sleepMetricsRow
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    /// Stage bar + legend — a visual summary, no numbers, just proportions.
    /// Falls back to the mini timeline when the night has intervals but no
    /// per-stage totals.
    @ViewBuilder
    private var stageSummary: some View {
        let deep = sleep.deepSleepMinutes ?? 0
        let rem = sleep.remSleepMinutes ?? 0
        let light = max(0, sleep.nightSleepMinutes - deep - rem)
        let awake = sleep.awakeMinutes
        if sleep.deepSleepMinutes != nil || sleep.remSleepMinutes != nil {
            VStack(spacing: 6) {
                stageBar(deep: deep, light: light, rem: rem, awake: awake)
                stageLegend(deep: deep, light: light, rem: rem, awake: awake)
            }
        } else if !sleep.stageIntervals.isEmpty {
            SleepTimelineMini(
                stageIntervals: sleep.stageIntervals,
                sleepStart: sleep.sleepStart,
                sleepEnd: sleep.sleepEnd,
                splitGapMinutes: sleep.splitGapMinutes
            )
        }
    }

    private func stageBar(deep: Int, light: Int, rem: Int, awake: Int) -> some View {
        let total = deep + light + rem + awake
        return HStack(spacing: 1) {
            if deep > 0 { sleepStageBar(minutes: deep, total: total, color: .indigo) }
            if light > 0 { sleepStageBar(minutes: light, total: total, color: .blue) }
            if rem > 0 { sleepStageBar(minutes: rem, total: total, color: .cyan) }
            if awake > 0 { sleepStageBar(minutes: awake, total: total, color: .orange) }
        }
        .frame(height: 12)
        .cornerRadius(6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Sleep stages: Deep \(deep) minutes, Light \(light) minutes, REM \(rem) minutes\(awake > 0 ? String(localized: ", Awake \(awake) minutes", bundle: LanguageManager.appBundle) : "")", bundle: LanguageManager.appBundle))
    }

    /// Legend with durations.
    private func stageLegend(deep: Int, light: Int, rem: Int, awake: Int) -> some View {
        HStack(spacing: 0) {
            sleepStagePill(color: .indigo, label: String(localized: "Deep", bundle: LanguageManager.appBundle), minutes: deep)
            sleepStagePill(color: .blue, label: String(localized: "Light", bundle: LanguageManager.appBundle), minutes: light)
            sleepStagePill(color: .cyan, label: String(localized: "REM", bundle: LanguageManager.appBundle), minutes: rem)
            if awake > 0 { sleepStagePill(color: .orange, label: String(localized: "Awake", bundle: LanguageManager.appBundle), minutes: awake) }
        }
    }

    private var efficiencyReadout: some View {
        let efficiency = min(100, sleep.sleepEfficiency)
        return HStack(spacing: 4) {
            Text("\(Int(efficiency))%")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(efficiency >= 85 ? AppTheme.sage : (efficiency >= 75 ? AppTheme.softGold : AppTheme.terracotta))
            Text(String(localized: "efficiency", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Sleep efficiency: \(Int(efficiency)) percent, \(efficiency >= 85 ? String(localized: "good", bundle: LanguageManager.appBundle) : efficiency >= 75 ? String(localized: "fair", bundle: LanguageManager.appBundle) : String(localized: "low", bundle: LanguageManager.appBundle))", bundle: LanguageManager.appBundle))
    }

    private var detailsChevron: some View {
        HStack(spacing: 3) {
            Text(String(localized: "Details", bundle: LanguageManager.appBundle))
                .font(.caption)
            Image(systemName: "chevron.right")
                .font(.caption2)
        }
        .foregroundColor(AppTheme.textTertiary)
        .accessibilityLabel(String(localized: "View sleep details", bundle: LanguageManager.appBundle))
    }

    /// Sleep -> Wake times (the most important thing: "when did I sleep?")
    @ViewBuilder
    private var sleepWindowRow: some View {
        if let start = sleep.sleepStart, let end = sleep.sleepEnd {
            HStack(alignment: .center) {
                asleepBlock(start)
                Spacer()
                durationBlock
                Spacer()
                awakeBlock(end)
            }
            splitNightCallout
        }
    }

    private func asleepBlock(_ start: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "moon.fill")
                    .font(.caption2)
                    .foregroundColor(AppTheme.primary)
                Text(String(localized: "Asleep", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundColor(AppTheme.textTertiary)
            }
            Text(Self.sleepTimeFormatter.string(from: start))
                .font(.title2.weight(.semibold))
        }
    }

    /// Duration in the centre, between the two clock times.
    private var durationBlock: some View {
        VStack(spacing: 2) {
            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
            Text(sleepDurationFormatted(sleep.totalSleepIncludingNapMinutes))
                .font(.caption.weight(.medium))
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    private func awakeBlock(_ end: Date) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 4) {
                Text(String(localized: "Awake", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundColor(AppTheme.textTertiary)
                Image(systemName: "sun.max.fill")
                    .font(.caption2)
                    .foregroundColor(AppTheme.softGold)
            }
            Text(Self.sleepTimeFormatter.string(from: end))
                .font(.title2.weight(.semibold))
        }
    }

    @ViewBuilder
    private var splitNightCallout: some View {
        if sleep.isSplitNight {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption2)
                Text(String(localized: "\(sleep.effectiveSegments.count) sleep segments", bundle: LanguageManager.appBundle))
                    .font(.caption2)
            }
            .foregroundColor(AppTheme.softGold)
        }
    }

    /// Key metrics row: efficiency + one contextual insight
    private var sleepMetricsRow: some View {
        HStack {
            efficiencyReadout
            Spacer()
            detailsChevron
        }
    }

    // MARK: - Sleep Card Helpers

    @ViewBuilder
    private func sleepStageBar(minutes: Int, total: Int, color: Color) -> some View {
        let fraction = total > 0 ? CGFloat(minutes) / CGFloat(total) : 0
        Rectangle()
            .fill(color)
            .frame(width: nil)
            .layoutPriority(Double(fraction))
    }

    private func sleepStagePill(color: Color, label: String, minutes: Int) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(label) \(minutes / 60)h\(minutes % 60 > 0 ? " \(minutes % 60)m" : "")")
                .font(.caption2)
                .foregroundColor(AppTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private func sleepDurationFormatted(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        return m > 0 ? "\(h)h \(m)m" : "\(h)h"
    }

    /// Shared time formatter for sleep/wake display.
    static var sleepTimeFormatter: DateFormatter { LocalizedDateFormat.formatter(template: "jmm") }
}
