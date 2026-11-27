import Foundation

/// Selects the best data source when both streaming and internal recording are available
/// Following Single Responsibility Principle: data source selection is separate from session management
enum DataSourceSelector {
    /// Minimum beats required for a valid data source
    static let minimumValidBeats = 120

    /// Percentage difference threshold for creating a composite
    static let compositeThresholdPercent = 5.0

    /// Two RR beats landing within this many wall-clock milliseconds from
    /// different sources (internal vs streaming) are treated as the same
    /// beat. Picked to be well under the shortest expected RR interval
    /// (~400ms at HR 150) so real beats never collapse, while catching
    /// timestamp jitter and clock skew between the device and phone.
    static let duplicateToleranceMs: Int64 = 50

    /// Result of data source selection
    struct SelectionResult {
        let points: [RRPoint]
        let sourceDescription: String
        let isComposite: Bool

        /// Normalized source key for dashboard display ("composite", "internal", or "streaming")
        var normalizedSource: String {
            if isComposite { return "composite" }
            if sourceDescription.contains("streaming") { return "streaming" }
            return "internal"
        }

        /// Whether the strap's recorded beats are in `points`: the internal
        /// recording alone, or merged with the stream.
        var usesDeviceBeats: Bool { isComposite || !sourceDescription.contains("streaming") }
    }

    /// Select the best data source from streaming and internal recording data.
    ///
    /// Both lists must count from the session's start, so callers first
    /// place a strap recording on the session's clock with
    /// `StrapRecording.points(onClockOf:)`; a composite then reads both on
    /// the real clock (`BeatTimeline`).
    /// - Parameters:
    ///   - streamingPoints: RR points collected via BLE streaming
    ///   - internalPoints: RR points fetched from H10 internal memory
    ///   - sessionId: Session ID for series construction
    ///   - sessionStart: Session start date
    /// - Returns: Selected data source with description, or nil if both sources failed
    static func selectBestSource(
        streamingPoints: [RRPoint],
        internalPoints: [RRPoint]?,
        sessionId: UUID,
        sessionStart: Date
    ) -> SelectionResult? {
        let hasValidStreaming = streamingPoints.count >= minimumValidBeats
        let hasValidInternal = (internalPoints?.count ?? 0) >= minimumValidBeats
        if let internalData = internalPoints, hasValidInternal {
            return selectWithInternalAvailable(
                internalData: internalData, streamingPoints: streamingPoints,
                hasValidStreaming: hasValidStreaming,
                sessionId: sessionId, sessionStart: sessionStart
            )
        }
        guard hasValidStreaming else {
            logBothSourcesFailed(streamingPoints: streamingPoints, internalPoints: internalPoints)
            return nil
        }
        debugLog("[DataSourceSelector] Using streaming data (internal failed)")
        return SelectionResult(points: streamingPoints, sourceDescription: "streaming (internal failed)", isComposite: false)
    }

    private static func logBothSourcesFailed(streamingPoints: [RRPoint], internalPoints: [RRPoint]?) {
        debugLog("[DataSourceSelector] Both data sources failed validation")
        debugLog("[DataSourceSelector] Streaming: \(streamingPoints.count) beats")
        debugLog("[DataSourceSelector] Internal: \(internalPoints?.count ?? 0) beats")
    }

    /// How far, on the real clock, the stream may run before the strap's
    /// recording starts or after it ends and still count as covered: the
    /// strap is armed moments after a stream starts, and the two clocks are
    /// stamped in whole seconds.
    static let spanSlackMs: Int64 = 60_000

    /// Whether the stream holds a stretch the strap's recording does not
    /// span: its first beat starts more than `spanSlackMs` before the
    /// recording's first, or its last more than that after the recording's
    /// end, on the real clock (`BeatTimeline`). A strap armed at a resume
    /// holds only what came after it, and one stopped early only what came
    /// before. Beat counts cannot tell: a recording of the last six hours
    /// can hold more beats than a stream of all eight.
    static func streamReachesPastRecording(internal internalPoints: [RRPoint], streaming streamingPoints: [RRPoint]) -> Bool {
        let device = timed(internalPoints)
        let streamed = timed(streamingPoints)
        guard let deviceFirst = device.first, let deviceLast = device.last,
              let streamFirst = streamed.first, let streamLast = streamed.last else { return false }
        let deviceEnd = deviceLast.timeMs + Int64(deviceLast.point.rr_ms)
        return streamFirst.timeMs < deviceFirst.timeMs - spanSlackMs || streamLast.timeMs > deviceEnd + spanSlackMs
    }

    // MARK: - Private Methods

