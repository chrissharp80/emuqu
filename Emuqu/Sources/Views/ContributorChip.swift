import SwiftUI

/// Build plan §3.2 — the contributor chip. Three to four chips below the
/// hero on Dashboard. Reused inside detail views.
///
/// Variants: HRV / Sleep / Vitals / Load. Same layout, different content
/// and accent. The Load chip is **always neutral** (gray-blue) — never
/// red, even for "Detraining" or "Rapid increase." The FDA copy perimeter
/// and the architecture both require load not be framed as a problem
/// (build plan §5.1).
///
/// States:
///   • default          — label, value, optional trend arrow
///   • loading          — skeleton shimmer
///   • buildingBaseline — value "—", subcopy "calibrating"
///   • noData           — value "—", tappable to source-config screen
///   • locked           — paywall lock glyph overlay, value blurred
struct ContributorChip: View {
    enum Variant {
        case hrv(value: String, trend: Trend?)
        case sleep(duration: String, efficiency: String?)
        case vitals(status: VitalsStatus, leadVital: String?)
        case load(verdict: TrajectoryVerdict, subline: String)
    }

    enum Trend {
        case up, flat, down
        var glyph: String {
            switch self {
            case .up: "arrow.up.right"
            case .flat: "arrow.right"
            case .down: "arrow.down.right"
            }
        }
    }

    enum VitalsStatus {
        case normal, watch, elevated
        var word: String {
            switch self {
            case .normal: "Normal"
            case .watch: "Watch"
            case .elevated: "Elevated"
            }
        }
        var color: Color {
            switch self {
            case .normal: AppTheme.wongOptimal
            case .watch: AppTheme.wongCaution
            case .elevated: AppTheme.wongAttention
            }
        }
        var glyph: String {
            switch self {
            case .normal: "checkmark.circle.fill"
            case .watch: "exclamationmark.circle.fill"
            case .elevated: "exclamationmark.triangle.fill"
            }
        }
    }

    enum DisplayState {
        case `default`, loading, buildingBaseline, noData, locked
    }

    let variant: Variant
    var state: DisplayState = .default
    /// Use compact (88×72) for 4-up grid, standard (104×86) for 3-up.
    var compact: Bool = true
    var onTap: () -> Void = {}

