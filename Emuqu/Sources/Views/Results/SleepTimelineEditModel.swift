import Foundation

/// Pure, value-semantics edit model for the sleep timeline editor.
///
/// Every user gesture produces an `Edit`. Applying an edit returns a new
/// `State`, which is pushed onto the undo stack. This keeps render, gesture,
/// and persistence code free of mutation logic and lets us unit-test the
/// transforms without any UI.
enum SleepTimelineEdit: Equatable {
    /// Move one boundary of a segment.
    case adjustBoundary(segmentId: UUID, side: Side, newTime: Date)
    /// Add a user-declared sleep segment. Stages are `.unspecified` so
    /// scoring counts total sleep time but not stage sub-scores.
    case addSegment(start: Date, end: Date)
    /// Remove an entire segment and the intervals inside it.
    case removeSegment(segmentId: UUID)
    /// Split a segment at `atTime`, producing two segments.
    case split(segmentId: UUID, atTime: Date)
    /// Merge two adjacent segments. Refused when the gap exceeds
    /// `maxMergeGapMinutes`.
    case merge(leftId: UUID, rightId: UUID)
    /// Punch awake time across `[start, end]`. Intervals overlapping the
    /// window are clipped and a user-carved awake interval is inserted.
    case carveAwake(start: Date, end: Date)

    enum Side: String, Equatable { case start, end }
}

/// Snapshot of what the editor is about to save. Mirrors the inputs the
/// rebuild function needs without depending on SwiftUI types.
struct SleepTimelineState: Equatable {
    /// One visible segment on the timeline. Identified by a stable UUID
    /// assigned at load time; preserved across `adjustBoundary` edits.
    struct Segment: Equatable {
        let id: UUID
        var start: Date
        var end: Date
        /// Stage intervals belonging to this segment (must lie within
        /// `[start, end]`). Sorted by start time.
        var intervals: [HealthKitManager.SleepStageInterval]
    }

    var segments: [Segment]
    /// Accumulated edit history — replayed into the persisted `SleepData.edits`
    /// on save.
    var edits: [SleepEditRecord]

    /// Gap, in minutes, at-or-below-which two adjacent segments can be merged.
    static let maxMergeGapMinutes = 60

    /// Minimum edit precision — edits snap to 1-minute boundaries.
    static let snapSeconds: TimeInterval = 60

    /// Content equality that IGNORES the per-segment/-interval UUIDs.
    /// `initial(from:)` mints a fresh `UUID()` per segment (and HealthKit mints
    /// fresh interval ids on every query), so the synthesized `Equatable` on
    /// `SleepTimelineState` reports "changed" even when the timeline is
    /// byte-identical. The editor's "did the user actually edit anything?"
    /// gate must compare the SHAPE of the timeline — segment boundaries, stage
    /// intervals, and edit count — not identities. Without this, tapping "Done"
    /// after merely viewing sleep still persists a spurious `sleepUserAdjusted`.
    func hasSameContent(as other: SleepTimelineState) -> Bool {
        guard segments.count == other.segments.count,
              edits.count == other.edits.count else { return false }
        for (a, b) in zip(segments, other.segments) {
            guard a.start == b.start, a.end == b.end,
                  a.intervals.count == b.intervals.count else { return false }
            for (ia, ib) in zip(a.intervals, b.intervals)
            where ia.stage != ib.stage || ia.start != ib.start || ia.end != ib.end {
                return false
            }
        }
        return true
    }
}

extension SleepTimelineState {
    /// Build the initial state from the user's current SleepData. Groups the
    /// HealthKit intervals into segments using the existing split heuristic,
    /// so the editor starts exactly where the current app already draws
    /// segments.
    ///
    /// Every interval lands in a segment. The heuristic leaves out the awake
    /// stretch that separates two segments, a long awake stretch before the
    /// first sleep, and a short sleep after a long final awakening; Done saves
    /// only what the segments hold, so leaving those out would cut sleep,
    /// awake and time in bed from a night the user never touched. Each one
    /// joins the segment it follows (or the first segment, when it comes
    /// before all of them).
    static func initial(from sleepData: SleepData) -> SleepTimelineState {
        let intervals = sleepData.stageIntervals.sorted { $0.start < $1.start }
        let groups = SleepMergingPipeline.splitStageIntervalsByAwake(
            intervals, gap: Double(sleepData.splitGapMinutes) * 60
        )
        var segments = groups.compactMap(segment(spanning:))
        let grouped = Set(groups.joined().map(\.id))
        for interval in intervals where !grouped.contains(interval.id) {
            segments = attaching(interval, to: segments)
        }
        if segments.isEmpty, let envelope = envelopeSegment(from: sleepData) {
            segments = [envelope]
        }
        return SleepTimelineState(segments: segments, edits: sleepData.edits)
    }