    /// The strap's recording alone when it spans the stream and is not
    /// missing beats the stream has (`compareDataSources`); otherwise the
    /// stream fills what the recording lacks (`compositeOrStreaming`). A
    /// recording never replaces the stream outside the span it covers
    /// (`streamReachesPastRecording`), whatever either one's beat count, and
    /// a stream too short to stand on its own still keeps the beats outside
    /// that span.
    private static func selectWithInternalAvailable(
        internalData: [RRPoint],
        streamingPoints: [RRPoint],
        hasValidStreaming: Bool,
        sessionId: UUID,
        sessionStart: Date
    ) -> SelectionResult {
        let reachesPast = streamReachesPastRecording(internal: internalData, streaming: streamingPoints)
        let missingBeats = hasValidStreaming && logComparison(internalCount: internalData.count, streamingCount: streamingPoints.count)
        guard reachesPast || missingBeats else {
            debugLog("[DataSourceSelector] Using internal recording (\(hasValidStreaming ? "preferred" : "streaming failed"))")
            return SelectionResult(points: internalData, sourceDescription: "internal", isComposite: false)
        }
        if reachesPast { debugLog("[DataSourceSelector] The stream runs past the internal recording's span - keeping its beats outside it") }
        return compositeOrStreaming(
            internalData: internalData, streamingPoints: streamingPoints,
            sessionId: sessionId, sessionStart: sessionStart
        )
    }

    /// Compares both sources' beat counts, logs it, and returns whether the
    /// internal recording is missing beats the stream has.
    private static func logComparison(internalCount: Int, streamingCount: Int) -> Bool {
        let comparison = compareDataSources(internalCount: internalCount, streamingCount: streamingCount)
        debugLog("[DataSourceSelector] Both recordings succeeded")
        debugLog("[DataSourceSelector] Beat count: internal=\(internalCount) vs streaming=\(streamingCount)")
        debugLog("[DataSourceSelector] Difference: \(comparison.beatDifference) beats (\(String(format: "%.1f", comparison.percentDifference))%)")
        return comparison.shouldCreateComposite
    }

    /// Internal is missing beats streaming has — try a composite. If streaming
    /// adds nothing to it, use streaming rather than silently falling back to
    /// the smaller internal dataset.
    private static func compositeOrStreaming(
        internalData: [RRPoint],
        streamingPoints: [RRPoint],
        sessionId: UUID,
        sessionStart: Date
    ) -> SelectionResult {
        debugLog("[DataSourceSelector] Internal is missing beats - attempting composite creation")
        let internalSeries = RRSeries(points: internalData, sessionId: sessionId, startDate: sessionStart)
        let streamingSeries = RRSeries(points: streamingPoints, sessionId: sessionId, startDate: sessionStart)
        if let composite = createComposite(internalSeries: internalSeries, streamingSeries: streamingSeries) {
            debugLog("[DataSourceSelector] Composite created: \(composite.count) beats")
            return SelectionResult(
                points: composite,
                sourceDescription: "composite (internal + streaming gap-fill)",
                isComposite: true
            )
        }
        debugLog("[DataSourceSelector] Composite failed, using streaming (more beats: \(streamingPoints.count) vs internal: \(internalData.count))")
        return SelectionResult(points: streamingPoints, sourceDescription: "streaming (composite failed)", isComposite: false)
    }

    private static func compareDataSources(internalCount: Int, streamingCount: Int) -> DataSourceComparison {
        let beatDiff = abs(internalCount - streamingCount)
        let percentDiff = (Double(beatDiff) / Double(max(internalCount, streamingCount))) * 100.0

        let shouldComposite = internalCount < streamingCount && percentDiff > compositeThresholdPercent

        return DataSourceComparison(
            beatDifference: beatDiff,
            percentDifference: percentDiff,
            shouldCreateComposite: shouldComposite
        )
    }

