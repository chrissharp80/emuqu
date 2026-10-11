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
    }

    /// Select the best data source from streaming and internal recording data.
    ///
    /// Both lists must be on the session's clock: a composite compares
    /// internal `t_ms` with streaming `wallClockMs` (ms since the stream
    /// started) directly, so callers first place a strap recording on the
    /// session's clock with `StrapRecording.points(onClockOf:)`.
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

    // MARK: - Private Methods

    private static func selectWithInternalAvailable(
        internalData: [RRPoint],
        streamingPoints: [RRPoint],
        hasValidStreaming: Bool,
        sessionId: UUID,
        sessionStart: Date
    ) -> SelectionResult {
        guard hasValidStreaming else {
            debugLog("[DataSourceSelector] Using internal recording (streaming failed)")
            return SelectionResult(points: internalData, sourceDescription: "internal", isComposite: false)
        }
        // Both succeeded — compare and decide.
        let comparison = compareDataSources(
            internalCount: internalData.count,
            streamingCount: streamingPoints.count
        )
        debugLog("[DataSourceSelector] Both recordings succeeded")
        debugLog("[DataSourceSelector] Beat count: internal=\(internalData.count) vs streaming=\(streamingPoints.count)")
        debugLog("[DataSourceSelector] Difference: \(comparison.beatDifference) beats (\(String(format: "%.1f", comparison.percentDifference))%)")
        guard comparison.shouldCreateComposite else {
            debugLog("[DataSourceSelector] Using internal recording (preferred)")
            return SelectionResult(points: internalData, sourceDescription: "internal", isComposite: false)
        }
        return compositeOrStreaming(
            internalData: internalData, streamingPoints: streamingPoints,
            sessionId: sessionId, sessionStart: sessionStart
        )
    }

    /// Internal has gaps — try a composite. If the composite can't be built,
    /// use streaming rather than silently falling back to the smaller internal
    /// dataset.
    private static func compositeOrStreaming(
        internalData: [RRPoint],
        streamingPoints: [RRPoint],
        sessionId: UUID,
        sessionStart: Date
    ) -> SelectionResult {
        debugLog("[DataSourceSelector] Internal has gaps - attempting composite creation")
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
    /// `mergeAddingOnlyUncoveredBeats`. Nil when the internal series has no
    /// gap streaming can fill.
    private static func createComposite(
        internalSeries: RRSeries,
        streamingSeries: RRSeries
    ) -> [RRPoint]? {
        let internalPoints = internalSeries.points
        let streamingPoints = streamingSeries.points
        guard !internalPoints.isEmpty, !streamingPoints.isEmpty else {
            debugLog("[DataSourceSelector] Cannot create composite: empty series")
            return nil
        }
        let gaps = findGaps(in: internalPoints)
        guard let fill = fillableGapSummary(gaps: gaps, streamingPoints: streamingPoints) else {
            return nil
        }
        let merged = mergePoints(internal: internalPoints, streaming: uncoveredBeats(streamingPoints, internal: internalPoints, gaps: gaps))
        debugLog("[DataSourceSelector] Composite complete: \(merged.count) beats — added \(merged.count - internalPoints.count) streaming beats, \(fill.beatsAdded) of them in \(fill.gapsFilled) gap(s)")
        return merged
    }

    /// Merges a streaming series into a device recording without doubling the
    /// beats both captured: streaming beats are kept only inside the device's
    /// gaps or outside the span it recorded.
    ///
    /// Both series must be on one clock: internal `t_ms` and streaming
    /// `wallClockMs` are compared directly, so the caller places a strap
    /// recording on the session's clock first (`StrapRecording.points(onClockOf:)`).
    static func mergeAddingOnlyUncoveredBeats(internal internalPoints: [RRPoint], streaming streamingPoints: [RRPoint]) -> [RRPoint] {
        let uncovered = uncoveredBeats(streamingPoints, internal: internalPoints, gaps: findGaps(in: internalPoints))
        return mergePoints(internal: internalPoints, streaming: uncovered)
    }

    /// The streaming beats the internal series does not cover: those inside
    /// one of its gaps or outside the span it recorded; all of them when it
    /// is empty. The stream's arrival-time clock rarely lands within the
    /// 50 ms duplicate window of the strap's own beats, so merging all of it
    /// would put nearly every covered beat in twice.
    private static func uncoveredBeats(_ streamingPoints: [RRPoint], internal internalPoints: [RRPoint], gaps: [GapInfo]) -> [RRPoint] {
        guard let first = internalPoints.first, let last = internalPoints.last else { return streamingPoints }
        return streamingPoints.filter { point in
            let time = streamTime(point)
            guard time >= first.t_ms, time <= last.endMs else { return true }
            return gaps.contains { time >= $0.startMs && time <= $0.endMs }
        }
    }

    /// Nil when there is nothing to gain from a composite: either the internal
    /// series has no significant gaps, or streaming can't cover any of them.
    private static func fillableGapSummary(gaps: [GapInfo], streamingPoints: [RRPoint]) -> (gapsFilled: Int, beatsAdded: Int)? {
        guard !gaps.isEmpty else {
            debugLog("[DataSourceSelector] No significant gaps found")
            return nil
        }
        debugLog("[DataSourceSelector] Found \(gaps.count) gap(s) to fill")
        let fill = countFillableBeats(gaps: gaps, streamingPoints: streamingPoints)
        guard fill.gapsFilled > 0 else {
            debugLog("[DataSourceSelector] No gaps could be filled from streaming")
            return nil
        }
        return fill
    }

    /// A gap is significant when the gap between one beat's end and the next
    /// beat's start runs more than 2 seconds past the expected RR interval.
    private static func findGaps(in internalPoints: [RRPoint]) -> [GapInfo] {
        guard internalPoints.count > 1 else { return [] }

        var gaps: [GapInfo] = []
        for i in 1 ..< internalPoints.count {
            let prevPoint = internalPoints[i - 1]
            let currPoint = internalPoints[i]
            let expectedGap = Int64(prevPoint.rr_ms)
            let actualGap = currPoint.t_ms - prevPoint.endMs
            if actualGap > expectedGap + 2000 {
                gaps.append(GapInfo(startMs: prevPoint.endMs, endMs: currPoint.t_ms, index: i))
            }
        }
        return gaps
    }

    /// How much of the gap set the streaming series can actually cover. Uses
    /// `wallClockMs` for streaming — raw `t_ms` drifts after BLE drops.
    private static func countFillableBeats(gaps: [GapInfo], streamingPoints: [RRPoint]) -> (gapsFilled: Int, beatsAdded: Int) {
        var gapsFilled = 0
        var beatsAdded = 0
        for gap in gaps {
            let fillPoints = streamingPoints.filter { point in
                let effectiveTime = streamTime(point)
                return effectiveTime >= gap.startMs && effectiveTime <= gap.endMs
            }
            guard !fillPoints.isEmpty else { continue }
            gapsFilled += 1
            beatsAdded += fillPoints.count
            debugLog("[DataSourceSelector] Gap \(gap.startMs / 1000)s-\(gap.endMs / 1000)s: filling with \(fillPoints.count) beats")
        }
        return (gapsFilled, beatsAdded)
    }

    /// Merge internal + streaming points using absolute-time alignment.
    /// Internal t_ms tracks real elapsed time (no BLE loss).
    /// Streaming t_ms drifts behind after BLE packet drops — use wallClockMs instead.
    /// Streaming gap-fill points have their t_ms rebased to wallClockMs for consistency.
    static func mergePoints(internal internalPoints: [RRPoint], streaming streamingPoints: [RRPoint]) -> [RRPoint] {
        var merged: [RRPoint] = []
        var internalIdx = 0
        var streamingIdx = 0
        while internalIdx < internalPoints.count || streamingIdx < streamingPoints.count {
            if internalIdx >= internalPoints.count {
                merged.append(rebased(streamingPoints[streamingIdx]))
                streamingIdx += 1
            } else if streamingIdx >= streamingPoints.count {
                merged.append(internalPoints[internalIdx])
                internalIdx += 1
            } else {
                takeEarlier(internalPoints, streamingPoints, &internalIdx, &streamingIdx, into: &merged)
            }
        }
        return merged
    }

    /// Append whichever head beat is earlier in wall-clock terms, then skip the
    /// other stream's duplicates of it.
    private static func takeEarlier(
        _ internalPoints: [RRPoint], _ streamingPoints: [RRPoint],
        _ internalIdx: inout Int, _ streamingIdx: inout Int,
        into merged: inout [RRPoint]
    ) {
        let internalTime = internalPoints[internalIdx].t_ms
        let streamingTime = streamTime(streamingPoints[streamingIdx])
        if internalTime <= streamingTime {
            merged.append(internalPoints[internalIdx])
            internalIdx += 1
            skipStreamingDuplicates(of: internalTime, in: streamingPoints, from: &streamingIdx)
        } else {
            merged.append(rebased(streamingPoints[streamingIdx]))
            streamingIdx += 1
            skipInternalDuplicates(of: streamingTime, in: internalPoints, from: &internalIdx)
        }
    }

    /// Real wall-clock time for a streaming beat, aligned with internal's t_ms.
    private static func streamTime(_ p: RRPoint) -> Int64 { p.wallClockMs ?? p.t_ms }

    /// A streaming gap-fill point with its t_ms rebased to wallClockMs for
    /// timeline consistency.
    private static func rebased(_ sp: RRPoint) -> RRPoint {
        RRPoint(t_ms: sp.wallClockMs ?? sp.t_ms, rr_ms: sp.rr_ms, wallClockMs: sp.wallClockMs, hr: sp.hr)
    }

    /// Skip every streaming point that falls within the duplicate-detection
    /// window of the internal beat just appended, not just the next one.
    /// Before this, a cluster of tightly-spaced streaming points (e.g. 10.01,
    /// 10.02, 10.03 relative to an internal at 10.00) would have only the first
    /// skipped and the rest leak into the composite as artificial beats.
    private static func skipStreamingDuplicates(of internalTime: Int64, in streamingPoints: [RRPoint], from idx: inout Int) {
        while idx < streamingPoints.count, abs(streamTime(streamingPoints[idx]) - internalTime) < duplicateToleranceMs {
            idx += 1
        }
    }

    /// The mirror of `skipStreamingDuplicates`, cluster-aware in the same way.
    private static func skipInternalDuplicates(of streamingTime: Int64, in internalPoints: [RRPoint], from idx: inout Int) {
        while idx < internalPoints.count, abs(internalPoints[idx].t_ms - streamingTime) < duplicateToleranceMs {
            idx += 1
        }
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
