import SwiftUI

/// Container for all Swift Charts visualisations.
/// Header (title + optional unit chip), chart at fixed aspect ratio,
/// optional legend below, supports loading / building-baseline / no-data /
/// interactive states.
struct ChartCard<Content: View>: View {
    let title: String
    var unitLabel: String?
    var aspectRatio: CGFloat = 16.0 / 9.0
    var state: DisplayState = .default
    @ViewBuilder let content: () -> Content
    var legend: AnyView?

    enum DisplayState {
        case `default`
        case loading
        case buildingBaseline(message: String)
        case noData(message: String, ctaLabel: String?, onTap: () -> Void)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            titleRow
            chartArea
            if let legend {
                legend
            }
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

    @ViewBuilder
    private var chartArea: some View {
        switch state {
        case .default:
            content()
                .aspectRatio(aspectRatio, contentMode: .fit)
        case .loading:
            RoundedRectangle(cornerRadius: 8)
                .fill(AppTheme.textTertiary.opacity(0.12))
                .aspectRatio(aspectRatio, contentMode: .fit)
        case let .buildingBaseline(message):
            baselineOverlay(message)
        case let .noData(message, ctaLabel, onTap):
            emptyState(message, ctaLabel: ctaLabel, onTap: onTap)
        }
    }

    private func baselineOverlay(_ message: String) -> some View {
        ZStack {
            content()
                .aspectRatio(aspectRatio, contentMode: .fit)
                .opacity(0.35)
            Text(verbatim: message)
                .scaledFont(size: 13)
                .foregroundStyle(AppTheme.textSecondary)
                .padding(8)
                .background(Capsule().fill(AppTheme.cardBackground.opacity(0.85)))
        }
    }

    private func emptyState(_ message: String, ctaLabel: String?, onTap: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Text(verbatim: message)
                .scaledFont(size: 14)
                .foregroundStyle(AppTheme.textSecondary)
            ctaButton(ctaLabel, onTap: onTap)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(aspectRatio, contentMode: .fit)
    }

    @ViewBuilder
    private func ctaButton(_ ctaLabel: String?, onTap: @escaping () -> Void) -> some View {
        if let ctaLabel {
            Button(action: onTap) {
                Text(verbatim: ctaLabel)
                    .scaledFont(size: 13, weight: .semibold)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(AppTheme.primary.opacity(0.15)))
                    .foregroundStyle(AppTheme.primary)
            }
            .buttonStyle(.plain)
        }
    }
}