    /// Create composite RR points by merging internal recording with streaming
    /// data: streaming fills the internal series' gaps and also supplies the
    /// beats before its first beat and after its last (a strap recording that
    /// started late or stopped early), the same rule as
    /// `mergeAddingOnlyUncoveredBeats`. Nil when streaming adds nothing: no
    /// beat in a gap it can fill and none outside the span the internal
    /// series recorded.
    ///
    /// Both series are read on the real clock (`BeatTimeline`): an H10's
    /// beat clock is real time, but a Verity Sense's runs behind it by every
    /// interval it rejected, and a stream's by every dropout, so neither raw
    /// clock can be compared with the other.
    private static func createComposite(
        internalSeries: RRSeries,
        streamingSeries: RRSeries
    ) -> [RRPoint]? {
        guard !internalSeries.points.isEmpty, !streamingSeries.points.isEmpty else {
            debugLog("[DataSourceSelector] Cannot create composite: empty series")
            return nil
        }
        let device = timed(internalSeries.points)
        let streamed = timed(streamingSeries.points)
        let gaps = findGaps(in: device)
        let fill = fillableGapSummary(gaps: gaps, streaming: streamed)
        let uncovered = uncoveredBeats(streamed, internal: device, gaps: gaps)
        guard !uncovered.isEmpty else {
            debugLog("[DataSourceSelector] Streaming adds no beat the internal series lacks")
            return nil
        }
        let merged = mergedOnRealClock(device, uncovered)
        debugLog("[DataSourceSelector] Composite complete: \(merged.count) beats — added \(merged.count - device.count) streaming beats, \(fill?.beatsAdded ?? 0) of them in \(fill?.gapsFilled ?? 0) gap(s)")
        return merged
    }

    /// Merges a streaming series into a device recording without doubling the
    /// beats both captured: streaming beats are kept only inside the device's
    /// gaps or outside the span it recorded.
    ///
    /// Both series must count from one start, so the caller places a strap
    /// recording on the session's clock first (`StrapRecording.points(onClockOf:)`);
    /// each is then read on the real clock (`BeatTimeline`).
    static func mergeAddingOnlyUncoveredBeats(internal internalPoints: [RRPoint], streaming streamingPoints: [RRPoint]) -> [RRPoint] {
        let device = timed(internalPoints)
        let uncovered = uncoveredBeats(timed(streamingPoints), internal: device, gaps: findGaps(in: device))
        return mergedOnRealClock(device, uncovered)
    }

    /// A beat and its start on the real clock (`BeatTimeline.ms`), read from
    /// the whole series it came in: a streamed beat's time depends on the
    /// batch it arrived with, which a filtered subset no longer holds.
    /// `batchPosition` counts the beats before it with the same recorded
    /// clock (the beats of one streamed batch share its arrival time).
    struct TimedBeat {
        let point: RRPoint
        let timeMs: Int64
        let batchPosition: Int
    }

    static func timed(_ points: [RRPoint]) -> [TimedBeat] {
        var position = 0
        return zip(points.indices, BeatTimeline.ms(points)).map { i, time in
            let sharesArrival = i > 0 && points[i].wallClockMs != nil && points[i].wallClockMs == points[i - 1].wallClockMs
            position = sharesArrival ? position + 1 : 0
            return TimedBeat(point: points[i], timeMs: time, batchPosition: position)
        }
    }

    /// The streaming beats the internal series does not cover: those inside
    /// one of its gaps or outside the span it recorded; all of them when it
    /// is empty. The stream's arrival-time clock rarely lands within the
    /// 50 ms duplicate window of the strap's own beats, so merging all of it
    /// would put nearly every covered beat in twice.
    private static func uncoveredBeats(_ streamed: [TimedBeat], internal device: [TimedBeat], gaps: [GapInfo]) -> [TimedBeat] {
        guard let first = device.first, let last = device.last else { return streamed }
        let endMs = last.timeMs + Int64(last.point.rr_ms)
        return streamed.filter { beat in
            guard beat.timeMs >= first.timeMs, beat.timeMs <= endMs else { return true }
            return gaps.contains { beat.timeMs >= $0.startMs && beat.timeMs <= $0.endMs }
        }
    }

    /// Nil when there is nothing to gain from a composite: either the internal
    /// series has no significant gaps, or streaming can't cover any of them.
    private static func fillableGapSummary(gaps: [GapInfo], streaming streamed: [TimedBeat]) -> (gapsFilled: Int, beatsAdded: Int)? {
        guard !gaps.isEmpty else {
            debugLog("[DataSourceSelector] No significant gaps found")
            return nil
        }
        debugLog("[DataSourceSelector] Found \(gaps.count) gap(s) to fill")
        let fill = countFillableBeats(gaps: gaps, streaming: streamed)
        guard fill.gapsFilled > 0 else {
            debugLog("[DataSourceSelector] No gaps could be filled from streaming")
            return nil
        }
        return fill
    }

