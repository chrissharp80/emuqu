import SwiftUI

// Rows and text styles the V2 detail pages share (recovery score, workout
// summary, sleep, HRV, trends). The pages differ only in how they size the
// font — some through `scaledFont`, some through their own `@ScaledMetric` —
// so the shared part is everything after the font.

extension View {
    /// The uppercase, tracked, secondary-coloured section heading every V2
    /// detail page uses. Apply after the page's own font modifier.
    func detailSectionHeadingStyle() -> some View {
        foregroundStyle(AppTheme.textSecondary)
            .textCase(.uppercase)
            .tracking(0.5)
    }
}

/// A label on the left, a monospaced-digit value on the right.
struct DetailLabelValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(verbatim: label)
                .scaledFont(size: 13)
                .foregroundStyle(AppTheme.textTertiary)
            Spacer()
            Text(verbatim: value)
                .scaledFont(size: 13, weight: .medium, monospacedDigit: true)
                .foregroundStyle(AppTheme.textPrimary)
        }
    }
}

/// One bulleted insight sentence. `fontSize` is the page's scaled 14 pt
/// metric so the row grows with the page's Dynamic Type setting.
struct InsightBulletRow: View {
    let text: String
    let fontSize: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(AppTheme.wongGood).frame(width: 6, height: 6).padding(.top, 7)
            Text(verbatim: text)
                .font(.system(size: fontSize))
                .foregroundStyle(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
