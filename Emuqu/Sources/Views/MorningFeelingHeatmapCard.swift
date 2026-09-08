import SwiftUI

/// 30-day calendar heatmap of morning feelings.
/// Each day is a colored square matching the 5-point scale; empty days are
/// a neutral gray. Optional divergence dot marks days where the feeling
/// disagreed with HRV by more than ~1 category (possible signal for
/// non-autonomic stressors).
///
/// Design rationale: this is the Daylio / Bearable pattern — the most
/// legible way to see a 1–5 scale over 30 days at a glance. Alternatives
/// (overlay on HRV chart, line chart) either conflate signals (Welltory
/// failure) or waste the low-precision discrete scale.
struct MorningFeelingHeatmapCard: View {
    /// Chronologically-sorted data points (ascending date).
    let dataPoints: [TrendAnalyzer.TrendDataPoint]

    /// Cluster filter: when .all, every answered day renders in color. When
    /// .body or .mind, only days tagged with at least one tag in that cluster
    /// render in color; other days dim to show the overall pattern.
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable {
        case all = "All"
        case body = "Body"
        case mind = "Mind"

        var cluster: MorningFeelingTag.Cluster? {
            switch self {
            case .all: nil
            case .body: .body
            case .mind: .mind
            }
        }

        var localizedLabel: String {
            switch self {
            case .all: String(localized: "All", bundle: LanguageManager.appBundle)
            case .body: String(localized: "Body", bundle: LanguageManager.appBundle)
            case .mind: String(localized: "Mind", bundle: LanguageManager.appBundle)
            }
        }
    }

    private struct DayCell: Identifiable {
        let id = UUID()
        let date: Date
        let feeling: Int?
        let tags: [MorningFeelingTag]
        let isDiverged: Bool
        /// When a filter is active, true = matches filter (render in color),
        /// false = doesn't match (render dimmed).
        let matchesFilter: Bool
    }

    /// Thirty trailing days aligned to today.
    private var days: [DayCell] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let byDay: [Date: TrendAnalyzer.TrendDataPoint] = Dictionary(
            dataPoints.map { (calendar.startOfDay(for: $0.date), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let tertiles = hrvTertiles(calendar: calendar, today: today)
        return (0 ..< 30).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return dayCell(for: date, calendar: calendar, byDay: byDay, tertiles: tertiles)
        }
    }

    /// HRV tertile thresholds over the visible 30-day window, used to spot a
    /// feeling that diverges from the physiology.
    ///
    /// Bind the 30-days-ago threshold once with a safe fallback (to
    /// `today`, so the filter degrades to "all points through today" instead of
    /// crashing on a Calendar nil).
    private func hrvTertiles(calendar: Calendar, today: Date) -> (low: Double?, high: Double?) {
        let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: today) ?? today
        let rmssds = dataPoints
            .filter { calendar.startOfDay(for: $0.date) >= thirtyDaysAgo }
            .map(\.rmssd)
            .sorted()
        return (percentile(rmssds, 1.0 / 3.0), percentile(rmssds, 2.0 / 3.0))
    }

    private func dayCell(
        for date: Date,
        calendar: Calendar,
        byDay: [Date: TrendAnalyzer.TrendDataPoint],
        tertiles: (low: Double?, high: Double?)
    ) -> DayCell {
        let point = byDay[calendar.startOfDay(for: date)]
        let feeling = point?.morningFeeling
        let tags = point?.morningFeelingTags ?? []
        let matches = matchesActiveFilter(feeling: feeling, tags: tags)
        return DayCell(
            date: date,
            feeling: feeling,
            tags: tags,
            isDiverged: diverges(point: point, feeling: feeling, tertiles: tertiles)
                && (filter.cluster == nil || matches),
            matchesFilter: matches
        )
    }

    /// A low feeling on a high-HRV day (or the reverse) is worth flagging: the
    /// user's sense of the morning and their physiology disagree.
    private func diverges(
        point: TrendAnalyzer.TrendDataPoint?,
        feeling: Int?,
        tertiles: (low: Double?, high: Double?)
    ) -> Bool {
        guard let point, let feeling, let low = tertiles.low, let high = tertiles.high else { return false }
        if feeling <= 2, point.rmssd >= high { return true }
        if feeling >= 4, point.rmssd <= low { return true }
        return false
    }

    /// No filter = match if the day was answered at all; otherwise a match
    /// requires at least one tag in the active cluster.
    private func matchesActiveFilter(feeling: Int?, tags: [MorningFeelingTag]) -> Bool {
        guard let cluster = filter.cluster else { return feeling != nil }
        return tags.contains { $0.cluster == cluster }
    }

