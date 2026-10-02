import SwiftUI

/// Real monthly calendar tied to the user's history.
/// Unlike a 30-day heatmap with
/// dead taps and no totals, this surface has:
///   • Sun–Sat columns, real month grid
///   • Swipe / chevrons to scrub back to any month with data
///   • Each cell shows the day's preferred LOAD (powerTSS →
///     hrTSS → METs → luciaTRIMP → route-history, per the
///     resolver in WorkoutMetadata.preferredTrainingLoad)
///   • Weekly totals to the right of every row
///   • Monthly total + session count in the header
///   • Tap a day with sessions → DaySummarySheet listing each
///     session's headline numbers; tap a row to open the full
///     session detail (RecoveryScoreDetailView for overnight,
///     FitnessPostSummaryView for workouts)
///
/// Data sources:
///   • `allSessions` — the lightweight session snapshot the
///     Trends tab already maintains. No re-fetching.
///   • `archiveSignal` — refreshes when any surface mutates
///     the archive so the calendar stays in sync.
@MainActor
struct HistoryCalendarView: View {
    let allSessions: [HRVSession]
    /// Delete a session from the day-summary sheet. The calendar and its day
    /// sheet were the surface a user was looking at when they hit a bogus
    /// reading with "no way to delete" — swipe-to-delete only existed on the
    /// flat History list, and worse, a same-night collapse could hide the row
    /// there entirely. Plumbed from `TrendsV2View`, which owns the collector.
    var onDelete: (HRVSession) -> Void = { _ in }

    @State private var visibleMonth: Date = HistoryCalendarView.startOfMonth(Date())
    @State private var selectedDaySheet: DaySheetIdentity?

    // Memoized calendar grid + month stats. Without
    // these, `var monthGrid` and `var monthHeader` would recompute
    // `monthWeeks()` and `monthStats` on every SwiftUI body invalidation
    // (every parent-view recompose, scroll, archive bump). For a user
    // with hundreds of overnight sessions, each rebuild walked all
    // sessions twice (`filter` for the month + the `Dictionary(grouping:)`
    // by start-of-day) and re-allocated 42 DayCell objects. Now rebuilt
    // only when `visibleMonth` or `allSessions` actually change.
    @State private var memoizedWeeks: [WeekRow] = []
    @State private var memoizedMonthStats: MonthStats = MonthStats(totalLoad: 0, sessionCount: 0)
    @State private var memoFingerprint: String = ""

    private static let weekdaySymbols: [String] = ["S", "M", "T", "W", "T", "F", "S"]

    // MARK: - Body

    var body: some View {
        withMonthSwipe(calendarCard)
    }

