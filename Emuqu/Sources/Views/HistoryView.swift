import QuickLook
import SwiftUI

/// History view showing all recorded sessions with filtering and delete
struct HistoryView: View {
    @Environment(\.dependencies) var dependencies
    @Environment(RRCollector.self) private var collector
    @Environment(ArchiveSignal.self) private var archiveSignal

    let onDelete: (HRVSession) -> Void
    let onUpdateTags: (HRVSession, [ReadingTag], String?) -> Void
    var onReanalyze: ((HRVSession, WindowSelectionMethod) async -> HRVSession?)?
    var scrollToTopToken: UUID = .init()

    @State private var viewModel = HistoryViewModel()

    @State private var deleteSessionId: UUID?
    @State private var showingDeleteAlert = false
    @State private var selectedSession: HRVSession?
    @State private var selectedLinkedSegments: [LinkedSegmentInfo]?
    @State private var cachedRecentSessions: [HRVSession] = []
    /// Handle for the in-flight session-load Task.
    /// `loadAndSelect` is async (no disk I/O on the main
    /// thread), so there is a Task to track. We
    /// cancel it on `.onDisappear` so a user who taps a row, immediately
    /// pops back, and taps another row doesn't have a stale background
    /// load racing the new selection. Also prevents the old session
    /// from briefly flashing in if its decode finishes first.
    @State private var selectionTask: Task<Void, Never>?
    @State private var recentLoadTask: Task<Void, Never>?

    /// Entries currently visible (paginated slice of filteredEntries)
    private var visibleEntries: [SessionArchiveEntry] {
        Array(viewModel.filteredEntries.prefix(viewModel.displayLimit))
    }

    /// Whether there are more entries to load beyond the current page
    private var hasMore: Bool {
        viewModel.displayLimit < viewModel.filteredEntries.count
    }

    private static let monthYearStyle: Date.FormatStyle = .dateTime.month(.wide).year()

    private var groupedEntries: [(String, [SessionArchiveEntry])] {
        Dictionary(grouping: visibleEntries) { Self.sectionKey(for: $0.displayDate) }
            .sorted(by: Self.sectionsInReadingOrder)
    }