    /// A segment exactly covering `intervals`, or nil when there are none.
    private static func segment(spanning intervals: [HealthKitManager.SleepStageInterval]) -> Segment? {
        guard let start = intervals.map(\.start).min(), let end = intervals.map(\.end).max() else { return nil }
        return Segment(id: UUID(), start: start, end: end, intervals: intervals.sorted { $0.start < $1.start })
    }

    /// `segments` with `interval` added to the last segment starting at or
    /// before it — else the first — widened to cover it. With no segments,
    /// the interval starts one.
    private static func attaching(
        _ interval: HealthKitManager.SleepStageInterval,
        to segments: [Segment]
    ) -> [Segment] {
        guard !segments.isEmpty else {
            return [Segment(id: UUID(), start: interval.start, end: interval.end, intervals: [interval])]
        }
        var segments = segments
        let idx = segments.lastIndex { $0.start <= interval.start } ?? 0
        segments[idx].start = min(segments[idx].start, interval.start)
        segments[idx].end = max(segments[idx].end, interval.end)
        segments[idx].intervals = (segments[idx].intervals + [interval]).sorted { $0.start < $1.start }
        return segments
    }

    /// Fall back to a single segment from the sleepStart/sleepEnd envelope when
    /// no intervals are available (strap-only night, or HealthKit empty).
    private static func envelopeSegment(from sleepData: SleepData) -> Segment? {
        guard let start = sleepData.sleepStart, let end = sleepData.sleepEnd, end > start else { return nil }
        return Segment(id: UUID(), start: start, end: end, intervals: [])
    }
}

// MARK: - Transforms

extension SleepTimelineState {
    /// Apply a single edit and return the new state. Returns `self` unchanged
    /// when the edit is rejected (e.g. gap too large to merge). Rejection is
    /// silent by design — the caller decides whether to surface a reason.
    func applying(_ edit: SleepTimelineEdit) -> SleepTimelineState {
        switch edit {
        case let .adjustBoundary(id, side, newTime):
            applyingAdjustBoundary(id: id, side: side, newTime: snap(newTime))
        case let .addSegment(start, end):
            applyingAddSegment(start: snap(start), end: snap(end))
        case let .removeSegment(id):
            applyingRemoveSegment(id: id)
        case let .split(id, at):
            applyingSplit(id: id, at: snap(at))
        case let .merge(left, right):
            applyingMerge(leftId: left, rightId: right)
        case let .carveAwake(start, end):
            applyingCarveAwake(start: snap(start), end: snap(end))
        }
    }

    private func snap(_ date: Date) -> Date {
        let t = date.timeIntervalSinceReferenceDate
        let snapped = (t / SleepTimelineState.snapSeconds).rounded() * SleepTimelineState.snapSeconds
        return Date(timeIntervalSinceReferenceDate: snapped)
    }

    private func applyingAdjustBoundary(id: UUID, side: SleepTimelineEdit.Side, newTime: Date) -> SleepTimelineState {
        var state = self
        guard let idx = state.segments.firstIndex(where: { $0.id == id }) else { return self }
        var seg = clampedBoundary(state.segments[idx], side: side, newTime: newTime)
        guard seg.end > seg.start else { return self }
        // Clip intervals to the new segment window. `clipIntervals` preserves
        // provenance, so Watch-origin intervals whose timestamps weren't
        // actually trimmed keep their original source.
        seg.intervals = SleepMergingPipeline.clipIntervals(seg.intervals, to: seg.start, end: seg.end)
        state.segments[idx] = seg
        state.edits.append(SleepEditRecord(
            kind: .adjustBoundary,
            summary: "\(side == .start ? "Start" : "End") moved to \(Self.formatTime(newTime))"
        ))
        return state.normalized()
    }

    /// Only the parts of `[start, end]` not already covered by a segment are
    /// added, so declaring sleep over an existing stretch never counts it twice.
    private func applyingAddSegment(start: Date, end: Date) -> SleepTimelineState {
        guard end > start else { return self }
        let pieces = uncoveredRanges(from: start, to: end)
        guard !pieces.isEmpty else { return self }
        var state = self
        state.segments.append(contentsOf: pieces.map { Self.userSegment(start: $0.start, end: $0.end) })
        state.edits.append(SleepEditRecord(
            kind: .addSegment,
            summary: "Added \(Self.formatDuration(end.timeIntervalSince(start))) at \(Self.formatTime(start))"
        ))
        return state.normalized()
    }

