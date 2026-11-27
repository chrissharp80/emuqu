import Foundation

// MARK: - Window Evaluation & Scanning

extension WindowSelector {
    /// The index range to scan and the window geometry to scan it with.
    struct ScanGrid {
        let bandStart: Int
        let bandEnd: Int
        let windowSize: Int
        let stepSize: Int
    }

    /// Scan a range of the series, evaluating windows at regular intervals.
    /// Windows start every `stepSize` beats from `bandStart`; each holds at
    /// least `windowSize` beats and runs on until it spans
    /// `config.minWindowSpanMs` (`timeFlooredEnd`), so a full window is a
    /// five-minute short-term recording at any heart rate. A band too short
    /// to hold one such window is scanned on beat count alone, so a short
    /// night is still measured; the acceptance rule then reads its span.
    /// `artifactRateLimit` overrides `config.maxArtifactRate` when supplied —
    /// `scanBandWithArtifactFallback` uses this to run a strict 10% pass
    /// first, falling back to the permissive 15% cutoff only if the strict
    /// pass yields no organized windows (`findBestWindow`) or no windows at
    /// all (`findPeakMetricWindow`).
    func scanWindows(
        series: RRSeries,
        flags: [ArtifactFlags],
        grid: ScanGrid,
        sessionStartMs: Int64,
        sessionEndMs: Int64,
        artifactRateLimit: Double? = nil
    ) -> [ScoredRecoveryBlock] {
        windowRanges(points: series.points, grid: grid).compactMap { range in
            evaluateWindow(
                series: series, flags: flags,
                startIdx: range.lowerBound, endIdx: range.upperBound,
                sessionStartMs: sessionStartMs, sessionEndMs: sessionEndMs,
                artifactRateLimit: artifactRateLimit
            )
        }
    }

    /// The index ranges `scanWindows` evaluates, in start order.
    func windowRanges(points: [RRPoint], grid: ScanGrid) -> [Range<Int>] {
        let timed = grid.bandEnd > grid.bandStart
            && Self.spanMs(points, grid.bandStart ..< grid.bandEnd) >= config.minWindowSpanMs
        var ranges: [Range<Int>] = []
        var start = grid.bandStart
        while let end = timed
            ? timeFlooredEnd(points: points, start: start, minEnd: start + grid.windowSize, limit: grid.bandEnd)
            : (start + grid.windowSize <= grid.bandEnd ? start + grid.windowSize : nil) {
            ranges.append(start ..< end)
            start += grid.stepSize
        }
        return ranges
    }

    /// The exclusive end of the window that starts at `start`: at least
    /// `minEnd`, extended beat by beat until the window spans
    /// `config.minWindowSpanMs`. Nil when that end would pass `limit`.
    func timeFlooredEnd(points: [RRPoint], start: Int, minEnd: Int, limit: Int) -> Int? {
        guard start < minEnd, minEnd <= limit, limit <= points.count else { return nil }
        var end = minEnd
        while Self.spanMs(points, start ..< end) < config.minWindowSpanMs {
            guard end < limit else { return nil }
            end += 1
        }
        return end
    }

    /// The time a run of beats covers, from the start of its first beat to
    /// the end of its last (`RRPoint.endMs`): the length the Task Force
    /// short-term recording and `HRVConstants.MinimumDuration` are written
    /// in. `range` is non-empty and inside `points`.
    static func spanMs(_ points: [RRPoint], _ range: Range<Int>) -> Int64 {
        points[range.upperBound - 1].endMs - points[range.lowerBound].t_ms
    }

    /// One window's slice of the series, already bounds-checked.
    struct WindowSlice {
        let points: [RRPoint]
        let flags: [ArtifactFlags]
        let startIdx: Int
        let endIdx: Int
    }

    /// Evaluate a single window, filtering ectopic beats individually
    /// Also calculates relative position within sleep episode for temporal representativeness
    func evaluateWindow(
        series: RRSeries,
        flags: [ArtifactFlags],
        startIdx: Int,
        endIdx: Int,
        sessionStartMs: Int64,
        sessionEndMs: Int64,
        artifactRateLimit: Double? = nil
    ) -> ScoredRecoveryBlock? {
        guard let slice = windowSlice(series: series, flags: flags, startIdx: startIdx, endIdx: endIdx) else {
            return nil
        }
        let (rrValues, artifactRate) = extractValidRRValues(
            windowPoints: slice.points, windowFlags: slice.flags, startIdx: startIdx
        )
        let effectiveLimit = artifactRateLimit ?? config.maxArtifactRate
        guard validateArtifactRate(artifactRate, limit: effectiveLimit, windowPointCount: slice.points.count) else { return nil }
        guard rrValues.count >= 50 else {
            debugLog("[WindowSelector] evaluateWindow REJECTED: only \(rrValues.count) valid RR values (need ≥50)")
            return nil
        }
        guard let clean = cleanBeats(rrValues: rrValues, windowPoints: slice.points, series: series, range: startIdx ..< endIdx) else { return nil }
        return scoredBlock(
            slice: slice, rrValues: rrValues, artifactRate: artifactRate,
            clean: clean, sessionStartMs: sessionStartMs, sessionEndMs: sessionEndMs
        )
    }