    /// The bucket an entry falls into. Named, not formatted, for the four recent
    /// buckets; anything older groups by month.
    private static func sectionKey(for date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return "This Week" }
        if let weekAgo = calendar.date(byAdding: .weekOfYear, value: -1, to: now),
           calendar.isDate(date, equalTo: weekAgo, toGranularity: .weekOfYear) {
            return "Last Week"
        }
        return date.formatted(Self.monthYearStyle)
    }

    /// Named buckets first in their fixed order, then months newest-first.
    private static func sectionsInReadingOrder(
        _ first: (key: String, value: [SessionArchiveEntry]),
        _ second: (key: String, value: [SessionArchiveEntry])
    ) -> Bool {
        let order = ["Today", "Yesterday", "This Week", "Last Week"]
        let idx1 = order.firstIndex(of: first.key) ?? Int.max
        let idx2 = order.firstIndex(of: second.key) ?? Int.max
        if idx1 != idx2 { return idx1 < idx2 }
        // For months, sort by date descending
        if let date1 = first.value.first?.displayDate,
           let date2 = second.value.first?.displayDate {
            return date1 > date2
        }
        return first.key < second.key
    }

    /// Maps a grouping key (a stable English identifier also used as the
    /// section `id` and for order lookup) to a localized display title.
    /// Month-year keys (the fallback) are already locale-formatted, so
    /// they pass through unchanged.
    private func localizedSectionTitle(_ key: String) -> String {
        switch key {
        case "Today": return String(localized: "Today", bundle: LanguageManager.appBundle)
        case "Yesterday": return String(localized: "Yesterday", bundle: LanguageManager.appBundle)
        case "This Week": return String(localized: "This Week", bundle: LanguageManager.appBundle)
        case "Last Week": return String(localized: "Last Week", bundle: LanguageManager.appBundle)
        default: return key
        }
    }

    var body: some View {
        withHistoryLifecycle(historyStack)
    }

    private var historyStack: some View {
        VStack(spacing: 0) {
            filterHeader
            if viewModel.filteredEntries.isEmpty {
                emptyState
            } else {
                historyList
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle(String(localized: "History", bundle: LanguageManager.appBundle))
    }

    /// Session-type filter, tag filter and the search field.
    private var filterHeader: some View {
        VStack(spacing: 0) {
            sessionTypeFilterBar
                .padding(.horizontal)
                .padding(.top, 8)
            tagFilterBar
                .padding(.horizontal)
                .padding(.vertical, 8)
            searchBar
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
    }

    /// An explicit field rather than `.searchable`: this screen is pushed from
    /// the Dashboard's stack, and the system placement never rendered a field
    /// there, so users had no way to search. A plain field in the header is
    /// visible on every iOS version and reachable by the UI suite.
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppTheme.textTertiary)
            TextField(
                String(localized: "Search readings", bundle: LanguageManager.appBundle),
                text: $viewModel.searchText
            )
            .textFieldStyle(.plain)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .accessibilityIdentifier("history.search")
            if !viewModel.searchText.isEmpty { clearSearchButton }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(AppTheme.cardBackground))
    }

    private var clearSearchButton: some View {
        Button { viewModel.searchText = "" } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(AppTheme.textTertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Clear search", bundle: LanguageManager.appBundle))
    }

    private var historyList: some View {
        ScrollViewReader { scrollProxy in
            historyEntryList
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .onChange(of: scrollToTopToken) { scrollToTop(scrollProxy) }
        }
    }

    /// Scrolls to the first section's header. The header carries the id, so
    /// the list needs no anchor row (an inset grouped list draws even a
    /// zero-height row as an empty capsule).
    private func scrollToTop(_ proxy: ScrollViewProxy) {
        guard let first = groupedEntries.first?.0 else { return }
        withAnimation { proxy.scrollTo(Self.sectionHeaderID(first), anchor: .top) }
    }

    private static func sectionHeaderID(_ section: String) -> String { "history.section.\(section)" }

    private var historyEntryList: some View {
        List {
            entrySections
            loadMoreTrigger
        }
    }

    private var entrySections: some View {
        ForEach(groupedEntries, id: \.0) { section, sectionEntries in
            entrySection(section, entries: sectionEntries)
        }
    }

    private func entrySection(_ section: String, entries: [SessionArchiveEntry]) -> some View {
        Section {
            entryRows(entries)
        } header: {
            Text(localizedSectionTitle(section)).id(Self.sectionHeaderID(section))
        }
    }

    private func entryRows(_ entries: [SessionArchiveEntry]) -> some View {
        ForEach(entries, id: \.sessionId) { entry in
            entryRow(entry)
        }
    }

    private func entryRow(_ entry: SessionArchiveEntry) -> some View {
        withEntryActions(entryRowContent(entry), entry: entry)
    }

    private func entryRowContent(_ entry: SessionArchiveEntry) -> some View {
        EntryHistoryRow(
            entry: entry,
            linkedSegmentCount: viewModel.linkedSegmentCounts[entry.sessionId] ?? 0
        )
        .contentShape(Rectangle())
        .onTapGesture {
            loadAndSelect(entry)
        }
        // The only route to a past reading's full detail. Rows carry one
        // shared identifier rather than a per-session one: a UI test knows it
        // seeded a reading, not which UUID the archive gave it.
        .accessibilityIdentifier("history.entryRow")
    }

    private func withEntryActions(_ content: some View, entry: SessionArchiveEntry) -> some View {
        content
            .swipeActions(edge: .trailing, allowsFullSwipe: false) { deleteEntryButton(entry) }
            .swipeActions(edge: .leading) { editTagsButton(entry) }
            .contextMenu { askFloButton(entry) }
    }

    private func deleteEntryButton(_ entry: SessionArchiveEntry) -> some View {
        Button(role: .destructive) {
            deleteSessionId = entry.sessionId
            showingDeleteAlert = true
        } label: {
            Label(String(localized: "Delete", bundle: LanguageManager.appBundle), systemImage: "trash")
        }
    }

    private func editTagsButton(_ entry: SessionArchiveEntry) -> some View {
        Button {
            loadAndSelect(entry)
        } label: {
            Label(String(localized: "Edit Tags", bundle: LanguageManager.appBundle), systemImage: "tag")
        }
        .tint(.blue)
    }

    private func askFloButton(_ entry: SessionArchiveEntry) -> some View {
        Button {
            askAssistantAbout(entry: entry)
        } label: {
            Label(String(localized: "Ask Flo about this session", bundle: LanguageManager.appBundle), systemImage: "sparkles")
        }
    }

    /// Load-more trigger: appearing at the bottom pulls the next page.
    @ViewBuilder
    private var loadMoreTrigger: some View {
        // Load more trigger
        if hasMore {
            loadMoreSection
        }
    }

    private var loadMoreSection: some View {
        Section {
            loadMoreRow
        }
    }

    @ViewBuilder
    private var loadMoreRow: some View {
        HStack {
            Spacer()
            loadMoreProgress
            Spacer()
        }
        .padding(.vertical, 4)
        .onAppear {
            viewModel.loadMore()
        }
    }

    private var loadMoreProgress: some View {
        VStack(spacing: 6) {
            ProgressView()
            Text(String(localized: "\(visibleEntries.count) of \(viewModel.filteredEntries.count) readings", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
        }
    }

    /// Delete confirmation, the recent-session loads and their cancellation on
    /// the way out, and the session-detail sheet.
    private func withHistoryLifecycle(_ content: some View) -> some View {
        withDeleteAlert(content)
            .task { await loadRecentSessions() }
            .onAppear { viewModel.refreshIfNeeded(archiveVersion: archiveSignal.version) }
            .onChange(of: archiveSignal.version) { archiveChanged() }
            .onDisappear { cancelInFlightWork() }
            .sheet(item: $selectedSession) { session in
                sessionDetailSheet(for: session)
            }
    }

    private func withDeleteAlert(_ content: some View) -> some View {
        content
            .alert(String(localized: "Delete Reading", bundle: LanguageManager.appBundle), isPresented: $showingDeleteAlert) {
                deleteAlertActions
            } message: {
                Text(String(localized: "This moves the reading to the Trash. You can restore it from Settings → iCloud & Data → Trash.", bundle: LanguageManager.appBundle))
            }
    }

    @ViewBuilder
    private var deleteAlertActions: some View {
        Button(String(localized: "Delete", bundle: LanguageManager.appBundle), role: .destructive) {
            confirmDelete()
        }
        Button(String(localized: "Cancel", bundle: LanguageManager.appBundle), role: .cancel) {
            deleteSessionId = nil
        }
    }

    private func confirmDelete() {
        guard let sessionId = deleteSessionId else { return }
        deleteSessionId = nil
        do {
            try collector.archive.delete(sessionId)
            collector.notifyArchiveChanged()
            // Sync the deletion to iCloud so it doesn't reappear on the next pull.
            Task { await dependencies.storage.cloudKitSyncManager.uploadDeletion(sessionId) }
        } catch {
            debugLog("[HistoryView] Failed to delete session")
        }
    }

    private func loadRecentSessions() async {
        let loaded = await collector.recentSessionsAsync(limit: MorningResultsView.recentSessionsContextLimit)
        cachedRecentSessions = loaded.filter { $0.state == .complete }
    }

    /// The recent-load Task is tracked so a fast
    /// archive-version churn (multi-session import, batch reanalyze) does not
    /// queue redundant background loads.
    private func archiveChanged() {
        viewModel.refreshIfNeeded(archiveVersion: archiveSignal.version)
        recentLoadTask?.cancel()
        recentLoadTask = Task {
            let loaded = await collector.recentSessionsAsync(limit: MorningResultsView.recentSessionsContextLimit)
            if Task.isCancelled { return }
            cachedRecentSessions = loaded.filter { $0.state == .complete }
        }
    }

    /// Cancel any in-flight selection / recent-load tasks so a user who
    /// navigates away mid-decode does not waste CPU or get a stale assignment.
    private func cancelInFlightWork() {
        selectionTask?.cancel()
        selectionTask = nil
        recentLoadTask?.cancel()
        recentLoadTask = nil
    }

    // MARK: - Load Session On Demand

    /// Pre-fill the AI Assistant with a question about a specific historical
    /// session and switch tabs. The Assistant's context already includes the
    /// last 14 days lite + the diagnostic for any session opened in
    /// MorningResultsView, so questions about recent sessions get rich answers.
    private func askAssistantAbout(entry: SessionArchiveEntry) {
        let dateString = entry.displayDate.formatted(date: .abbreviated, time: .shortened)
        var bits: [String] = []
        if let score = entry.recoveryScore { // the 0-100 number the row shows
            bits.append(String(localized: "recovery score \(historyDisplayScore(score).composite)/100", bundle: LanguageManager.appBundle))
        }
        if let rmssd = entry.meanRMSSD {
            bits.append(String(localized: "RMSSD \(String(format: "%.1f", locale: .current, rmssd))ms", bundle: LanguageManager.appBundle))
        }
        let summary = bits.isEmpty ? "" : " (\(bits.joined(separator: ", ")))"
        let question = String(localized: "Tell me about my session from \(dateString)\(summary). What was notable about it, what likely caused that result, and how does it compare to my baseline and to surrounding days?", bundle: LanguageManager.appBundle)
        dependencies.assistant.assistantInbox.pendingDraft = question
        dependencies.assistant.assistantInbox.requestOpen()
    }

    /// Not synchronous disk I/O on @MainActor:
    /// `archive.retrieve` decodes a full HRVSession including the
    /// rrSeries, which could be 50+KB JSON parse on the main thread.
    /// So it runs off-main via `retrieveFullSessionAsync`, with task
    /// cancellation tied to view lifecycle so navigating away
    /// mid-decode doesn't waste cycles or fight a newer selection.
    private func loadAndSelect(_ entry: SessionArchiveEntry) {
        // Cancel any prior in-flight selection — only the latest tap
        // matters. Without this, a tap-tap-tap on different rows
        // races to assign `selectedSession` and the user sees the
        // wrong session pop up.
        selectionTask?.cancel()
        selectionTask = Task {
            guard let session = await collector.retrieveFullSessionAsync(entry.sessionId) else {
                debugLog("[HistoryView] Failed to load session \(entry.sessionId)")
                return
            }
            if Task.isCancelled { return }
            // The BFS dedup in filteredEntries already picks the
            // winner from each linked chain, so the tapped entry IS
            // the best session. No need to load the rest of the night.
            selectedLinkedSegments = collector.archive.linkedSegments(for: session)
            selectedSession = session
        }
    }

    // MARK: - Session Detail Sheet

    /// Workouts get the fitness summary view — map, TRIMP, splits, GPX
    /// export. The overnight HRV detail view (MorningResultsView) requires
    /// analysisResult, which short workouts don't have enough beats to
    /// produce; routing those there shows "No analysis data available".
    @ViewBuilder
    private func sessionDetailSheet(for session: HRVSession) -> some View {
        if session.sessionType == .workout {
            NavigationStack { workoutSummarySheet(session) }
        } else if let result = session.analysisResult {
            NavigationStack { sessionDetailContent(session: session, result: result) }
        } else {
            noAnalysisPlaceholder
        }
    }

    private func workoutSummarySheet(_ session: HRVSession) -> some View {
        FitnessPostSummaryView(session: session) { selectedSession = nil }
    }

    private var noAnalysisPlaceholder: some View {
        VStack {
            Text(String(localized: "No analysis data available", bundle: LanguageManager.appBundle))
                .foregroundColor(AppTheme.textSecondary)
            Button(String(localized: "Close", bundle: LanguageManager.appBundle)) { selectedSession = nil }
                .buttonStyle(.zen())
        }
        .padding()
    }

    /// History opens the FULL morning session view
    /// (`MorningResultsView`) so a past session is identical to the day it
    /// was recorded: sleep detail + timeline editing, recovery breakdown,
    /// training-load/readiness cards, tags & notes, export, and a prominent
    /// Re-analyze (full + manual-window). The session is already loaded with
    /// its `rrSeries` (via `retrieveFullSessionAsync` in `loadAndSelect`), so
    /// reanalyze is ready immediately — no trip to Settings. `MorningResultsView`
    /// auto-detects a non-today session (`isHistoricalSession`) and renders it
    /// frozen/read-only; it never re-archives on open.
    private func sessionDetailContent(session: HRVSession, result: HRVAnalysisResult) -> some View {
        MorningResultsView(
            session: session,
            result: result,
            recentSessions: cachedRecentSessions,
            onDiscard: { selectedSession = nil },
            onDelete: { deleteAndDismiss(session) },
            onReanalyze: { s, method in await onReanalyze?(s, method) },
            onUpdateTags: { tags, notes in onUpdateTags(session, tags, notes) },
            onReanalyzeAt: { await collector.reanalyzeAtPosition(session, targetMs: $0) },
            onApplyManualResult: { await collector.applyManualAnalysis(session, result: $0) },
            onUpdateSleep: { collector.updateSessionSleepBoundaries(sessionId: session.id, sleepData: $0) },
            onAdjustSleep: { adjustSleep(session, sleepData: $0) },
            onUnlinkSegment: { collector.unlinkSegment(segmentId: $0, fromSession: session.id) },
            linkedSegments: selectedLinkedSegments,
            expandTechnicalDetails: true
        )
    }

    private func deleteAndDismiss(_ session: HRVSession) {
        onDelete(session)
        selectedSession = nil
    }

    private func adjustSleep(_ session: HRVSession, sleepData: SleepData) {
        _ = collector.updateSessionSleepBoundaries(sessionId: session.id, sleepData: sleepData, isUserAdjustment: true)
    }

    // MARK: - Session Type Filter Bar

    /// Five chips: All / Extended / Naps / Quick / Breathe.
    /// (No "Workouts" chip; workouts have their own
    /// home in the Fitness tab and surface there. "Extended" is the
    /// spec's term for overnight.)
    private var sessionTypeFilterBar: some View {
        // A bare HStack forces all 5 chips to share
        // the screen width, so "Extended" wrapped to 3 lines while the
        // shorter labels stayed on one. Horizontal ScrollView lets each
        // chip size to its content (matches the tagFilterBar pattern
        // immediately below in this file).
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                allFilterButton

                extendedFilterButton

                napFilterButton

                quickFilterButton

                workoutFilterButton
            }
            .padding(.vertical, 1) // prevents shadow-clipping at chip edges
        }
    }

    private var allFilterButton: some View {
        SessionTypeFilterButton(
            title: String(localized: "All", bundle: LanguageManager.appBundle),
            icon: "list.bullet",
            isSelected: viewModel.selectedSessionType == nil,
            color: AppTheme.primary
        ) {
            viewModel.selectedSessionType = nil
        }
    }

    private var extendedFilterButton: some View {
        SessionTypeFilterButton(
            title: String(localized: "Extended", bundle: LanguageManager.appBundle),
            icon: SessionType.overnight.icon,
            isSelected: viewModel.selectedSessionType == .overnight,
            color: AppTheme.primary
        ) {
            viewModel.selectedSessionType = .overnight
        }
    }

    private var napFilterButton: some View {
        SessionTypeFilterButton(
            title: String(localized: "Naps", bundle: LanguageManager.appBundle),
            icon: SessionType.nap.icon,
            isSelected: viewModel.selectedSessionType == .nap,
            color: AppTheme.mist
        ) {
            viewModel.selectedSessionType = .nap
        }
    }

    private var quickFilterButton: some View {
        SessionTypeFilterButton(
            title: String(localized: "Quick", bundle: LanguageManager.appBundle),
            icon: SessionType.quick.icon,
            isSelected: viewModel.selectedSessionType == .quick,
            color: AppTheme.sage
        ) {
            viewModel.selectedSessionType = .quick
        }
    }

    private var workoutFilterButton: some View {
        SessionTypeFilterButton(
            title: String(localized: "Breathe", bundle: LanguageManager.appBundle),
            icon: SessionType.breathe.icon,
            isSelected: viewModel.selectedSessionType == .breathe,
            color: AppTheme.sdnnColor
        ) {
            viewModel.selectedSessionType = .breathe
        }
    }

    // MARK: - Tag Filter Bar

    private var tagFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // All filter
                allTagsButton

                tagButtons
            }
        }
    }

    private var tagButtons: some View {
        ForEach(ReadingTag.systemTags) { tag in
            tagButton(tag)
        }
    }

    private func tagButton(_ tag: ReadingTag) -> some View {
        Button {
            toggleTag(tag)
        } label: {
            tagButtonLabel(tag)
        }
    }

    private func toggleTag(_ tag: ReadingTag) {
        if viewModel.selectedTags.contains(tag) {
            viewModel.selectedTags.remove(tag)
        } else {
            viewModel.selectedTags.insert(tag)
        }
    }

    private func tagButtonLabel(_ tag: ReadingTag) -> some View {
        Text(tag.displayName)
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(viewModel.selectedTags.contains(tag) ? tag.color : tag.color.opacity(0.15))
            .foregroundColor(viewModel.selectedTags.contains(tag) ? .white : tag.color)
            .cornerRadius(16)
    }

    private var allTagsButton: some View {
        Button {
            viewModel.selectedTags.removeAll()
        } label: {
            Text(String(localized: "All", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(viewModel.selectedTags.isEmpty ? Color.blue : Color.gray.opacity(0.2))
                .foregroundColor(viewModel.selectedTags.isEmpty ? .white : .primary)
                .cornerRadius(16)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "list.bullet.rectangle")
                .scaledFont(size: 48)
                .foregroundColor(AppTheme.textSecondary)

            noReadingsYetSection

            Spacer()
        }
    }

    @ViewBuilder
    private var noReadingsYetSection: some View {
        if collector.archive.entries.isEmpty {
            Text(String(localized: "No Readings Yet", bundle: LanguageManager.appBundle))
                .font(.headline)
            Text(String(localized: "Your HRV readings will appear here", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
        } else {
            Text(String(localized: "No Matching Readings", bundle: LanguageManager.appBundle))
                .font(.headline)
            Text(String(localized: "Try adjusting your filters", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)

            clearFiltersButton
        }
    }

    private var clearFiltersButton: some View {
        Button(String(localized: "Clear Filters", bundle: LanguageManager.appBundle)) {
            viewModel.selectedTags.removeAll()
            viewModel.searchText = ""
            // sessionType must be cleared here too: otherwise a user
            // who filtered to e.g. Workouts and got
            // no results would tap Clear Filters and still see the
            // empty state because the session-type chip stayed
            // selected.
            viewModel.selectedSessionType = nil
        }
        .buttonStyle(.bordered)
    }
}

// MARK: - Session Type Filter Button

private struct SessionTypeFilterButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                Text(title)
                    .font(.subheadline)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? color : color.opacity(0.15))
            .foregroundColor(isSelected ? .white : color)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "\(title) filter", bundle: LanguageManager.appBundle))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Entry History Row (uses archive metadata, no disk I/O)