    private var answeredCount: Int {
        days.filter { $0.feeling != nil }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            heatmapHeader
            clusterFilterControl
            heatmapGrid
            legend
            divergenceNote
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(12)
    }

    private var filterPicker: some View {
        Picker(String(localized: "Filter", bundle: LanguageManager.appBundle), selection: $filter) {
            ForEach(Filter.allCases, id: \.self) { option in
                Text(option.localizedLabel).tag(option)
            }
        }
    }

    @ViewBuilder
    private func dayCell(_ day: DayCell) -> some View {
        let isToday = Calendar.current.isDateInToday(day.date)
        ZStack(alignment: .topTrailing) {
            dayTile(day, isToday: isToday)
            if day.isDiverged {
                // Amber dot: HRV/feeling divergence on this day
                Circle()
                    .fill(Color.orange)
                    .frame(width: 5, height: 5)
                    .padding(2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: day, isToday: isToday))
        .accessibilityAddTraits(isToday ? [.isStaticText, .isHeader] : .isStaticText)
    }

    /// Days that fall outside the active filter stay visible but recede, so the
    /// shape of the month is never lost when the user narrows the view.
    private func dayTile(_ day: DayCell, isToday: Bool) -> some View {
        let dim = filter != .all && !day.matchesFilter
        let fillOpacity: Double = day.feeling != nil ? (dim ? 0.15 : 0.75) : 0.12
        return RoundedRectangle(cornerRadius: 4)
            .fill(
                day.feeling.map { MorningFeelingDisplay.color(for: $0).opacity(fillOpacity) }
                    ?? AppTheme.textTertiary.opacity(0.12)
            )
            .aspectRatio(1, contentMode: .fit)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isToday ? AppTheme.textPrimary : Color.clear, lineWidth: isToday ? 1.5 : 0)
            )
            .overlay(dayEmoji(day, dim: dim))
    }

    @ViewBuilder
    private func dayEmoji(_ day: DayCell, dim: Bool) -> some View {
        if let feeling = day.feeling {
            Text(MorningFeelingDisplay.emoji(for: feeling))
                .font(.caption)
                .opacity(dim ? 0.35 : 1.0)
        }
    }

    private func accessibilityLabel(for day: DayCell, isToday: Bool) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let dateString = isToday ? "Today, \(formatter.string(from: day.date))" : formatter.string(from: day.date)

        let feelingPart: String
        if let feeling = day.feeling {
            feelingPart = "feeling \(MorningFeelingDisplay.label(for: feeling)) (\(feeling) of 5)"
        } else {
            feelingPart = "no reading"
        }

        let divergencePart = day.isDiverged
            ? ". Subjective feeling diverges from HRV that day."
            : ""

        return "\(dateString), \(feelingPart)\(divergencePart)"
    }

    private var heatmapHeader: some View {
        HStack {
            Text(String(localized: "How You Felt", bundle: LanguageManager.appBundle))
                .font(.headline)
            Spacer()
            Text(String(localized: "\(answeredCount)/30 days", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    /// Only shown if at least one day has tags, so the segmented control isn't a
    /// dead UI for users who never tag.
    @ViewBuilder
    private var clusterFilterControl: some View {
        if dataPoints.contains(where: { !($0.morningFeelingTags ?? []).isEmpty }) {
            filterPicker
                .pickerStyle(.segmented)
        }
    }

    /// 10 columns × 3 rows = 30 days.
    private var heatmapGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 10), spacing: 6) {
            ForEach(days) { dayCell($0) }
        }
    }

    @ViewBuilder
    private var divergenceNote: some View {
        if days.contains(where: \.isDiverged) {
            divergenceHint
        }
    }

    private var legend: some View {
        HStack(spacing: 8) {
            ForEach(1 ... 5, id: \.self) { legendSwatch($0) }
            Spacer()
        }
    }

    private func legendSwatch(_ value: Int) -> some View {
        HStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 2)
                .fill(MorningFeelingDisplay.color(for: value).opacity(0.75))
                .frame(width: 10, height: 10)
            Text(MorningFeelingDisplay.label(for: value))
                .font(.caption2)
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    private var divergenceHint: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.orange)
                .frame(width: 5, height: 5)
            Text(String(localized: "Days where your feeling disagreed with your HRV \u{2014} worth reflecting on", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    /// Compute the value at a given percentile (0.0–1.0) of a sorted array.
    /// Returns nil if the array is empty.
    private func percentile(_ sorted: [Double], _ p: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let idx = Int((p * Double(sorted.count - 1)).rounded())
        return sorted[max(0, min(sorted.count - 1, idx))]
    }
}
