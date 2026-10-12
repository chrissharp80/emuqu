import SwiftUI

/// Container for all Swift Charts visualisations.
/// Header (title + optional unit chip) above the chart at a fixed aspect
/// ratio, in a rounded card.
struct ChartCard<Content: View>: View {
    let title: String
    var unitLabel: String?
    var aspectRatio: CGFloat = 16.0 / 9.0
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            titleRow
            chartArea
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(AppTheme.cardBackground)
        )
    }

    private var titleRow: some View {
        HStack {
            Text(verbatim: title)
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            unitChip
        }
    }

    @ViewBuilder
    private var unitChip: some View {
        if let unitLabel {
            Text(verbatim: unitLabel)
                .scaledFont(size: 11, weight: .medium)
                .foregroundStyle(AppTheme.textTertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(AppTheme.sectionTint))
        }
    }

    private var chartArea: some View {
        content()
            .aspectRatio(aspectRatio, contentMode: .fit)
    }
}
