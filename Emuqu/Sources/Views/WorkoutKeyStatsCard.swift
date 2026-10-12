import SwiftUI

/// Curated key-stats grid for the post-workout summary — a direct replacement
/// for the previous 15-row dense vertical table. Up to six tiles, each a
/// big-value-on-top / small-label-below pair, three to a row.
///
/// The card renders the `stats` its caller assembles; the summary adds a tile
/// only for a metric the workout recorded (average and peak HR, elevation
/// gain, the training load, the HR load beside a power load, best split), so
/// the grid shrinks to what exists, and the card is not drawn when nothing
/// does.
///
/// Design matches the morning cards: bold-rounded number + caption label +
/// consistent padding + `cornerRadius(16)`.
struct WorkoutKeyStatsCard: View {
    /// Identified by its label (one tile per metric), so a rebuilt array
    /// keeps the same identities and the grid diffs instead of recreating
    /// every tile.
    struct Stat: Identifiable {
        let label: String
        let value: String
        let sub: String?
        let icon: String
        let tint: Color
        var id: String { label }
    }

    let stats: [Stat]

    private static let tileColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    private var tileGrid: some View {
        LazyVGrid(columns: Self.tileColumns, spacing: 12) {
            ForEach(stats) { stat in
                tile(stat)
            }
        }
    }

    @ViewBuilder
    var body: some View {
        if !stats.isEmpty { card }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "AT A GLANCE", bundle: LanguageManager.appBundle))
                .font(.caption.weight(.bold))
                .tracking(1.5)
                .foregroundStyle(AppTheme.textTertiary)

            tileGrid
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    private func tile(_ stat: Stat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            tileHeader(stat)
            Text(stat.value)
                .scaledFont(size: 18, weight: .semibold)
                .monospacedDigit()
                .foregroundStyle(AppTheme.textPrimary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            if let sub = stat.sub {
                Text(sub)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .modifier(TileChrome())
    }

    /// Faint card ground with a hairline border, clipped to the same radius.
    private struct TileChrome: ViewModifier {
        func body(content: Content) -> some View {
            content
                .background(AppTheme.cardBackground.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.gray.opacity(0.18), lineWidth: 0.5)
                )
                .cornerRadius(10)
        }
    }

    private func tileHeader(_ stat: Stat) -> some View {
        HStack(spacing: 4) {
            Image(systemName: stat.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(stat.tint)
            Text(stat.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.textTertiary)
                .lineLimit(1)
        }
    }
}
