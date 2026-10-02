import SwiftUI

/// Cold-start confidence indicator next to the
/// recovery-score brand label.
///
/// Three states based on days of HRV baseline data collected:
/// - 0–13 days: ●○○ "Building baseline" — absolute thresholds for the first
///   two nights, then z-scored against a short baseline whose spread is
///   widened until seven nights (`BaselineTracker`, `minimumDays` = 3)
/// - 14–27 days: ●●○ "Provisional" — baseline still maturing; tomorrow's
///   reading can shift it more than usual
/// - 28+ days: ●●● "Full algorithm"
///
/// Tapping the pip pops a one-line explanation so users can connect a
/// score reading to the maturity of their data without forcing them
/// into a help page.
struct ConfidencePip: View {
    let daysCollected: Int

    @State private var explanationVisible = false

    private var stage: Stage {
        if daysCollected < 14 { return .cold }
        if daysCollected < 28 { return .provisional }
        return .full
    }

    private enum Stage {
        case cold, provisional, full
    }

    private var pipDots: String {
        switch stage {
        case .cold: return "●○○"
        case .provisional: return "●●○"
        case .full: return "●●●"
        }
    }

    private var labelText: String {
        switch stage {
        case .cold:
            return String(localized: "Building baseline (\(daysCollected)/14)", bundle: LanguageManager.appBundle)
        case .provisional:
            return String(localized: "Provisional baseline (\(daysCollected)/28)", bundle: LanguageManager.appBundle)
        case .full:
            return String(localized: "Full algorithm", bundle: LanguageManager.appBundle)
        }
    }

    private var explanationText: String {
        switch stage {
        case .cold:
            return String(localized: "For your first two nights the score uses general HRV thresholds. From the third night it compares you with your own baseline, cautiously at first, and that baseline keeps settling until about two weeks.", bundle: LanguageManager.appBundle)
        case .provisional:
            return String(localized: "Z-scoring is active but your baseline is still maturing. Tomorrow's reading may shift it noticeably.", bundle: LanguageManager.appBundle)
        case .full:
            return String(localized: "60-day rolling baseline is in place. Score reflects your personal HRV range.", bundle: LanguageManager.appBundle)
        }
    }

    var body: some View {
        Button {
            explanationVisible.toggle()
        } label: {
            bodyLabel
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(labelText)
        .accessibilityHint(String(localized: "Tap for explanation", bundle: LanguageManager.appBundle))
        .popover(isPresented: $explanationVisible, attachmentAnchor: .point(.top), arrowEdge: .bottom) {
            Text(explanationText)
                .font(.callout)
                .padding(14)
                .frame(maxWidth: 280)
                .presentationCompactAdaptation(.popover)
        }
    }

    /// The row is caption-height (~14 pt). Without the `minHeight` the whole
    /// control is a 150 × 14 pt tap target against the 44 pt HIG minimum —
    /// flagged by the accessibility audit on Dashboard.
    private var bodyLabel: some View {
        HStack(spacing: 4) {
            dots
            Text(labelText)
                .font(.caption2)
                .foregroundStyle(AppTheme.textTertiary)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    /// The dots are a redundant visual encoding of `labelText`, which sits
    /// right beside them and says the same thing in words. Exposed, VoiceOver
    /// reads "black circle, white circle, white circle" before the sentence
    /// that explains it, and the audit scores the glyph run as failing text
    /// contrast. Hiding it also satisfies the "never colour alone" rule, since
    /// the words carry the state.
    private var dots: some View {
        Text(pipDots)
            .font(.caption.monospaced())
            .foregroundStyle(stage == .full ? AppTheme.sage : AppTheme.softGold)
            .accessibilityHidden(true)
    }
}