    private func applyingRemoveSegment(id: UUID) -> SleepTimelineState {
        guard let idx = segments.firstIndex(where: { $0.id == id }) else { return self }
        var state = self
        let removed = state.segments.remove(at: idx)
        state.edits.append(SleepEditRecord(
            kind: .removeSegment,
            summary: "Removed \(Self.formatDuration(removed.end.timeIntervalSince(removed.start))) at \(Self.formatTime(removed.start))"
        ))
        return state
    }

    private func applyingSplit(id: UUID, at: Date) -> SleepTimelineState {
        guard let idx = segments.firstIndex(where: { $0.id == id }) else { return self }
        let seg = segments[idx]
        guard at > seg.start.addingTimeInterval(60), at < seg.end.addingTimeInterval(-60) else { return self }

        let leftIntervals = SleepMergingPipeline.clipIntervals(seg.intervals, to: seg.start, end: at)
        let rightIntervals = SleepMergingPipeline.clipIntervals(seg.intervals, to: at, end: seg.end)
        let left = Segment(id: UUID(), start: seg.start, end: at, intervals: leftIntervals)
        let right = Segment(id: UUID(), start: at, end: seg.end, intervals: rightIntervals)

        var state = self
        state.segments.remove(at: idx)
        state.segments.insert(contentsOf: [left, right], at: idx)
        state.edits.append(SleepEditRecord(
            kind: .split,
            summary: "Split at \(Self.formatTime(at))"
        ))
        return state.normalized()
    }

    private func applyingMerge(leftId: UUID, rightId: UUID) -> SleepTimelineState {
        guard let leftIdx = segments.firstIndex(where: { $0.id == leftId }),
              let rightIdx = segments.firstIndex(where: { $0.id == rightId }) else { return self }
        let (aIdx, bIdx) = leftIdx < rightIdx ? (leftIdx, rightIdx) : (rightIdx, leftIdx)
        let a = segments[aIdx]
        let b = segments[bIdx]
        let gapMinutes = Int(b.start.timeIntervalSince(a.end) / 60)
        guard gapMinutes >= 0, gapMinutes <= SleepTimelineState.maxMergeGapMinutes else { return self }
        let merged = Segment(
            id: UUID(),
            start: a.start,
            end: b.end,
            intervals: (a.intervals + b.intervals).sorted { $0.start < $1.start }
        )
        var state = self
        // Remove the higher index first so the lower one stays valid.
        state.segments.remove(at: bIdx)
        state.segments.remove(at: aIdx)
        state.segments.insert(merged, at: aIdx)
        state.edits.append(SleepEditRecord(kind: .merge, summary: "Merged segments (gap \(gapMinutes) min)"))
        return state.normalized()
    }

    private func applyingCarveAwake(start: Date, end: Date) -> SleepTimelineState {
        guard end > start else { return self }
        // Marking awake over no sleep changes nothing, so it records no edit.
        guard let carved = segmentsCarving(start: start, end: end) else { return self }
        var state = self
        state.segments = carved
        state.edits.append(SleepEditRecord(
            kind: .carveAwake,
            summary: "Carved \(Self.formatDuration(end.timeIntervalSince(start))) awake at \(Self.formatTime(start))"
        ))
        return state.normalized()
    }

    /// The segments with the window marked awake, each clipped to its own
    /// bounds so neighbours are untouched. Nil when the window overlaps none.
    private func segmentsCarving(start: Date, end: Date) -> [Segment]? {
        var segments = self.segments
        var touchedAny = false
        for idx in segments.indices {
            let clippedStart = max(start, segments[idx].start)
            let clippedEnd = min(end, segments[idx].end)
            guard clippedEnd > clippedStart else { continue }
            segments[idx].intervals = Self.carving(segments[idx].intervals, from: clippedStart, to: clippedEnd)
            touchedAny = true
        }
        return touchedAny ? segments : nil
    }

    /// Walk intervals: keep the portion before, keep the portion after, drop
    /// the middle, insert one user-carved awake interval.
    private static func carving(
        _ intervals: [HealthKitManager.SleepStageInterval],
        from clippedStart: Date,
        to clippedEnd: Date
    ) -> [HealthKitManager.SleepStageInterval] {
        var rebuilt: [HealthKitManager.SleepStageInterval] = []
        for interval in intervals {
            if interval.end <= clippedStart || interval.start >= clippedEnd {
                rebuilt.append(interval)
                continue
            }
            rebuilt.append(contentsOf: remnants(of: interval, clippedStart: clippedStart, clippedEnd: clippedEnd))
        }
        rebuilt.append(HealthKitManager.SleepStageInterval(
            stage: .awake, start: clippedStart, end: clippedEnd, provenance: .userCarved
        ))
        return rebuilt.sorted { $0.start < $1.start }
    }

