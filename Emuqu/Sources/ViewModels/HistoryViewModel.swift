import Combine
import SwiftUI

/// ViewModel for HistoryView — caches filtered entries and linked-chain deduplication
/// so the expensive BFS computation doesn't re-run on every SwiftUI body evaluation.
@Observable
@MainActor
final class HistoryViewModel {
    // MARK: - Published State

    var searchText: String = ""
    var selectedSessionType: SessionType?
    var selectedTags: Set<ReadingTag> = []
    var displayLimit: Int = 10

    /// The filtered, deduplicated, sorted archive entries — cached, not recomputed per render.
    private(set) var filteredEntries: [SessionArchiveEntry] = []
    /// Normalized split-night segment count by session ID (only entries with >1 segments).
    private(set) var linkedSegmentCounts: [UUID: Int] = [:]

    // MARK: - Dependencies

    private let archive: SessionArchive
    private let settingsProvider: () -> UserSettings
    @ObservationIgnored private var filterObservation: ObservationHandle?
    @ObservationIgnored private var filterDebounce: Task<Void, Never>?
    private var lastArchiveVersion: Int = -1

    let pageSize = 10

    // MARK: - Init

    init(
        archive: SessionArchive = AppDependencies.current.storage.sessionArchive,
        settingsProvider: @escaping () -> UserSettings = { AppDependencies.current.app.settingsManager.settingsSnapshot }
    ) {
        self.archive = archive
        self.settingsProvider = settingsProvider

        // Recompute filtered entries when any filter changes, debounced.
        // Also reset displayLimit to pageSize when filters change.
        filterObservation = ObservationLoop.observe(
            self, initial: true,
            read: { ($0.searchText, $0.selectedSessionType, $0.selectedTags) }
        , onChange: { vm, _ in vm.scheduleFilterRecompute() })
    }

    /// One recompute per burst of filter edits, `HistoryConstants.filterDebounceMs` after the last.
    private func scheduleFilterRecompute() {
        filterDebounce?.cancel()
        filterDebounce = Task { @MainActor [weak self] in
            await sleepQuietly(UInt64(HistoryConstants.filterDebounceMs) * 1_000_000, context: "historyFilterDebounce")
            guard !Task.isCancelled, let self else { return }
            displayLimit = pageSize
            recomputeFilteredEntries()
        }
    }

    /// Call when archiveVersion changes (from collector.archiveVersion)
    func refreshIfNeeded(archiveVersion: Int) {
        guard archiveVersion != lastArchiveVersion else { return }
        lastArchiveVersion = archiveVersion
        recomputeFilteredEntries()
    }

    func loadMore() {
        displayLimit += pageSize
    }

    // MARK: - Core Logic (moved from HistoryView.filteredEntries)
    //
    // The BFS chain dedup + same-night collapse +
    // filter passes must not run synchronously on @MainActor when the
    // user opens the History tab. For users with many split-night
    // chains the O(n + chain²) BFS plus the per-entry DateFormatter
    // search-string format add up to a perceptible main-thread
    // freeze. The compute is pure in-memory work with no actor-bound
    // state — it runs in a Task.detached and is applied back on main.

    @ObservationIgnored private var recomputeTask: Task<Void, Never>?