    /// The points and flags covering `startIdx ..< endIdx`, or nil when those
    /// indices can't address the series.
    ///
    /// Defensive bounds check. A recovered/interrupted session can have a
    /// `flags` array shorter than `points` (artifact detection ran on a
    /// partial backup), so `min(endIdx, flags.count)` < `startIdx` for any
    /// window past the flags array's tail, and slicing `flags` would trap
    /// ("Range requires lowerBound <= upperBound").
    /// Reject the window cleanly instead of crashing the whole
    /// window-selection pass — the recovery score path tolerates
    /// missing windows.
    private func windowSlice(
        series: RRSeries, flags: [ArtifactFlags], startIdx: Int, endIdx: Int
    ) -> WindowSlice? {
        let points = series.points
        guard startIdx >= 0, endIdx > startIdx, endIdx <= points.count else {
            debugLog("[WindowSelector] evaluateWindow REJECTED: invalid bounds startIdx=\(startIdx) endIdx=\(endIdx) points.count=\(points.count)", level: .warning)
            return nil
        }
        // Flags array can be shorter than points (partial artifact
        // detection on a recovered session). Clamp BOTH bounds.
        let flagsUpper = min(endIdx, flags.count)
        let flagsLower = min(startIdx, flagsUpper)
        return WindowSlice(
            points: Array(points[startIdx ..< endIdx]),
            flags: Array(flags[flagsLower ..< flagsUpper]),
            startIdx: startIdx, endIdx: endIdx
        )
    }

    /// A window's ectopic-filtered beats and the RMSSD over its adjacent kept
    /// pairs (`maskedRMSSD`). `beats` keeps each beat's series index and the
    /// window's recording breaks, so the window's DFA α1 interpolates the
    /// beats removed here and never boxes across a break
    /// (`DFAAnalyzer.compute(window:)`, as for the reported α1).
    struct CleanBeats {
        let beats: CleanBeatWindow
        let rmssd: Double

        var rrs: [Double] { beats.rr }
    }

    /// Ectopic-filtered beats, or nil when too few survive. The gate is
    /// `TimeDomainAnalyzer.ectopicKeepMask`, the one the reported RMSSD uses,
    /// so the window is chosen on the beats it then reports. The floor adapts
    /// downward for short windows so a 200-beat window isn't held to the same
    /// absolute count as a 600-beat one.
    ///
    /// No difference is taken across a recording break or a beat the sensor
    /// removed an interval before (`TimeDomainAnalyzer.isAdjacentBeat`); DFA
    /// splits only at the breaks (`CleanBeatWindow`).
    private func cleanBeats(
        rrValues: [(index: Int, rr: Double)], windowPoints: [RRPoint], series: RRSeries, range: Range<Int>
    ) -> CleanBeats? {
        let kept = TimeDomainAnalyzer.ectopicKeepMask(rrValues.map(\.rr))
        let keptValues = zip(rrValues, kept).filter { $0.1 }.map { $0.0 }
        let cleanRRs = keptValues.map(\.rr)
        let adaptiveMinCleanBeats = min(config.minCleanBeats, max(50, Int(Double(windowPoints.count) * 0.75)))
        guard cleanRRs.count >= adaptiveMinCleanBeats else {
            debugLog("[WindowSelector] evaluateWindow REJECTED: only \(cleanRRs.count) clean beats (need ≥\(adaptiveMinCleanBeats)), \(rrValues.count - cleanRRs.count) ectopic removed")
            return nil
        }
        let breaks = TimeDomainAnalyzer.beatsAfterRecordingBreak(in: series.points, range: range)
        let removed = TimeDomainAnalyzer.beatsAfterRemovedBeat(in: series.points, range: range)
        return CleanBeats(
            beats: CleanBeatWindow(rr: cleanRRs, indices: keptValues.map(\.index), breaks: breaks, afterRemovedBeat: removed),
            rmssd: maskedRMSSD(rrValues, kept: kept, breaks: breaks.union(removed))
        )
    }

    /// The block is half-open in time: it ends where its last beat ends, so
    /// its span is the time it covers and the first beat at or after `endMs`
    /// is the first one outside it (`SessionMerger.repointed`).
    private func scoredBlock(
        slice: WindowSlice,
        rrValues: [(index: Int, rr: Double)],
        artifactRate: Double,
        clean: CleanBeats,
        sessionStartMs: Int64,
        sessionEndMs: Int64
    ) -> ScoredRecoveryBlock? {
        let cleanRRs = clean.rrs, metrics = computeWindowMetrics(cleanRRs: cleanRRs, rmssd: clean.rmssd, windowPoints: slice.points)
        guard let relativePosition = computeRelativePosition(
            windowPoints: slice.points, sessionStartMs: sessionStartMs, sessionEndMs: sessionEndMs
        ) else { return nil }
        let dfaAlpha1 = cleanRRs.count >= 64 ? DFAAnalyzer.compute(window: clean.beats)?.alpha1 : nil
        // Optional-bind first/last instead of force-unwrap.
        // slice.points is guaranteed non-empty by the rrValues.count >= 50
        // guard in evaluateWindow, so this never fails in practice.
        guard let firstPoint = slice.points.first, let lastPoint = slice.points.last else { return nil }
        return ScoredRecoveryBlock(
            startIndex: slice.startIdx, endIndex: slice.endIdx,
            startMs: firstPoint.t_ms, endMs: lastPoint.endMs,
            artifactRate: artifactRate,
            ectopicRate: Double(rrValues.count - cleanRRs.count) / Double(rrValues.count),
            meanHR: metrics.meanHR, hrCV: metrics.hrCV,
            rmssd: metrics.rmssd, sdnn: metrics.sdnn,
            cleanBeatCount: cleanRRs.count, relativePosition: relativePosition,
            cleanRRs: cleanRRs, dfaAlpha1: dfaAlpha1, lfHfRatio: nil
        )
    }

