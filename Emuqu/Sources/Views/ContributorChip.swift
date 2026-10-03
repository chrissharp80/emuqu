import SwiftUI

/// The contributor chip. Three to four chips below the
/// hero on Dashboard. Reused inside detail views.
///
/// Variants: HRV / Sleep / Vitals / Load. Same layout, different content
/// and accent. The Load chip is **always neutral** (gray-blue) — never
/// red, even for "Detraining" or "Rapid increase." The FDA copy perimeter
/// and the architecture both require load not be framed as a problem.
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
            case .normal: String(localized: "Normal", bundle: LanguageManager.appBundle)
            case .watch: String(localized: "Watch", bundle: LanguageManager.appBundle)
            case .elevated: String(localized: "Elevated", bundle: LanguageManager.appBundle)
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
    /// Use compact (72pt tall) for the 4-up row, standard (86pt) for 3-up.
    /// Width is flexible: the row shares the screen between its chips.
    /// Fixed 88pt chips needed 412pt for four, wider than a 375, 393 or
    /// 402pt iPhone, and the row ran off the screen edge.
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
        .frame(
            minWidth: 0, idealWidth: compact ? 88 : 104, maxWidth: .infinity,
            minHeight: compact ? 72 : 86, maxHeight: compact ? 72 : 86, alignment: .topLeading
        )
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
            Text(verbatim: verdict.localizedChipLabel)
                .scaledFont(size: 14, weight: .semibold)
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        } else {
            numericValue
        }
    }

    @ViewBuilder
    private func vitalsValue(_ status: VitalsStatus) -> some View {
        Image(systemName: status.glyph)
            .scaledFont(size: 14, weight: .semibold)
            .foregroundStyle(status.color)
        // Shrinks further than the other values: on a 390pt iPhone the chip
        // is about 78pt wide, and "Normal" at 0.7 still truncated to "Nor…".
        Text(verbatim: status.word)
            .scaledFont(size: 18, weight: .semibold, design: .rounded)
            .foregroundStyle(AppTheme.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }

    /// 28pt SF Pro Rounded Semibold, monospaced digits.
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
        case .hrv: String(localized: "HRV", bundle: LanguageManager.appBundle)
        case .sleep: String(localized: "Sleep", bundle: LanguageManager.appBundle)
        case .vitals: String(localized: "Vitals", bundle: LanguageManager.appBundle)
        case .load: String(localized: "Load", bundle: LanguageManager.appBundle)
        }
    }

    private var primaryValue: String {
        switch variant {
        case let .hrv(value, _): value
        case let .sleep(duration, _): duration
        case let .vitals(status, _): status.word
        case let .load(verdict, _): verdict.localizedChipLabel
        }
    }

    private var subline: String? {
        switch state {
        case .buildingBaseline: String(localized: "calibrating", bundle: LanguageManager.appBundle)
        case .noData: String(localized: "tap to set up", bundle: LanguageManager.appBundle)
        case .loading: nil
        case .locked, .default: variantSubline
        }
    }

    private var variantSubline: String? {
        switch variant {
        case let .hrv(_, trend): trend.map { trendSubline($0) }
        case let .sleep(_, eff): eff.map { String(localized: "Eff \($0)", bundle: LanguageManager.appBundle) }
        case let .vitals(_, lead): lead
        case let .load(_, sub): sub
        }
    }

    private func trendSubline(_ trend: Trend) -> String {
        switch trend {
        case .up: String(localized: "Above baseline", bundle: LanguageManager.appBundle)
        case .flat: String(localized: "At baseline", bundle: LanguageManager.appBundle)
        case .down: String(localized: "Below baseline", bundle: LanguageManager.appBundle)
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
            // increase.
            AppTheme.textSecondary
        }
    }

    /// Follows the display state: placeholder states read their placeholder,
    /// and a locked chip never reads the value it blurs.
    private var accessibilityLabel: String {
        let bundle = LanguageManager.appBundle
        switch state {
        case .default: return variantAccessibilityLabel
        case .loading: return "\(label), \(String(localized: "Loading...", bundle: bundle))"
        case .buildingBaseline: return "\(label), \(String(localized: "calibrating", bundle: bundle))"
        case .noData:
            return [label, String(localized: "No data", bundle: bundle), String(localized: "tap to set up", bundle: bundle)]
                .joined(separator: ", ")
        case .locked: return "\(label), \(String(localized: "Locked", bundle: bundle))"
        }
    }

    private var variantAccessibilityLabel: String {
        switch variant {
        case let .hrv(value, trend):
            [label, value, trend.map { Self.trendPhrase($0) }].compactMap { $0 }.joined(separator: ", ")
        case let .sleep(duration, eff):
            [label, duration, eff.map { String(localized: "efficiency \($0)", bundle: LanguageManager.appBundle) }]
                .compactMap { $0 }.joined(separator: ", ")
        case let .vitals(status, lead):
            [label, status.word, lead].compactMap { $0 }.joined(separator: ", ")
        case let .load(verdict, sub):
            [label, verdict.localizedAccessibilityLabel, sub].joined(separator: ", ")
        }
    }

    private static func trendPhrase(_ trend: Trend) -> String {
        switch trend {
        case .up: String(localized: "above baseline", bundle: LanguageManager.appBundle)
        case .flat: String(localized: "at baseline", bundle: LanguageManager.appBundle)
        case .down: String(localized: "below baseline", bundle: LanguageManager.appBundle)
        }
    }
}
