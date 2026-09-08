import SwiftUI

/// Build plan §3.14 — horizontal-scroll row of last 7 readings on
/// Dashboard. Streak-without-streak retention mechanic (build plan §8.1):
/// shows continuity without grading, miss a day → 6 dots instead of 7,
/// no shame copy.
///
/// First-30-days users see progress dots, not verdicts (verdicts aren't
/// reliable yet). Day-30+ users see full verdicts.
struct RecentStrip: View {
    struct Day: Identifiable, Sendable {
        let id: Date
        let date: Date
        let score: Int?
        let verdict: ScoreVerdict?
    }

    let days: [Day]
    var showVerdicts: Bool = true   // false → progress-dots mode for first-30-days users
    var onTapDay: (Day) -> Void = { _ in }
    var onViewAll: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            recentStripHeader
            recentStripScroll
        }
    }

    private var recentStripHeader: some View {
        HStack {
            Text(String(localized: "Recent", bundle: LanguageManager.appBundle))
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(AppTheme.textSecondary)
                .textCase(.uppercase)
                .tracking(0.5)
            Spacer()
            viewAllButton
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "View all readings", bundle: LanguageManager.appBundle))
                // This button is the only route to History
                // since History is not a tab, so UI tests reach the whole
                // History surface through it (there is no
                // `tabBar.buttons["History"]` in the five-tab IA).
                // Identifier, not label: the label is localized
                // into 16 languages and carries a "▸" glyph.
                .accessibilityIdentifier("dashboard.viewAllReadings")
        }
    }

    private var recentStripScroll: some View {
        ScrollViewReader { proxy in
            recentStripRow
            // Anchor to TODAY's card on the
            // trailing edge so the user sees today + recent on
            // first paint. Not `.onAppear`,
            // which fires before the LazyHStack has finished
            // its first layout pass — `scrollTo` then runs against
            // a zero-width content size and silently no-ops,
            // leaving the strip pinned at the leading edge with
            // older empty days visible and today off-screen.
            // `.task(id:)` fires AFTER first layout commits and
            // the small `Task.sleep(50ms)` yields to the layout
            // engine before the scroll, which lands reliably.
            // Re-fires when `days.count` changes (e.g. archive
            // version bumps inject a new day).
            .task(id: days.count) { await anchorToToday(proxy) }
        }
    }

    /// Every day card is tappable. The host (DashboardV2View)
    /// decides what to do based on the day's state: days with a reading open
    /// detail; today's empty card opens the hero-medallion target (Take a reading
    /// for a fresh day, or Recovery Score detail if today already has a session).
    /// Empty PAST days call `onTapDay` too, where the host can no-op or surface
    /// "no reading" context — but the card visibly responds to the press, so it
    /// is not a dead surface.
    private func dayCard(_ day: Day) -> some View {
        Button { onTapDay(day) } label: { card(for: day) }
            .buttonStyle(.plain)
            .id(day.id)
    }

    private func anchorToToday(_ proxy: ScrollViewProxy) async {
        await sleepQuietly(50_000_000, context: "body")
        guard let last = days.last else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(last.id, anchor: .trailing)
        }
    }

    private var recentStripRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            dayCards
                .padding(.trailing, 4)
        }
        .scrollClipDisabled()
    }

    private var dayCards: some View {
        HStack(spacing: 10) {
            ForEach(days) { dayCard($0) }
        }
    }

    private var viewAllButton: some View {
        Button(action: onViewAll) {
            Text(String(localized: "View all  ▸", bundle: LanguageManager.appBundle))
                .scaledFont(size: 13, weight: .medium)
                .foregroundStyle(AppTheme.primary)
        }
    }

    private func card(for day: Day) -> some View {
        VStack(spacing: 8) {
            Text(verbatim: weekdayLabel(day.date))
                .scaledFont(size: 11, weight: .medium)
                .foregroundStyle(AppTheme.textTertiary)
            dayMarker(for: day)
        }
        .frame(width: 64)
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AppTheme.sectionTint)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: day))
    }

    /// Three states: a verdict dot once scores are meaningful, a plain
    /// progress dot for first-30-days users, and an empty ring for a day with
    /// no reading — no shame copy on that last one.
    @ViewBuilder
    private func dayMarker(for day: Day) -> some View {
        if showVerdicts, let verdict = day.verdict {
            filledDot(verdict.color)
            Text(verbatim: verdict.word)
                .scaledFont(size: 10, weight: .medium)
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        } else if day.score != nil {
            filledDot(AppTheme.wongGood)
            Text(String(localized: "Logged", bundle: LanguageManager.appBundle))
                .scaledFont(size: 10)
                .foregroundStyle(AppTheme.textTertiary)
        } else {
            Circle()
                .stroke(AppTheme.textTertiary.opacity(0.4), lineWidth: 1.4)
                .frame(width: 14, height: 14)
            Text(verbatim: "—")
                .scaledFont(size: 10)
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    private func filledDot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 14, height: 14)
    }

    // Cached; otherwise allocated per day-card per dashboard render.
    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.autoupdatingCurrent
        f.dateFormat = "EEE"
        return f
    }()

    private static let mediumDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    private func weekdayLabel(_ date: Date) -> String {
        Self.weekdayFormatter.string(from: date).uppercased()
    }

    private func accessibilityLabel(for day: Day) -> String {
        let dateString = Self.mediumDateFormatter.string(from: day.date)
        if let v = day.verdict { return "\(dateString), \(v.word)" }
        if day.score != nil { return "\(dateString), reading logged" }
        return "\(dateString), no reading"
    }
}
