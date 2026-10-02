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
    /// Taken from the original SleepData's splitGapMinutes × 3 to give users
    /// headroom (Pillow uses 6 h). Capped at 90 min.
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
    static func initial(from sleepData: SleepData) -> SleepTimelineState {
        let groups = SleepMergingPipeline.splitStageIntervalsByAwake(
            sleepData.stageIntervals, gap: Double(sleepData.splitGapMinutes) * 60
        )
        var segments: [Segment] = groups.compactMap { group in
            guard let first = group.first, let last = group.last else { return nil }
            return Segment(
                id: UUID(),
                start: first.start,
                end: last.end,
                intervals: group.sorted { $0.start < $1.start }
            )
        }
        if segments.isEmpty, let envelope = envelopeSegment(from: sleepData) {
            segments = [envelope]
        }
        return SleepTimelineState(segments: segments, edits: sleepData.edits)
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
        var seg = state.segments[idx]
        switch side {
        case .start:
            // Don't collapse the segment; keep at least 1 minute.
            seg.start = min(newTime, seg.end.addingTimeInterval(-60))
        case .end:
            seg.end = max(newTime, seg.start.addingTimeInterval(60))
        }
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

    private func applyingAddSegment(start: Date, end: Date) -> SleepTimelineState {
        guard end > start else { return self }
        var state = self
        let seg = Segment(
            id: UUID(),
            start: start,
            end: end,
            intervals: [HealthKitManager.SleepStageInterval(
                stage: .unspecified,
                start: start,
                end: end,
                provenance: .userAdded
            )]
        )
        state.segments.append(seg)
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
        var state = self
        for idx in state.segments.indices {
            var seg = state.segments[idx]
            // Skip segments that don't overlap.
            guard start < seg.end, end > seg.start else { continue }
            // Clip the carve window to the segment so we don't touch neighbors.
            let clippedStart = max(start, seg.start)
            let clippedEnd = min(end, seg.end)
            guard clippedEnd > clippedStart else { continue }
            seg.intervals = Self.carving(seg.intervals, from: clippedStart, to: clippedEnd)
            state.segments[idx] = seg
        }
        state.edits.append(SleepEditRecord(
            kind: .carveAwake,
            summary: "Carved \(Self.formatDuration(end.timeIntervalSince(start))) awake at \(Self.formatTime(start))"
        ))
        return state.normalized()
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
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes) min"
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
