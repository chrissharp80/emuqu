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
    /// `artifactRateLimit` overrides `config.maxArtifactRate` when supplied —
    /// `findBestWindow` uses this to run a strict 10% pass first, falling
    /// back to the permissive 15% cutoff only if the strict pass yields no
    /// organized windows.
    func scanWindows(
        series: RRSeries,
        flags: [ArtifactFlags],
        grid: ScanGrid,
        sessionStartMs: Int64,
        sessionEndMs: Int64,
        artifactRateLimit: Double? = nil
    ) -> [ScoredRecoveryBlock] {
        var windows: [ScoredRecoveryBlock] = []
        var scanIdx = grid.bandStart + grid.windowSize
        while scanIdx <= grid.bandEnd {
            if let block = evaluateWindow(
                series: series,
                flags: flags,
                startIdx: scanIdx - grid.windowSize,
                endIdx: scanIdx,
                sessionStartMs: sessionStartMs,
                sessionEndMs: sessionEndMs,
                artifactRateLimit: artifactRateLimit
            ) {
                windows.append(block)
            }
            scanIdx += grid.stepSize
        }
        return windows
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
        guard validateArtifactRate(
            artifactRate, limit: effectiveLimit, windowPoints: slice.points, windowFlags: slice.flags
        ) else { return nil }
        guard rrValues.count >= 50 else {
            debugLog("[WindowSelector] evaluateWindow REJECTED: only \(rrValues.count) valid RR values (need ≥50)")
            return nil
        }
        guard let cleanRRs = cleanBeats(rrValues: rrValues, windowPoints: slice.points) else { return nil }
        return scoredBlock(
            slice: slice, rrValues: rrValues, artifactRate: artifactRate,
            cleanRRs: cleanRRs, sessionStartMs: sessionStartMs, sessionEndMs: sessionEndMs
        )
    }

    /// The points and flags covering `startIdx ..< endIdx`, or nil when those
    /// indices can't address the series.
    ///
    /// Defensive bounds check. A production overnight crashed with
    /// "Fatal error: Range requires lowerBound <= upperBound" on
    /// the `flags[startIdx ..< min(endIdx, flags.count)]` line.
    /// Cause: a recovered/interrupted session can have a `flags`
    /// array shorter than `points` (artifact detection ran on a
    /// partial backup), so `min(endIdx, flags.count)` < `startIdx`
    /// for any window that lives past the flags array's tail.
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

    /// Ectopic-filtered beats, or nil when too few survive. The floor adapts
    /// downward for short windows so a 200-beat window isn't held to the same
    /// absolute count as a 600-beat one.
    private func cleanBeats(
        rrValues: [(index: Int, rr: Double)], windowPoints: [RRPoint]
    ) -> [Double]? {
        let cleanRRs = filterEctopicBeats(rrValues.map(\.rr))
        let adaptiveMinCleanBeats = min(config.minCleanBeats, max(50, Int(Double(windowPoints.count) * 0.75)))
        guard cleanRRs.count >= adaptiveMinCleanBeats else {
            debugLog("[WindowSelector] evaluateWindow REJECTED: only \(cleanRRs.count) clean beats (need ≥\(adaptiveMinCleanBeats)), \(rrValues.count - cleanRRs.count) ectopic removed")
            return nil
        }
        return cleanRRs
    }

    private func scoredBlock(
        slice: WindowSlice,
        rrValues: [(index: Int, rr: Double)],
        artifactRate: Double,
        cleanRRs: [Double],
        sessionStartMs: Int64,
        sessionEndMs: Int64
    ) -> ScoredRecoveryBlock? {
        let metrics = computeWindowMetrics(cleanRRs: cleanRRs, windowPoints: slice.points)
        guard let relativePosition = computeRelativePosition(
            windowPoints: slice.points, sessionStartMs: sessionStartMs, sessionEndMs: sessionEndMs
        ) else { return nil }
        let dfaAlpha1 = cleanRRs.count >= 64 ? DFAAnalyzer.compute(cleanRRs)?.alpha1 : nil
        // Optional-bind first/last instead of force-unwrap.
        // slice.points is guaranteed non-empty by the rrValues.count >= 50
        // guard in evaluateWindow, so this never fails in practice — the bind
        // is purely for refactor-spec compliance ("zero magic, no force-unwraps").
        guard let firstPoint = slice.points.first, let lastPoint = slice.points.last else { return nil }
        return ScoredRecoveryBlock(
            startIndex: slice.startIdx, endIndex: slice.endIdx,
            startMs: firstPoint.t_ms, endMs: lastPoint.t_ms,
            artifactRate: artifactRate,
            ectopicRate: Double(rrValues.count - cleanRRs.count) / Double(rrValues.count),
            meanHR: metrics.meanHR, hrCV: metrics.hrCV,
            rmssd: metrics.rmssd, sdnn: metrics.sdnn,
            cleanBeatCount: cleanRRs.count, relativePosition: relativePosition,
            cleanRRs: cleanRRs, dfaAlpha1: dfaAlpha1, lfHfRatio: nil
        )
    }

    // MARK: - evaluateWindow Helpers

    private func extractValidRRValues(
        windowPoints: [RRPoint], windowFlags: [ArtifactFlags], startIdx: Int
    ) -> (values: [(index: Int, rr: Double)], artifactRate: Double) {
        var rrValues: [(index: Int, rr: Double)] = []
        for (i, point) in windowPoints.enumerated() {
            let isArtifact = i < windowFlags.count ? windowFlags[i].isArtifact : false
            if !isArtifact, HRVConstants.RRInterval.isValid(point.rr_ms) {
                rrValues.append((startIdx + i, Double(point.rr_ms)))
            }
        }
        let artifactCount = windowFlags.filter(\.isArtifact).count
        let artifactRate = Double(artifactCount) / Double(windowPoints.count)
        return (rrValues, artifactRate)
    }

    private func validateArtifactRate(_ artifactRate: Double, limit: Double, windowPoints: [RRPoint], windowFlags: [ArtifactFlags]) -> Bool {
        if artifactRate > limit {
            let artifactCount = windowFlags.filter(\.isArtifact).count
            debugLog("[WindowSelector] evaluateWindow REJECTED: artifact rate \(String(format: "%.1f%%", artifactRate * 100)) > limit \(String(format: "%.1f%%", limit * 100)) (\(artifactCount)/\(windowPoints.count) artifacts)")
            return false
        }
        return true
    }

    private struct WindowMetrics {
        let meanHR: Double, hrCV: Double, rmssd: Double, sdnn: Double
    }

    private func computeWindowMetrics(cleanRRs: [Double], windowPoints: [RRPoint]) -> WindowMetrics {
        let meanRR = cleanRRs.reduce(0, +) / Double(cleanRRs.count)
        let meanHR = computeMeanHR(windowPoints: windowPoints, meanRR: meanRR)
        // Population variance (divisor N) — NOT routed through Statistics, which offers
        // only sample variance (divisor N-1). Convention mismatch; left as-is to preserve behavior.
        let variance = cleanRRs.map { pow($0 - meanRR, 2) }.reduce(0, +) / Double(cleanRRs.count)
        return WindowMetrics(
            meanHR: meanHR, hrCV: sqrt(variance) / meanRR,
            rmssd: calculateRMSSD(cleanRRs), sdnn: sqrt(variance)
        )
    }

    /// Calculate mean HR — trimmed mean from sensor if available, otherwise from mean RR.
    private func computeMeanHR(windowPoints: [RRPoint], meanRR: Double) -> Double {
        let hrValues = windowPoints.compactMap(\.hr).map { Double($0) }.sorted()
        guard !hrValues.isEmpty else { return 60000.0 / meanRR }
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