private struct EntryHistoryRow: View {
    let entry: SessionArchiveEntry
    let linkedSegmentCount: Int

    private var sessionTypeColor: Color {
        switch entry.sessionType {
        case .overnight: AppTheme.primary
        case .nap: AppTheme.mist
        case .quick: AppTheme.sage
        case .breathe: AppTheme.sdnnColor
        case .workout: AppTheme.terracotta
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            sessionTypeIcon
            timeAndTags
            Spacer()
            rowMetrics

            Image(systemName: "chevron.forward")
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityHint(String(localized: "Double tap to view details", bundle: LanguageManager.appBundle))
    }

    private var sessionTypeIcon: some View {
        // Session type indicator
        Image(systemName: entry.sessionType.icon)
            .font(.title3)
            .foregroundColor(sessionTypeColor)
            .frame(width: 28)
            .accessibilityHidden(true)
    }

    private var timeAndTags: some View {
        // Date and Time
        VStack(alignment: .leading, spacing: 4) {
            timeRow

            Text(entry.displayDate, style: .date)
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)

            // Tags
            tagChips
        }
    }

    @ViewBuilder
    private var tagChips: some View {
        if !entry.tags.isEmpty {
            tagChipRow
        }
    }

    private var tagChipRow: some View {
        HStack(spacing: 4) {
            visibleTagChips
            overflowTagCount
        }
    }