    /// Cancel any in-flight recompute — only the latest set of filters
    /// matters. Without this a user typing fast in the search field would
    /// queue up multiple recomputes that all race to assign filteredEntries.
    private func recomputeFilteredEntries() {
        recomputeTask?.cancel()
        let entries = archive.entries
        let typeFilter = selectedSessionType
        let tagFilter = selectedTags
        let search = searchText
        let schedule = settingsProvider().sleepSchedule
        recomputeTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = Self.computeFiltered(
                entries: entries,
                typeFilter: typeFilter,
                tagFilter: tagFilter,
                searchText: search,
                schedule: schedule
            )
            if Task.isCancelled { return }
            await self?.apply(result)
        }
    }

    /// Capture `self` weakly OUTSIDE the MainActor.run
    /// closure (Swift 6 strict concurrency rejects `[weak self]` capture being
    /// read inside a Sendable sub-closure). Hopping to main with the result
    /// first keeps the weak capture on the outer closure, where it's read
    /// before any further suspension point.
    @MainActor
    private func apply(_ result: (sorted: [SessionArchiveEntry], linkedSegmentCounts: [UUID: Int])) {
        filteredEntries = result.sorted
        linkedSegmentCounts = result.linkedSegmentCounts
    }

    /// Pure in-memory compute. `nonisolated static` so callers from
    /// any actor context can invoke without isolation churn. Inputs
    /// are all Sendable value types (or already-resolved snapshots
    /// from the main actor).
    nonisolated private static func computeFiltered(
        entries: [SessionArchiveEntry],
        typeFilter: SessionType?,
        tagFilter: Set<ReadingTag>,
        searchText: String,
        schedule: SleepSchedule
    ) -> (sorted: [SessionArchiveEntry], linkedSegmentCounts: [UUID: Int]) {
        let entryById = Dictionary(entries.map { ($0.sessionId, $0) }, uniquingKeysWith: { first, _ in first })
        let idsToHide = chainDuplicateIds(entries: entries, entryById: entryById)
        var result = entries.filter { !idsToHide.contains($0.sessionId) }
        result = collapseSameNightOvernightDuplicatesStatic(result, entryById: entryById, schedule: schedule)
        result = applyFilters(result, typeFilter: typeFilter, tagFilter: tagFilter, searchText: searchText)
        let sorted = result.sorted { $0.displayDate > $1.displayDate }
        let counts = computeLinkedSegmentCountsStatic(for: sorted, entryById: entryById)
        return (sorted, counts)
    }

    /// Every entry in a linked chain except the chain's winner. A split night
    /// arrives as several linked segments; History shows one row for it.
    nonisolated private static func chainDuplicateIds(
        entries: [SessionArchiveEntry], entryById: [UUID: SessionArchiveEntry]
    ) -> Set<UUID> {
        var visited: Set<UUID> = []
        var idsToHide: Set<UUID> = []
        for entry in entries {
            guard let linked = entry.linkedSessionIds, !linked.isEmpty,
                  !visited.contains(entry.sessionId) else { continue }
            let chain = chainFrom(entry, entryById: entryById, visited: &visited)
            guard chain.count > 1, let winner = chainWinner(chain) else { continue }
            for member in chain where member.sessionId != winner.sessionId {
                idsToHide.insert(member.sessionId)
            }
        }
        return idsToHide
    }

    /// Breadth-first walk of one link chain, marking everything it reaches as
    /// visited so an entry is never walked twice.
    nonisolated private static func chainFrom(
        _ entry: SessionArchiveEntry,
        entryById: [UUID: SessionArchiveEntry],
        visited: inout Set<UUID>
    ) -> [SessionArchiveEntry] {
        var chain: [SessionArchiveEntry] = []
        var queue: [UUID] = [entry.sessionId]
        while !queue.isEmpty {
            let id = queue.removeFirst()
            guard !visited.contains(id) else { continue }
            visited.insert(id)
            guard let member = entryById[id] else { continue }
            chain.append(member)
            for linkedId in member.linkedSessionIds ?? [] where !visited.contains(linkedId) {
                queue.append(linkedId)
            }
        }
        return chain
    }

    /// Highest recovery score wins; ties break to the later end date, then the
    /// later start, so the choice is stable across recomputes.
    nonisolated private static func chainWinner(_ chain: [SessionArchiveEntry]) -> SessionArchiveEntry? {
        chain.max { a, b in
            let scoreA = a.recoveryScore ?? 0
            let scoreB = b.recoveryScore ?? 0
            if scoreA != scoreB { return scoreA < scoreB }
            let aEnd = a.endDate ?? .distantPast
            let bEnd = b.endDate ?? .distantPast
            if aEnd != bEnd { return aEnd < bEnd }
            return a.date < b.date
        }
    }

    /// Type, tag and free-text filters. The search pass builds one
    /// DateFormatter per call, off the main actor, in the app's language: the
    /// rows show dates in that language, so a search for "Okt" must match
    /// German month names even on an English-locale device.
    nonisolated private static func applyFilters(
        _ entries: [SessionArchiveEntry],
        typeFilter: SessionType?,
        tagFilter: Set<ReadingTag>,
        searchText: String
    ) -> [SessionArchiveEntry] {
        var result = entries
        if let typeFilter {
            result = result.filter { $0.sessionType == typeFilter }
        }
        if !tagFilter.isEmpty {
            result = result.filter { !tagFilter.isDisjoint(with: Set($0.tags)) }
        }
        guard !searchText.isEmpty else { return result }
        let formatter = DateFormatter()
        formatter.locale = LanguageManager.appLocale
        formatter.dateStyle = .medium
        return result.filter { entry in
            let dateString = formatter.string(from: entry.displayDate)
            return dateString.localizedCaseInsensitiveContains(searchText) ||
                entry.tags.contains { $0.name.localizedCaseInsensitiveContains(searchText) } ||
                (entry.notes?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    // MARK: - Background-safe static helpers
    //
    // `recomputeFilteredEntries` runs off-main and calls these
    // `nonisolated static` helpers — they take pre-resolved inputs
    // (schedule pre-fetched on main) and avoid actor isolation.

    nonisolated private static func computeLinkedSegmentCountsStatic(
        for entries: [SessionArchiveEntry],
        entryById: [UUID: SessionArchiveEntry]
    ) -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for entry in entries {
            let count = normalizedSegmentCountStatic(for: entry, entryById: entryById)
            if count > 1 { counts[entry.sessionId] = count }
        }
        return counts
    }

    nonisolated private static func normalizedSegmentCountStatic(
        for entry: SessionArchiveEntry,
        entryById: [UUID: SessionArchiveEntry]
    ) -> Int {
        guard let linked = entry.linkedSessionIds, !linked.isEmpty else { return 1 }
        if let sleepSegments = entry.sleepSegmentCount, sleepSegments <= 1 { return 1 }
        let currentEnd = entry.endDate ?? entry.date
        guard currentEnd > entry.date else { return 1 }
        let linkedRanges = linkedSegmentInfos(linked, entryById: entryById)
        guard !linkedRanges.isEmpty else { return 1 }
        let normalized = SessionArchive.normalizedSplitNightSegments(
            currentSessionId: entry.sessionId,
            currentStartDate: entry.date,
            currentEndDate: currentEnd,
            linkedSegments: linkedRanges
        )
        return max(1, normalized.count)
    }

    /// The linked entries that describe a real span. Entries that are missing
    /// from the archive, or whose end doesn't advance past their start, carry
    /// no segment information and are dropped.
    nonisolated private static func linkedSegmentInfos(
        _ linked: [UUID], entryById: [UUID: SessionArchiveEntry]
    ) -> [LinkedSegmentInfo] {
        linked.compactMap { linkedId in
            guard let linkedEntry = entryById[linkedId] else { return nil }
            let linkedEnd = linkedEntry.endDate ?? linkedEntry.date
            guard linkedEnd > linkedEntry.date else { return nil }
            return LinkedSegmentInfo(
                id: linkedEntry.sessionId,
                startDate: linkedEntry.date,
                endDate: linkedEnd
            )
        }
    }

    nonisolated private static func collapseSameNightOvernightDuplicatesStatic(
        _ entries: [SessionArchiveEntry],
        entryById: [UUID: SessionArchiveEntry],
        schedule: SleepSchedule
    ) -> [SessionArchiveEntry] {
        let overnightEntries = entries.filter { $0.sessionType == .overnight }
        guard overnightEntries.count > 1 else { return entries }
        let grouped = Dictionary(grouping: overnightEntries) { entry in
            schedule.overnightWindowStart(relativeTo: entry.endDate ?? entry.date)
        }
        var idsToHide: Set<UUID> = []
        for (_, group) in grouped where group.count > 1 {
            idsToHide.formUnion(sameNightHiddenIds(group: group, entryById: entryById))
        }
        guard !idsToHide.isEmpty else { return entries }
        return entries.filter { !idsToHide.contains($0.sessionId) }
    }

    /// The losers of every duplicate cluster within one night's group.
    ///
    /// NEVER hide a same-night session that carries a real
    /// recovery score. The collapse exists to fold empty sync/placeholder
    /// duplicates, but hiding a SCORED session makes a real recovery "vanish"
    /// from History when a re-score flips which duplicate wins. Only collapse
    /// scoreless placeholders; if two same-night sessions both have real data,
    /// show both rather than silently dropping one.
    nonisolated private static func sameNightHiddenIds(
        group: [SessionArchiveEntry], entryById: [UUID: SessionArchiveEntry]
    ) -> Set<UUID> {
        let byId = Dictionary(group.map { ($0.sessionId, $0) }, uniquingKeysWith: { first, _ in first })
        var visited: Set<UUID> = []
        var idsToHide: Set<UUID> = []
        for seed in group where !visited.contains(seed.sessionId) {
            let component = duplicateComponent(seed: seed, group: group, byId: byId, visited: &visited)
            guard component.count > 1,
                  let winner = overnightWinner(component, entryById: entryById) else { continue }
            for entry in component where entry.sessionId != winner.sessionId && entry.recoveryScore == nil {
                idsToHide.insert(entry.sessionId)
            }
        }
        return idsToHide
    }

    /// Breadth-first walk over "looks like the same night" edges, starting at
    /// `seed`, marking everything it reaches as visited.
    nonisolated private static func duplicateComponent(
        seed: SessionArchiveEntry,
        group: [SessionArchiveEntry],
        byId: [UUID: SessionArchiveEntry],
        visited: inout Set<UUID>
    ) -> [SessionArchiveEntry] {
        var component: [SessionArchiveEntry] = []
        var queue: [UUID] = [seed.sessionId]
        while let currentId = queue.first {
            queue.removeFirst()
            guard !visited.contains(currentId),
                  let current = byId[currentId] else { continue }
            visited.insert(currentId)
            component.append(current)
            for candidate in group where !visited.contains(candidate.sessionId)
                && areLikelyDuplicateOvernightEntriesStatic(current, candidate) {
                queue.append(candidate.sessionId)
            }
        }
        return component
    }

    /// Richest entry wins: most normalized segments, then highest recovery
    /// score, then most links, then the later end — a stable total order so
    /// the same duplicate wins on every recompute.
    nonisolated private static func overnightWinner(
        _ component: [SessionArchiveEntry], entryById: [UUID: SessionArchiveEntry]
    ) -> SessionArchiveEntry? {
        component.max { lhs, rhs in
            let lhsSegments = normalizedSegmentCountStatic(for: lhs, entryById: entryById)
            let rhsSegments = normalizedSegmentCountStatic(for: rhs, entryById: entryById)
            if lhsSegments != rhsSegments { return lhsSegments < rhsSegments }
            let lhsScore = lhs.recoveryScore ?? 0
            let rhsScore = rhs.recoveryScore ?? 0
            if lhsScore != rhsScore { return lhsScore < rhsScore }
            let lhsLinked = lhs.linkedSessionIds?.count ?? 0
            let rhsLinked = rhs.linkedSessionIds?.count ?? 0
            if lhsLinked != rhsLinked { return lhsLinked < rhsLinked }
            let lhsEnd = lhs.endDate ?? lhs.date
            let rhsEnd = rhs.endDate ?? rhs.date
            if lhsEnd != rhsEnd { return lhsEnd < rhsEnd }
            return lhs.date < rhs.date
        }
    }

    nonisolated private static func areLikelyDuplicateOvernightEntriesStatic(
        _ lhs: SessionArchiveEntry,
        _ rhs: SessionArchiveEntry
    ) -> Bool {
        let lhsWindow = overnightWindowStatic(for: lhs)
        let rhsWindow = overnightWindowStatic(for: rhs)
        return windowsOverlapEnough(lhsWindow, rhsWindow) || isTinyArtifactOf(lhsWindow, rhsWindow)
    }

    /// Two sleep windows that start together, end together, or overlap for
    /// most of the shorter one's length are the same night recorded twice.
    nonisolated private static func windowsOverlapEnough(
        _ lhsWindow: (start: Date, end: Date, duration: TimeInterval),
        _ rhsWindow: (start: Date, end: Date, duration: TimeInterval)
    ) -> Bool {
        let overlapStart = max(lhsWindow.start, rhsWindow.start)
        let overlapEnd = min(lhsWindow.end, rhsWindow.end)
        let overlapSeconds = overlapEnd.timeIntervalSince(overlapStart)
        let overlaps = overlapSeconds > 0
        let startsClose = abs(lhsWindow.start.timeIntervalSince(rhsWindow.start)) <= HistoryConstants.closeWindowSeconds
        let endsClose = abs(lhsWindow.end.timeIntervalSince(rhsWindow.end)) <= HistoryConstants.closeWindowSeconds
        if (startsClose && endsClose) || (overlaps && (startsClose || endsClose)) {
            return true
        }
        let shorterDuration = min(lhsWindow.duration, rhsWindow.duration)
        guard shorterDuration > 0 else { return false }
        return overlapSeconds / shorterDuration >= HistoryConstants.overlapRatioThreshold
    }

    /// A very short window sitting at the tail of a long one is the tail of
    /// that recording, not a separate night.
    nonisolated private static func isTinyArtifactOf(
        _ lhsWindow: (start: Date, end: Date, duration: TimeInterval),
        _ rhsWindow: (start: Date, end: Date, duration: TimeInterval)
    ) -> Bool {
        let short = lhsWindow.duration <= rhsWindow.duration ? lhsWindow : rhsWindow
        let long = lhsWindow.duration <= rhsWindow.duration ? rhsWindow : lhsWindow
        guard short.duration > 0, short.duration <= HistoryConstants.tinyArtifactMaxDuration else {
            return false
        }
        let nearLongEnd =
            abs(short.start.timeIntervalSince(long.end)) <= HistoryConstants.nearEndTolerance ||
            abs(short.end.timeIntervalSince(long.end)) <= HistoryConstants.nearEndTolerance
        let shortWithinLongBounds =
            short.start >= long.start.addingTimeInterval(-HistoryConstants.artifactStartTolerance) &&
            short.end <= long.end.addingTimeInterval(HistoryConstants.artifactEndTolerance)
        return nearLongEnd && shortWithinLongBounds
    }

    nonisolated private static func overnightWindowStatic(for entry: SessionArchiveEntry) -> (start: Date, end: Date, duration: TimeInterval) {
        let start = entry.date
        let rawEnd = entry.endDate ?? entry.date
        let end = max(start, rawEnd)
        return (start: start, end: end, duration: end.timeIntervalSince(start))
    }
}