    var body: some View {
        Button(action: onTap) { content }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            labelRow
            valueRow
            sublineText
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: compact ? 88 : 104, height: compact ? 72 : 86, alignment: .topLeading)
        .background(chipBackground)
        .overlay(lockOverlay)
        .opacity(state == .locked ? 0.85 : 1.0)
    }

    private var labelRow: some View {
        HStack(spacing: 4) {
            Text(verbatim: label)
                .scaledFont(size: 13, weight: .medium)
                .foregroundStyle(AppTheme.textTertiary)
            Spacer(minLength: 0)
            trendGlyphImage
        }
    }

    @ViewBuilder
    private var trendGlyphImage: some View {
        if let trendGlyph {
            Image(systemName: trendGlyph)
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    @ViewBuilder
    private var sublineText: some View {
        if let subline {
            Text(verbatim: subline)
                .scaledFont(size: 11)
                .foregroundStyle(AppTheme.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private var chipBackground: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(AppTheme.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(accentColor.opacity(0.18), lineWidth: 1)
            )
    }

    private var valueRow: some View {
        HStack(spacing: 4) {
            valueContent
        }
    }

    @ViewBuilder
    private var valueContent: some View {
        switch state {
        case .default: defaultValue
        case .loading, .buildingBaseline: placeholderValue(size: 28)
        case .noData: placeholderValue(size: 22)
        case .locked: lockedValue
        }
    }

    @ViewBuilder
    private var defaultValue: some View {
        if case let .vitals(status, _) = variant {
            vitalsValue(status)
        } else if case let .load(verdict, _) = variant {
            Text(verbatim: verdict.chipLabel)
                .scaledFont(size: 14, weight: .semibold)
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        } else {
            numericValue
        }
    }

    @ViewBuilder
    private func vitalsValue(_ status: VitalsStatus) -> some View {
        Image(systemName: status.glyph)
            .scaledFont(size: 14, weight: .semibold)
            .foregroundStyle(status.color)
        Text(verbatim: status.word)
            .scaledFont(size: 18, weight: .semibold, design: .rounded)
            .foregroundStyle(AppTheme.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    /// BP §3.2 line 258 — 28pt SF Pro Rounded Semibold, monospaced digits.
    /// `minimumScaleFactor` 0.55 lets the value auto-shrink to ~15pt on smaller
    /// phones / larger Dynamic Type so "5h 25m" never truncates while honouring
    /// the 28pt baseline.
    private var numericValue: some View {
        Text(verbatim: primaryValue)
            .scaledFont(size: 28, weight: .semibold, design: .rounded, monospacedDigit: true)
            .foregroundStyle(AppTheme.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.55)
    }

    private func placeholderValue(size: CGFloat) -> some View {
        Text(verbatim: "—")
            .scaledFont(size: size, weight: .semibold, design: .rounded)
            .foregroundStyle(AppTheme.textTertiary)
    }

    private var lockedValue: some View {
        Text(verbatim: primaryValue)
            .scaledFont(size: 22, weight: .semibold, design: .rounded, monospacedDigit: true)
            .foregroundStyle(AppTheme.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .blur(radius: 6)
    }

    @ViewBuilder
    private var lockOverlay: some View {
        if state == .locked {
            Image(systemName: "lock.fill")
                .scaledFont(size: 14, weight: .semibold)
                .foregroundStyle(AppTheme.textSecondary)
                .padding(6)
                .background(Circle().fill(AppTheme.cardElevated))
                .offset(x: 30, y: -22)
        }
    }

    // MARK: - Variant accessors

    private var label: String {
        switch variant {
        case .hrv: "HRV"
        case .sleep: "Sleep"
        case .vitals: "Vitals"
        case .load: "Load"
        }
    }

    private var primaryValue: String {
        switch variant {
        case let .hrv(value, _): value
        case let .sleep(duration, _): duration
        case let .vitals(status, _): status.word
        case let .load(verdict, _): verdict.chipLabel
        }
    }

    private var subline: String? {
        switch state {
        case .buildingBaseline: "calibrating"
        case .noData: "tap to set up"
        case .loading: nil
        case .locked, .default: variantSubline
        }
    }

    private var variantSubline: String? {
        switch variant {
        case let .hrv(_, trend): trend.map { trendSubline($0) }
        case let .sleep(_, eff): eff.map { "Eff \($0)" }
        case let .vitals(_, lead): lead
        case let .load(_, sub): sub
        }
    }

    private func trendSubline(_ trend: Trend) -> String {
        switch trend {
        case .up: "Above baseline"
        case .flat: "At baseline"
        case .down: "Below baseline"
        }
    }

    private var trendGlyph: String? {
        if case let .hrv(_, trend) = variant, let trend { return trend.glyph }
        return nil
    }

    private var accentColor: Color {
        switch variant {
        case .hrv: AppTheme.primary
        case .sleep: AppTheme.primaryLight
        case let .vitals(status, _): status.color
        case .load:
            // ALWAYS NEUTRAL — never red, even for Detraining or Rapid
            // increase. Build plan §5.1.
            AppTheme.textSecondary
        }
    }

    private var accessibilityLabel: String {
        switch variant {
        case let .hrv(value, trend):
            "HRV \(value), \(trend.map { Self.trendPhrase($0) } ?? "")"
        case let .sleep(duration, eff):
            "Sleep \(duration)\(eff.map { ", efficiency \($0)" } ?? "")"
        case let .vitals(status, lead):
            "Vitals \(status.word)\(lead.map { ", \($0)" } ?? "")"
        case let .load(verdict, sub):
            "Load: \(verdict.accessibilityLabel) \(sub)"
        }
    }

    private static func trendPhrase(_ trend: Trend) -> String {
        switch trend {
        case .up: "above baseline"
        case .flat: "at baseline"
        case .down: "below baseline"
        }
    }
}