    @ViewBuilder
    private var overflowTagCount: some View {
        if entry.tags.count > 3 {
            Text("+\(entry.tags.count - 3)")
                .font(.caption2)
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    private var visibleTagChips: some View {
        ForEach(entry.tags.prefix(3)) { tag in
            Text(tag.displayName)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(tag.color.opacity(0.2))
                .foregroundColor(tag.color)
                .cornerRadius(4)
        }
    }

    private var timeRow: some View {
        HStack(spacing: 6) {
            Text(entry.displayDate, style: .time)
                .font(.headline)

            // Show "Nap" label for nap sessions
            sessionTypeBadge

            // Show segment count badge only when normalized split-night
            // segmentation resolves to multiple meaningful segments.
            segmentCountBadge
        }
    }

    @ViewBuilder
    private var segmentCountBadge: some View {
        if linkedSegmentCount > 1 {
            HStack(spacing: 3) {
                Image(systemName: "link")
                    .font(.caption2.weight(.bold))
                Text(String(localized: "\(linkedSegmentCount) segments", bundle: LanguageManager.appBundle))
            }
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(AppTheme.primary.opacity(0.2))
            .foregroundColor(AppTheme.primary)
            .cornerRadius(4)
        }
    }

    @ViewBuilder
    private var sessionTypeBadge: some View {
        if entry.sessionType == .nap {
            napBadge
        } else if entry.sessionType == .quick {
            quickBadge
        } else if entry.sessionType == .breathe {
            breatheBadge
        }
    }

    /// Workout rows must not show RMSSD
    /// (mid-effort RR is contaminated and often reads as nonsense, e.g. 3 ms)
    /// or a recovery score, which is an overnight construct workouts do not
    /// get. Workouts render duration and sport; overnights, naps, quick
    /// checks and breathe sessions keep the RMSSD + recovery layout.
    private var rowMetrics: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if entry.sessionType == .workout {
                workoutRowMetrics(entry: entry)
            } else {
                recoveryRowMetrics
            }
        }
    }