    /// The head and/or tail of an interval that the carve window bisects.
    private static func remnants(
        of interval: HealthKitManager.SleepStageInterval,
        clippedStart: Date,
        clippedEnd: Date
    ) -> [HealthKitManager.SleepStageInterval] {
        var out: [HealthKitManager.SleepStageInterval] = []
        if interval.start < clippedStart {
            out.append(HealthKitManager.SleepStageInterval(
                stage: interval.stage, start: interval.start, end: clippedStart, provenance: interval.provenance
            ))
        }
        if interval.end > clippedEnd {
            out.append(HealthKitManager.SleepStageInterval(
                stage: interval.stage, start: clippedEnd, end: interval.end, provenance: interval.provenance
            ))
        }
        return out
    }

    /// Moves one boundary, keeping at least 1 minute and never pushing into a
    /// neighbouring segment: overlapping segments would count the same sleep
    /// twice on save.
    private func clampedBoundary(_ seg: Segment, side: SleepTimelineEdit.Side, newTime: Date) -> Segment {
        var seg = seg
        switch side {
        case .start:
            let floor = previousNeighborEnd(before: seg) ?? .distantPast
            seg.start = max(floor, min(newTime, seg.end.addingTimeInterval(-60)))
        case .end:
            let ceiling = nextNeighborStart(after: seg) ?? .distantFuture
            seg.end = min(ceiling, max(newTime, seg.start.addingTimeInterval(60)))
        }
        return seg
    }

    /// A user-declared stretch: one `.unspecified` interval, so it counts toward
    /// total sleep but not toward stage sub-scores.
    private static func userSegment(start: Date, end: Date) -> Segment {
        Segment(
            id: UUID(),
            start: start,
            end: end,
            intervals: [HealthKitManager.SleepStageInterval(
                stage: .unspecified, start: start, end: end, provenance: .userAdded
            )]
        )
    }

    /// End of the nearest segment that starts before `seg`.
    private func previousNeighborEnd(before seg: Segment) -> Date? {
        segments.filter { $0.id != seg.id && $0.start < seg.start }.map(\.end).max()
    }

    /// Start of the nearest segment that starts after `seg`.
    private func nextNeighborStart(after seg: Segment) -> Date? {
        segments.filter { $0.id != seg.id && $0.start > seg.start }.map(\.start).min()
    }

    /// Sub-ranges of `[start, end]` that no existing segment covers, each at
    /// least one minute long.
    private func uncoveredRanges(from start: Date, to end: Date) -> [(start: Date, end: Date)] {
        var pieces: [(start: Date, end: Date)] = []
        var cursor = start
        for seg in segments.sorted(by: { $0.start < $1.start }) where seg.end > cursor && seg.start < end {
            if seg.start > cursor { pieces.append((cursor, seg.start)) }
            cursor = max(cursor, seg.end)
        }
        if cursor < end { pieces.append((cursor, end)) }
        return pieces.filter { $0.end.timeIntervalSince($0.start) >= SleepTimelineState.snapSeconds }
    }

    /// Sort segments by start; clip any stray intervals that leak outside
    /// their segment window (defense-in-depth against transform bugs).
    private func normalized() -> SleepTimelineState {
        var state = self
        state.segments.sort { $0.start < $1.start }
        for idx in state.segments.indices {
            var seg = state.segments[idx]
            seg.intervals = SleepMergingPipeline.clipIntervals(
                seg.intervals, to: seg.start, end: seg.end
            )
            state.segments[idx] = seg
        }
        return state
    }
}

// MARK: - Formatting

extension SleepTimelineState {
    static func formatTime(_ date: Date) -> String {
        LocalizedDateFormat.string(from: date, template: "jmm")
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes >= 60 { return LocalizedDuration.hoursMinutes(minutes: minutes) }
        return LocalizedDuration.minutes(minutes)
    }
}

// MARK: - Undo Stack

/// Bounded undo stack — 5 entries (Sleep-as-Android precedent).
struct SleepTimelineUndoStack {
    private var entries: [SleepTimelineState] = []
    private let limit = 5

    var canUndo: Bool {
        !entries.isEmpty
    }

    mutating func push(_ state: SleepTimelineState) {
        entries.append(state)
        if entries.count > limit { entries.removeFirst() }
    }

    mutating func pop() -> SleepTimelineState? {
        entries.popLast()
    }

    mutating func clear() {
        entries.removeAll()
    }
}