    /// A gap is significant when, on the real clock, the time between one
    /// beat's end and the next beat's start runs more than 2 seconds past the
    /// expected RR interval. A Verity Sense recording's rejected intervals
    /// count here: its beat clock leaves them out, the real clock does not.
    private static func findGaps(in device: [TimedBeat]) -> [GapInfo] {
        guard device.count > 1 else { return [] }
        var gaps: [GapInfo] = []
        for i in 1 ..< device.count {
            let previousEnd = device[i - 1].timeMs + Int64(device[i - 1].point.rr_ms)
            if device[i].timeMs - previousEnd > Int64(device[i - 1].point.rr_ms) + 2000 {
                gaps.append(GapInfo(startMs: previousEnd, endMs: device[i].timeMs, index: i))
            }
        }
        return gaps
    }

    /// How much of the gap set the streaming series can actually cover, on
    /// the real clock: raw `t_ms` drifts after BLE drops.
    private static func countFillableBeats(gaps: [GapInfo], streaming streamed: [TimedBeat]) -> (gapsFilled: Int, beatsAdded: Int) {
        var gapsFilled = 0
        var beatsAdded = 0
        for gap in gaps {
            let fillCount = streamed.count(where: { $0.timeMs >= gap.startMs && $0.timeMs <= gap.endMs })
            guard fillCount > 0 else { continue }
            gapsFilled += 1
            beatsAdded += fillCount
            debugLog("[DataSourceSelector] Gap \(gap.startMs / 1000)s-\(gap.endMs / 1000)s: filling with \(fillCount) beats")
        }
        return (gapsFilled, beatsAdded)
    }

    /// Merge two series of one night on the real clock (`BeatTimeline`): in
    /// time order, a beat of `streaming` that is the same beat as one of
    /// `internal` (`isSameBeat`) left out, and every beat's `t_ms` set to its
    /// real start, so the result's beat clock never steps back or repeats
    /// (beats of one streamed batch share one arrival time; a Verity Sense
    /// recording's beat clock runs behind the stream's arrival clock).
    /// The internal series' beats are kept where both hold one.
    static func mergePoints(internal internalPoints: [RRPoint], streaming streamingPoints: [RRPoint]) -> [RRPoint] {
        mergedOnRealClock(timed(internalPoints), timed(streamingPoints))
    }

    private static func mergedOnRealClock(_ primary: [TimedBeat], _ secondary: [TimedBeat]) -> [RRPoint] {
        interleaved(primary, secondary).map { $0.point.retimed(t_ms: $0.timeMs, wallClockMs: $0.point.wallClockMs) }
    }

    /// Both lists in real-clock order. Before each primary beat is placed,
    /// every secondary beat that is the same beat as it is skipped, so a
    /// cluster of copies of one beat leaves none behind.
    private static func interleaved(_ primary: [TimedBeat], _ secondary: [TimedBeat]) -> [TimedBeat] {
        var merged: [TimedBeat] = []
        merged.reserveCapacity(primary.count + secondary.count)
        var (p, s) = (0, 0)
        while p < primary.count || s < secondary.count {
            if p < primary.count { skipCopies(of: primary[p], in: secondary, from: &s) }
            let takePrimary = s >= secondary.count || (p < primary.count && primary[p].timeMs <= secondary[s].timeMs)
            if takePrimary {
                merged.append(primary[p])
                p += 1
            } else {
                merged.append(secondary[s])
                s += 1
            }
        }
        return merged
    }

    private static func skipCopies(of beat: TimedBeat, in beats: [TimedBeat], from index: inout Int) {
        while index < beats.count, isSameBeat(beats[index], beat) {
            index += 1
        }
    }

    /// Whether two beats from two copies of a night are one heartbeat. Two
    /// beats that both carry a recorded clock are compared on it, like with
    /// like: the same interval at the same recorded time and the same place
    /// in its batch. Their beat clocks may differ (a composite set a streamed
    /// beat's to its real start, the stream's own copy kept the running
    /// sum), and so may their real-clock times near the end of a shorter
    /// copy, which has fewer later batches to time its last beats from.
    /// Otherwise their real-clock times are within `duplicateToleranceMs`.
    static func isSameBeat(_ lhs: TimedBeat, _ rhs: TimedBeat) -> Bool {
        guard let lhsWall = lhs.point.wallClockMs, let rhsWall = rhs.point.wallClockMs else {
            return abs(lhs.timeMs - rhs.timeMs) < duplicateToleranceMs
        }
        return abs(lhsWall - rhsWall) < duplicateToleranceMs && lhs.point.rr_ms == rhs.point.rr_ms
            && lhs.batchPosition == rhs.batchPosition
    }
}

// MARK: - Supporting Types

private struct DataSourceComparison {
    let beatDifference: Int
    let percentDifference: Double
    let shouldCreateComposite: Bool
}

private struct GapInfo {
    let startMs: Int64
    let endMs: Int64
    let index: Int
}