    @ViewBuilder
    private var recoveryRowMetrics: some View {
        primaryMetricReadout
        recoveryScoreReadout
    }

    @ViewBuilder
    private var primaryMetricReadout: some View {
        if entry.sessionType == .breathe, let sdnn = entry.meanSDNN {
            HStack(spacing: 4) {
                Text(String(format: "%.0f", locale: .current, sdnn))
                    .font(.system(.title2, design: .rounded).bold())
                    .foregroundColor(AppTheme.sdnnColor)
                Text(String(localized: "SDNN", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
            }
        } else if let rmssd = entry.meanRMSSD {
            HStack(spacing: 4) {
                Text(String(format: "%.0f", locale: .current, rmssd))
                    .font(.system(.title2, design: .rounded).bold())
                Text(String(localized: "ms", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var recoveryScoreReadout: some View {
        if let rawScore = entry.recoveryScore {
            let (readiness, composite) = historyDisplayScore(rawScore)
            recoveryScoreRow(readiness: readiness, composite: composite)
            recoveryScoreBar(readiness: readiness, composite: composite)
        }
    }

    private func recoveryScoreBar(readiness: Double, composite: Int) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(AppTheme.textTertiary.opacity(0.15))
                .frame(width: 64, height: 3)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(AppTheme.readinessColor(readiness))
                .frame(width: max(2, 64 * CGFloat(min(100, max(0, composite))) / 100), height: 3)
        }
        .accessibilityHidden(true)
    }

    private func recoveryScoreRow(readiness: Double, composite: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: readinessIcon(readiness))
                .foregroundColor(AppTheme.readinessColor(readiness))
                .font(.caption)
            Text("\(composite)")
                .font(.caption.weight(.medium))
                .foregroundColor(AppTheme.readinessColor(readiness))
            Text(String(localized: "Recovery", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    private func readinessIcon(_ score: Double) -> String {
        // Aligned to the documented readiness tiers
        // (≥7.0 Ready / ≥4.5 Moderate / below Fatigued-Rest — the same
        // boundaries `AppTheme.readinessColor` uses). If the icon
        // switched at 5.0 while the color switched at 4.5, a 4.7 row
        // showed a warning icon in "Moderate" gold.
        if score >= 7.0 { return "checkmark.circle.fill" }
        if score >= 4.5 { return "minus.circle.fill" }
        return "exclamationmark.circle.fill"
    }

    /// Workout row trailing metrics — duration + distance pulled from
    /// the lightweight index where available. NO RMSSD (workouts have
    /// noisy mid-effort RR), NO recovery score (workouts don't have
    /// one — that's an overnight construct). Bug list #2 fix.
    @ViewBuilder
    private func workoutRowMetrics(entry: SessionArchiveEntry) -> some View {
        let duration: TimeInterval = {
            guard let end = entry.endDate else { return 0 }
            return end.timeIntervalSince(entry.date)
        }()
        if duration > 0 {
            let mins = Int(duration / 60)
            HStack(spacing: 4) {
                Image(systemName: "figure.run")
                    .font(.caption2)
                    .foregroundColor(AppTheme.terracotta)
                    .accessibilityHidden(true)
                Text(verbatim: mins >= 60 ? LocalizedDuration.hoursMinutes(minutes: mins) : LocalizedDuration.minutes(mins))
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundColor(AppTheme.textPrimary)
            }
        }
        Text(String(localized: "Workout", bundle: LanguageManager.appBundle))
            .font(.caption2)
            .foregroundColor(AppTheme.textSecondary)
    }
}

private var napBadge: some View {
    Text(String(localized: "Nap", bundle: LanguageManager.appBundle))
        .font(.caption2.bold())
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(AppTheme.mist.opacity(0.2))
        .foregroundColor(AppTheme.mist)
        .cornerRadius(4)
}

@MainActor
private var quickBadge: some View {
    Text(String(localized: "Quick", bundle: LanguageManager.appBundle))
        .font(.caption2.bold())
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(AppTheme.sage.opacity(0.2))
        .foregroundColor(AppTheme.sage)
        .cornerRadius(4)
}

@MainActor private var breatheBadge: some View {
    Text(String(localized: "Breathe", bundle: LanguageManager.appBundle))
        .font(.caption2.bold())
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(AppTheme.sdnnColor.opacity(0.2))
        .foregroundColor(AppTheme.sdnnColor)
        .cornerRadius(4)
}

#Preview {
    NavigationStack {
        HistoryView(
            onDelete: { _ in },
            onUpdateTags: { _, _, _ in },
            onReanalyze: nil
        )
    }
}

/// Readiness (0-10) and the 0-100 composite the row shows. Legacy ms-scale
/// imports (RMSSD × stability) are scaled and clamped into 0-10.
private func historyDisplayScore(_ rawScore: Double) -> (readiness: Double, composite: Int) {
    let readiness = rawScore > 10 ? min(10, rawScore / 5.0) : rawScore
    return (readiness, ScoreVerdict.safeDisplayScore(readiness * 10))
}