    // MARK: - evaluateWindow Helpers

    /// The window's valid, artifact-free beats with their series index, and
    /// the share of its beats that are artifacts or unverified. A beat past
    /// the end of `windowFlags` (a recovered session whose artifact detection
    /// ran on a partial backup) was never checked, so it is neither clean nor
    /// left out of the rate: it counts as unverified, against the window.
    private func extractValidRRValues(
        windowPoints: [RRPoint], windowFlags: [ArtifactFlags], startIdx: Int
    ) -> (values: [(index: Int, rr: Double)], artifactRate: Double) {
        var rrValues: [(index: Int, rr: Double)] = []
        var rejectedCount = 0
        for (i, point) in windowPoints.enumerated() {
            guard i < windowFlags.count, !windowFlags[i].isArtifact else {
                rejectedCount += 1
                continue
            }
            if HRVConstants.RRInterval.isValid(point.rr_ms) {
                rrValues.append((startIdx + i, Double(point.rr_ms)))
            }
        }
        return (rrValues, Double(rejectedCount) / Double(windowPoints.count))
    }

    private func validateArtifactRate(_ artifactRate: Double, limit: Double, windowPointCount: Int) -> Bool {
        if artifactRate > limit {
            let rejectedCount = Int((artifactRate * Double(windowPointCount)).rounded())
            debugLog("[WindowSelector] evaluateWindow REJECTED: artifact rate \(String(format: "%.1f%%", artifactRate * 100)) > limit \(String(format: "%.1f%%", limit * 100)) (\(rejectedCount)/\(windowPointCount) artifacts or unverified)")
            return false
        }
        return true
    }

    private struct WindowMetrics {
        let meanHR: Double, hrCV: Double, rmssd: Double, sdnn: Double
    }

    /// SDNN is the sample standard deviation (divisor N-1), the estimator the
    /// reported SDNN uses (`TimeDomainAnalyzer.computeTimeDomain` via
    /// `Statistics.sampleStandardDeviation`), so peak-SDNN selection and
    /// `PeakCapacity.peakSDNN` carry the value the report shows. HR CV is
    /// that SD over the mean RR.
    private func computeWindowMetrics(cleanRRs: [Double], rmssd: Double, windowPoints: [RRPoint]) -> WindowMetrics {
        let meanRR = cleanRRs.reduce(0, +) / Double(cleanRRs.count)
        let meanHR = computeMeanHR(windowPoints: windowPoints, meanRR: meanRR)
        let sdnn = Statistics.sampleStandardDeviation(cleanRRs)
        return WindowMetrics(meanHR: meanHR, hrCV: sdnn / meanRR, rmssd: rmssd, sdnn: sdnn)
    }

    /// Mean HR: a trimmed mean of the sensor's HR when every beat in the
    /// window carries it, otherwise from the clean beats' mean RR. In a merged
    /// night only the streamed gap-fill beats carry sensor HR, and averaging
    /// those few would stand in for the whole window, as
    /// `TimeDomainAnalyzer`'s window HR also refuses to do.
    private func computeMeanHR(windowPoints: [RRPoint], meanRR: Double) -> Double {
        let hrValues = windowPoints.compactMap(\.hr).map { Double($0) }.sorted()
        guard !hrValues.isEmpty, hrValues.count == windowPoints.count else { return 60000.0 / meanRR }
        if hrValues.count >= 10 {
            let lo = Int(Double(hrValues.count) * 0.05)
            let hi = Int(Double(hrValues.count) * 0.95)
            let trimmed = Array(hrValues[lo ..< hi])
            return trimmed.reduce(0, +) / Double(trimmed.count)
        }
        return hrValues.reduce(0, +) / Double(hrValues.count)
    }

    private func computeRelativePosition(
        windowPoints: [RRPoint], sessionStartMs: Int64, sessionEndMs: Int64
    ) -> Double? {
        guard let first = windowPoints.first, let last = windowPoints.last else { return nil }
        let midpointMs = (first.t_ms + last.t_ms) / 2
        let sleepDuration = sessionEndMs - sessionStartMs
        return sleepDuration > 0 ? Double(midpointMs - sessionStartMs) / Double(sleepDuration) : 0.5
    }
}