    @ViewBuilder
    private var calendarCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader
            monthHeader
            weekdayRow
            monthGrid
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(AppTheme.cardBackground)
        )
        .sheet(item: $selectedDaySheet) { item in
            DaySummarySheet(date: item.date, sessions: item.sessions, onDelete: onDelete)
        }
        .onAppear { rebuildMemoIfNeeded() }
        .onChange(of: visibleMonth) { _, _ in rebuildMemoIfNeeded() }
        .onChange(of: allSessions.count) { _, _ in rebuildMemoIfNeeded() }
    }

    /// Horizontal swipe changes months. The chevrons stay for
    /// users who do not discover the gesture. The 80 pt threshold is roomy
    /// enough not to fight a vertical scroll intent from the outer ScrollView.
    private func withMonthSwipe(_ content: some View) -> some View {
        content
            .gesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        guard abs(value.translation.width) > 80,
                              abs(value.translation.width) > abs(value.translation.height) * 2
                        else { return }
                        if value.translation.width < 0 {
                            stepMonth(by: 1)
                        } else {
                            stepMonth(by: -1)
                        }
                    }
            )
    }

    /// Rebuild the cached calendar grid + month stats when the fingerprint
    /// (visible-month + session count) changes.
    private func rebuildMemoIfNeeded() {
        let fingerprint = "\(Int(visibleMonth.timeIntervalSinceReferenceDate))-\(allSessions.count)"
        guard fingerprint != memoFingerprint else { return }
        memoFingerprint = fingerprint
        memoizedWeeks = monthWeeks()
        memoizedMonthStats = monthStats
    }

    // MARK: - Section header

    private var sectionHeader: some View {
        HStack {
            Image(systemName: "calendar")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.primary)
            Text(verbatim: String(localized: "History", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            Text(verbatim: String(localized: "Tap a day for sessions", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    // MARK: - Month header

    private var monthHeader: some View {
        let stats = memoizedMonthStats
        return HStack(spacing: 12) {
            previousMonthButton

            monthTitleBlock(stats)

            nextMonthButton
        }
    }

    private var nextMonthButton: some View {
        Button {
            stepMonth(by: 1)
        } label: {
            Image(systemName: "chevron.right")
                .font(.body.weight(.semibold))
                .foregroundStyle(canStepForward ? AppTheme.textPrimary : AppTheme.textTertiary.opacity(0.4))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .disabled(!canStepForward)
        .accessibilityLabel(String(localized: "Next month", bundle: LanguageManager.appBundle))
    }

    private func monthTitleBlock(_ stats: MonthStats) -> some View {
        VStack(spacing: 2) {
            Text(verbatim: monthTitle(visibleMonth))
                .font(.headline)
                .foregroundStyle(AppTheme.textPrimary)
            if stats.sessionCount > 0 {
                Text(verbatim: String(localized: "\(Int(stats.totalLoad.rounded())) LOAD", bundle: LanguageManager.appBundle) + " · "
                    + String(localized: "\(stats.sessionCount) sessions", bundle: LanguageManager.appBundle))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(AppTheme.textSecondary)
            } else {
                Text(verbatim: String(localized: "No sessions", bundle: LanguageManager.appBundle))
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var previousMonthButton: some View {
        Button {
            stepMonth(by: -1)
        } label: {
            Image(systemName: "chevron.left")
                .font(.body.weight(.semibold))
                .foregroundStyle(canStepBack ? AppTheme.textPrimary : AppTheme.textTertiary.opacity(0.4))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .disabled(!canStepBack)
        .accessibilityLabel(String(localized: "Previous month", bundle: LanguageManager.appBundle))
    }

    // MARK: - Weekday header row

    private var weekdayRow: some View {
        // 8 columns: Sun–Sat (7) + weekly total label (1)
        let cols = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        return HStack(spacing: 4) {
            weekdaySymbolGrid(cols)
            // Weekly-total column header
            Text(verbatim: String(localized: "Wk", bundle: LanguageManager.appBundle))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.textTertiary)
                .frame(width: 40)
                .padding(.vertical, 4)
        }
    }

    private func weekdaySymbolGrid(_ cols: [GridItem]) -> some View {
        LazyVGrid(columns: cols, spacing: 0) {
            weekdaySymbolCells
        }
    }

    private var weekdaySymbolCells: some View {
        ForEach(0 ..< 7, id: \.self) { i in
            Text(verbatim: Self.weekdaySymbols[i])
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
    }

    // MARK: - Month grid

    private var monthGrid: some View {
        let weeks = memoizedWeeks
        let dayCols = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        return VStack(spacing: 4) {
            weekRows(weeks, dayCols: dayCols)
        }
    }

    private func weekRows(_ weeks: [WeekRow], dayCols: [GridItem]) -> some View {
        ForEach(weeks, id: \.weekStart) { week in
            weekRow(week, dayCols: dayCols)
        }
    }

    private func weekRow(_ week: WeekRow, dayCols: [GridItem]) -> some View {
        HStack(spacing: 4) {
            dayCells(week, dayCols: dayCols)
            weeklyTotalCell(week.totalLoad)
        }
    }

    private func dayCells(_ week: WeekRow, dayCols: [GridItem]) -> some View {
        LazyVGrid(columns: dayCols, spacing: 0) {
            dayCellRow(week)
        }
    }

    private func dayCellRow(_ week: WeekRow) -> some View {
        ForEach(week.days, id: \.date) { day in
            dayCell(day)
        }
    }

    /// Consolidated calendar: the cell carries BOTH objective load
    /// and subjective feeling, rather than a tiny load-only
    /// calendar AND a separate big non-interactive "how you felt" heatmap.
    /// Load fills the cell (intensity by colour), morning feeling shows as
    /// a small dot in the top-right corner. One calendar. Tappable. Both
    /// signals.
    private func dayCell(_ day: DayCell) -> some View {
        Button {
            guard !day.sessions.isEmpty else { return }
            selectedDaySheet = DaySheetIdentity(date: day.date, sessions: day.sessions)
        } label: {
            ZStack(alignment: .topTrailing) {
                dayCellTile(day)
                feelingDot(day)
            }
        }
        .buttonStyle(.plain)
        .disabled(day.sessions.isEmpty)
        .accessibilityLabel(accessibilityLabel(for: day))
    }

    private func dayCellTile(_ day: DayCell) -> some View {
        let isToday = Calendar.current.isDateInToday(day.date)
        return VStack(spacing: 3) {
            Text(verbatim: "\(Calendar.current.component(.day, from: day.date))")
                .scaledFont(size: 13, weight: isToday ? .bold : .semibold)
                .foregroundStyle(dayNumberColor(inMonth: day.inVisibleMonth, isToday: isToday))
            loadNumber(day)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(cellBackground(for: day.totalLoad, inMonth: day.inVisibleMonth))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(isToday ? AppTheme.primary : .clear, lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder
    private func loadNumber(_ day: DayCell) -> some View {
        if day.totalLoad > 0 {
            Text(verbatim: "\(Int(day.totalLoad.rounded()))")
                .scaledFont(size: 11, weight: .semibold, monospacedDigit: true)
                .foregroundStyle(loadNumberColor(load: day.totalLoad, inMonth: day.inVisibleMonth))
        } else {
            Spacer().frame(height: 14)
        }
    }

    @ViewBuilder
    private func feelingDot(_ day: DayCell) -> some View {
        if let feelingTint = HistoryCalendarView.feelingColor(day.morningFeeling), day.inVisibleMonth {
            Circle()
                .fill(feelingTint)
                .frame(width: 8, height: 8)
                .padding(4)
        }
    }

    /// Color for the morning-feeling dot, on the
    /// scale the "how you felt" heatmap used so the user's mental
    /// model carries over: green = great, amber = neutral,
    /// red = struggling. Nil → no dot (no rating logged that day).
    private static func feelingColor(_ feeling: Int?) -> Color? {
        guard let f = feeling else { return nil }
        switch f {
        case 5: return AppTheme.wongOptimal
        case 4: return AppTheme.wongOptimal.opacity(0.7)
        case 3: return AppTheme.wongGood
        case 2: return AppTheme.wongCaution
        case 1: return AppTheme.wongAttention
        default: return nil
        }
    }

    private func weeklyTotalCell(_ total: Double) -> some View {
        VStack(spacing: 0) {
            if total > 0 {
                Text(verbatim: "\(Int(total.rounded()))")
                    .scaledFont(size: 11, weight: .semibold, monospacedDigit: true)
                    .foregroundStyle(AppTheme.textSecondary)
            } else {
                Text(verbatim: "—")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textTertiary.opacity(0.5))
            }
        }
        .frame(width: 40, height: 40)
        .background(AppTheme.sectionTint.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Styling

    private func cellBackground(for load: Double, inMonth: Bool) -> Color {
        if !inMonth { return AppTheme.sectionTint.opacity(0.15) }
        // Load tiers calibrated against the TSS scale (100 = 1 hr at
        // threshold). Easy/moderate/hard/very-hard.
        switch load {
        case 0:        return AppTheme.sectionTint.opacity(0.3)
        case ..<25:    return AppTheme.primary.opacity(0.12)
        case 25..<55:  return AppTheme.primary.opacity(0.28)
        case 55..<90:  return AppTheme.warning.opacity(0.35)
        default:       return AppTheme.alert.opacity(0.40)
        }
    }

    private func dayNumberColor(inMonth: Bool, isToday: Bool) -> Color {
        if !inMonth { return AppTheme.textTertiary.opacity(0.5) }
        if isToday { return AppTheme.primary }
        return AppTheme.textPrimary
    }

    private func loadNumberColor(load: Double, inMonth: Bool) -> Color {
        if !inMonth { return AppTheme.textTertiary.opacity(0.5) }
        return AppTheme.textSecondary
    }

    // MARK: - Data assembly

    private struct DayCell {
        let date: Date
        let inVisibleMonth: Bool
        let totalLoad: Double
        let sessions: [HRVSession]
        /// Morning-feeling rating (1–5) for the overnight
        /// session that ANCHORS this calendar day, or nil when no
        /// overnight session was logged that day. Drives the small
        /// colored dot in the top-right corner of the cell so the
        /// calendar carries both objective load (cell fill) and
        /// subjective feeling (corner dot) without the user needing
        /// to scroll between two surfaces.
        let morningFeeling: Int?
    }

    private struct WeekRow {
        let weekStart: Date
        let days: [DayCell]
        let totalLoad: Double
    }

    private struct MonthStats {
        let totalLoad: Double
        let sessionCount: Int
    }

    private var monthStats: MonthStats {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: visibleMonth)
        let sessionsInMonth = allSessions.filter { session in
            let sc = cal.dateComponents([.year, .month], from: session.startDate)
            return sc.year == comps.year && sc.month == comps.month
        }
        let total = sessionsInMonth.reduce(0.0) { acc, s in
            acc + (s.workoutMetadata?.preferredTrainingLoad?.value ?? 0)
        }
        return MonthStats(totalLoad: total, sessionCount: sessionsInMonth.count)
    }

    private func monthWeeks() -> [WeekRow] {
        let cal = Calendar.current
        let monthStart = visibleMonth
        let comps = cal.dateComponents([.year, .month], from: monthStart)
        let trimmed = Self.gridCells(cal: cal, monthStart: monthStart, comps: comps)
        // Group sessions by day for O(1) lookup as we build cells.
        let sessionsByDay: [Date: [HRVSession]] = Dictionary(
            grouping: allSessions,
            by: { cal.startOfDay(for: $0.startDate) }
        )
        var weeks: [WeekRow] = []
        for weekIdx in stride(from: 0, to: trimmed.count, by: 7) {
            let weekDates = Array(trimmed[weekIdx ..< min(weekIdx + 7, trimmed.count)])
            weeks.append(weekRow(dates: weekDates, cal: cal, comps: comps, sessionsByDay: sessionsByDay, monthStart: monthStart))
        }
        return weeks
    }

    /// 42 cells (6 weeks × 7 days) — common upper bound; trailing rows that
    /// contain no in-month day are dropped so the grid doesn't show a phantom
    /// 6th week of next-month dates.
    private static func gridCells(cal: Calendar, monthStart: Date, comps: DateComponents) -> [Date] {
        let range = cal.range(of: .day, in: .month, for: monthStart) ?? 1 ..< 32
        let leading = cal.component(.weekday, from: monthStart) - 1 // 1 = Sunday
        var cells: [Date] = []
        for offset in -leading ..< range.count {
            if let d = cal.date(byAdding: .day, value: offset, to: monthStart) {
                cells.append(d)
            }
        }
        // Pad to a multiple of 7 to fill the trailing row.
        while cells.count % 7 != 0 {
            guard let last = cells.last, let next = cal.date(byAdding: .day, value: 1, to: last) else { break }
            cells.append(next)
        }
        return trimTrailingOutOfMonthRows(cells, cal: cal, comps: comps)
    }

    private static func trimTrailingOutOfMonthRows(_ cells: [Date], cal: Calendar, comps: DateComponents) -> [Date] {
        var result = cells
        while result.count >= 7 {
            let anyInMonth = result.suffix(7).contains { isIn(month: comps, date: $0, cal: cal) }
            if anyInMonth { break }
            result.removeLast(7)
        }
        return result
    }

    private static func isIn(month comps: DateComponents, date: Date, cal: Calendar) -> Bool {
        let dc = cal.dateComponents([.year, .month], from: date)
        return dc.year == comps.year && dc.month == comps.month
    }

    private func weekRow(dates: [Date], cal: Calendar, comps: DateComponents, sessionsByDay: [Date: [HRVSession]], monthStart: Date) -> WeekRow {
        var weekDays: [DayCell] = []
        var weekTotal: Double = 0
        for date in dates {
            let day = cal.startOfDay(for: date)
            let cell = Self.dayCellFor(day: day, inMonth: Self.isIn(month: comps, date: day, cal: cal), sessions: sessionsByDay[day] ?? [])
            if cell.inVisibleMonth { weekTotal += cell.totalLoad }
            weekDays.append(cell)
        }
        return WeekRow(weekStart: dates.first ?? monthStart, days: weekDays, totalLoad: weekTotal)
    }

    /// Pick the overnight session's morningFeeling for this day
    /// (naps / quick checks don't count). First overnight wins on
    /// multi-session days.
    private static func dayCellFor(day: Date, inMonth: Bool, sessions: [HRVSession]) -> DayCell {
        let dayLoad = sessions.reduce(0.0) { acc, s in
            acc + (s.workoutMetadata?.preferredTrainingLoad?.value ?? 0)
        }
        return DayCell(
            date: day,
            inVisibleMonth: inMonth,
            totalLoad: dayLoad,
            sessions: sessions,
            morningFeeling: sessions.first(where: { $0.sessionType == .overnight })?.morningFeeling
        )
    }

    // MARK: - Navigation

    private var canStepBack: Bool {
        guard let earliest = allSessions.map(\.startDate).min() else { return false }
        let earliestMonth = Self.startOfMonth(earliest)
        return visibleMonth > earliestMonth
    }

    private var canStepForward: Bool {
        visibleMonth < Self.startOfMonth(Date())
    }

    private func stepMonth(by delta: Int) {
        let cal = Calendar.current
        guard let next = cal.date(byAdding: .month, value: delta, to: visibleMonth) else { return }
        let nextStart = Self.startOfMonth(next)
        // Clamp to [earliestMonth, currentMonth]
        let currentMonth = Self.startOfMonth(Date())
        let earliestMonth = allSessions.map(\.startDate).min().map(Self.startOfMonth) ?? nextStart
        if nextStart < earliestMonth { return }
        if nextStart > currentMonth { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            visibleMonth = nextStart
        }
    }

    private static func startOfMonth(_ date: Date) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: date)
        return cal.date(from: comps) ?? date
    }

    // Static so there is no per-render DateFormatter churn: monthTitle runs
    // once per render, accessibilityLabel once per day cell (~42/render).
    // Default locale.
    /// Month and year in the selected language's order ("2026年9月", "September 2026").
    private static var monthTitleFormatter: DateFormatter { LocalizedDateFormat.formatter(template: "MMMMyyyy") }

    private static let accessibilityDateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        return fmt
    }()

    private func monthTitle(_ date: Date) -> String {
        Self.monthTitleFormatter.string(from: date)
    }

    private func accessibilityLabel(for day: DayCell) -> String {
        let dateStr = Self.accessibilityDateFormatter.string(from: day.date)
        if day.sessions.isEmpty {
            return String(format: NSLocalizedString("%@, no sessions", bundle: LanguageManager.appBundle, comment: ""), dateStr)
        }
        let count = day.sessions.count
        let load = Int(day.totalLoad.rounded())
        let sessions = String(localized: "\(count) sessions", bundle: LanguageManager.appBundle)
        let loadText = String(localized: "\(load) LOAD", bundle: LanguageManager.appBundle)
        return String(localized: "\(dateStr), \(sessions), \(loadText). Double tap to open.", bundle: LanguageManager.appBundle)
    }
}

// MARK: - Day-summary sheet

private struct DaySheetIdentity: Identifiable {
    let date: Date
    let sessions: [HRVSession]
    var id: Date { date }
}

@MainActor
private struct DaySummarySheet: View {
    let date: Date
    /// Local, mutable copy so a delete removes the row immediately — the parent
    /// passes a value snapshot and only reloads on the next archive signal.
    @State private var sessions: [HRVSession]
    let onDelete: (HRVSession) -> Void

    @State private var pendingDelete: HRVSession?

    @Environment(\.dismiss) private var dismiss

    init(date: Date, sessions: [HRVSession], onDelete: @escaping (HRVSession) -> Void) {
        self.date = date
        _sessions = State(initialValue: sessions)
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationStack {
            withDeleteConfirmation(daySessionList)
        }
    }

    private var sessionStack: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerCard
            ForEach(sessions, id: \.id) { session in
                deletableSessionRow(session)
            }
        }
    }

    private func deletableSessionRow(_ session: HRVSession) -> some View {
        sessionRow(session)
            .contextMenu { deleteMenuButton(session) }
    }

    private var daySessionList: some View {
        ScrollView {
            sessionStack
                .padding(18)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle(Text(date, style: .date))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { doneToolbarItem }
    }

    /// ScrollView rows cannot use `swipeActions` (List-only), so delete is
    /// exposed through a long-press context menu instead.
    private func deleteMenuButton(_ session: HRVSession) -> some View {
        Button(role: .destructive) {
            // ScrollView rows can't use swipeActions (List-only),
            // so expose delete via long-press context menu.
            pendingDelete = session
        } label: {
            Label(String(localized: "Delete Reading", bundle: LanguageManager.appBundle), systemImage: "trash")
        }
    }

    @ToolbarContentBuilder
    private var doneToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(String(localized: "Done", bundle: LanguageManager.appBundle)) { dismiss() }
        }
    }

    private func withDeleteConfirmation(_ content: some View) -> some View {
        content
            .confirmationDialog(
                String(localized: "Delete this reading?", bundle: LanguageManager.appBundle),
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                deleteConfirmationActions
            } message: {
                Text(String(localized: "This moves the reading to Trash. You can restore it from Settings.", bundle: LanguageManager.appBundle))
            }
    }

    @ViewBuilder
    private var deleteConfirmationActions: some View {
        Button(String(localized: "Delete", bundle: LanguageManager.appBundle), role: .destructive) {
            guard let session = pendingDelete else { return }
            onDelete(session)
            sessions.removeAll { $0.id == session.id }
            pendingDelete = nil
            if sessions.isEmpty { dismiss() }
        }
        Button(String(localized: "Cancel", bundle: LanguageManager.appBundle), role: .cancel) {
            pendingDelete = nil
        }
    }

    private var totalLoad: Double {
        sessions.reduce(0.0) { acc, s in
            acc + (s.workoutMetadata?.preferredTrainingLoad?.value ?? 0)
        }
    }

    private var headerCard: some View {
        let dur = sessions.reduce(0.0) { acc, s in
            guard let end = s.endDate else { return acc }
            return acc + end.timeIntervalSince(s.startDate)
        }
        let durMin = Int(dur / 60)
        return HStack(spacing: 14) {
            loadStat
            Divider().frame(height: 36)
            sessionCountStat
            minutesStat(durMin)
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AppTheme.cardBackground)
        )
    }

    @ViewBuilder
    private func minutesStat(_ durMin: Int) -> some View {
        if durMin > 0 {
            Divider().frame(height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(durMin)")
                    .font(.title2.bold().monospacedDigit())
                    .foregroundStyle(AppTheme.textPrimary)
                Text(verbatim: String(localized: "MINUTES", bundle: LanguageManager.appBundle))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
    }

    private var sessionCountStat: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "\(sessions.count)")
                .font(.title2.bold().monospacedDigit())
                .foregroundStyle(AppTheme.textPrimary)
            Text(verbatim: sessions.count == 1 ? String(localized: "SESSION", bundle: LanguageManager.appBundle) : String(localized: "SESSIONS", bundle: LanguageManager.appBundle))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    private var loadStat: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "\(Int(totalLoad.rounded()))")
                .font(.title2.bold().monospacedDigit())
                .foregroundStyle(AppTheme.textPrimary)
            Text(verbatim: String(localized: "LOAD", bundle: LanguageManager.appBundle))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    private func sessionRow(_ session: HRVSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sessionRowHeader(session)
            // Session-specific extra details inline so the user doesn't
            // need another tap to see the headline numbers.
            if let result = session.analysisResult, session.sessionType == .overnight {
                overnightDetailRow(session: session, result: result)
            }
            if let meta = session.workoutMetadata, session.sessionType == .workout {
                workoutDetailRow(meta: meta)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AppTheme.cardBackground)
        )
    }

    private func sessionRowHeader(_ session: HRVSession) -> some View {
        let sport = session.workoutMetadata?.sport
        let isWorkout = session.sessionType == .workout
        return HStack(spacing: 10) {
            Image(systemName: Self.sessionIcon(session, sport: sport))
                .font(.title3)
                .foregroundStyle(isWorkout ? AppTheme.fitnessAccent : AppTheme.primary)
                .frame(width: 28)
            sessionRowTitle(session, sport: sport)
            Spacer()
            sessionRowLoad(session)
        }
    }

    private static func sessionTitle(_ session: HRVSession, sport: Sport?) -> String {
        if let sport { return sport.displayName }
        if session.sessionType == .overnight { return String(localized: "Overnight HRV", bundle: LanguageManager.appBundle) }
        return String(localized: "Reading", bundle: LanguageManager.appBundle)
    }

    private static func sessionIcon(_ session: HRVSession, sport: Sport?) -> String {
        if let sport { return sport.icon }
        if session.sessionType == .overnight { return "moon.zzz.fill" }
        return "heart.fill"
    }

    private func sessionRowTitle(_ session: HRVSession, sport: Sport?) -> some View {
        let timeStr = session.startDate.formatted(date: .omitted, time: .shortened)
        let durSec = session.endDate.map { $0.timeIntervalSince(session.startDate) } ?? 0
        return VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: Self.sessionTitle(session, sport: sport))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
            // Locale-aware "min" abbreviation.
            Text(verbatim: "\(timeStr) · \(LocalizedDuration.minutes(Int(durSec / 60)))")
                .font(.caption)
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    @ViewBuilder
    private func sessionRowLoad(_ session: HRVSession) -> some View {
        if let load = session.workoutMetadata?.preferredTrainingLoad, load.value > 0 {
            VStack(alignment: .trailing, spacing: 1) {
                Text(verbatim: "\(Int(load.value.rounded()))")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(AppTheme.textPrimary)
                Text(verbatim: sourceLabel(for: load.source))
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
    }

    private func overnightDetailRow(session: HRVSession, result: HRVAnalysisResult) -> some View {
        HStack(spacing: 14) {
            detailField(label: "RMSSD", value: "\(Int(result.timeDomain.rmssd.rounded())) ms")
            if let score = session.recoveryScore {
                detailField(label: String(localized: "Recovery", bundle: LanguageManager.appBundle), value: "\(ScoreVerdict.safeDisplayScore(score * 10))")
            }
            if result.timeDomain.meanHR > 0 {
                detailField(label: String(localized: "Mean HR", bundle: LanguageManager.appBundle), value: "\(Int(result.timeDomain.meanHR.rounded())) bpm")
            }
            Spacer()
        }
    }

    /// Respects the user's units setting instead of hardcoding km/m.
    private func workoutDetailRow(meta: WorkoutMetadata) -> some View {
        let units = UnitsPreferenceStore.current.resolved
        return HStack(spacing: 14) {
            if let dist = meta.distanceMeters, dist > 0 {
                detailField(label: String(localized: "Distance", bundle: LanguageManager.appBundle), value: units.formatDistance(meters: dist))
            }
            if let np = meta.normalizedPowerWatts, np > 0 {
                detailField(label: "NP", value: "\(Int(np.rounded())) W")
            }
            if let gain = meta.elevationGainMeters, gain > 2 {
                detailField(label: String(localized: "Climb", bundle: LanguageManager.appBundle), value: units.formatElevation(meters: gain))
            }
            Spacer()
        }
    }

    private func detailField(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.textTertiary)
            Text(verbatim: value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private func sourceLabel(for source: WorkoutMetadata.TrainingLoadSource) -> String {
        switch source {
        case .power: return "Coggan"
        case .hr: return "hrTSS"
        case .mets: return "METs"
        case .banister: return "Banister"
        case .routeHistory: return "est"
        }
    }
}
