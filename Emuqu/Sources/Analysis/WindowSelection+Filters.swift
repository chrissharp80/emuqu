import Foundation

// MARK: - Filtering & Helpers

extension WindowSelector {
    /// Filter out isolated spikes: windows whose RMSSD is ≥50% higher than BOTH neighbors.
    /// Edge windows (first/last) are never classified as spikes.
    /// Threshold lives on `WindowSelector.Config.isolatedSpikeRatio`.
    func filterIsolatedSpikes(_ windows: [ScoredRecoveryBlock]) -> (sustained: [ScoredRecoveryBlock], rejectedCount: Int) {
        var sustained: [ScoredRecoveryBlock] = []
        var rejectedCount = 0
        for (i, window) in windows.enumerated() {
            if isIsolatedSpike(at: i, in: windows) {
                rejectedCount += 1
            } else {
                sustained.append(window)
            }
        }
        return (sustained, rejectedCount)
    }

    /// A window is a spike only when both neighbours exist, both carry real
    /// RMSSD, and it towers over both of them.
    private func isIsolatedSpike(at i: Int, in windows: [ScoredRecoveryBlock]) -> Bool {
        guard i > 0, i < windows.count - 1 else { return false }
        let prev = windows[i - 1].rmssd
        let next = windows[i + 1].rmssd
        guard prev > .leastNonzeroMagnitude, next > .leastNonzeroMagnitude else { return false }
        return windows[i].rmssd >= prev * config.isolatedSpikeRatio
            && windows[i].rmssd >= next * config.isolatedSpikeRatio
    }

    // MARK: - Ectopic Beat Filtering

    /// Filter ectopic beats using 20% deviation from local median.
    /// Based on research: PMC3268104, Kubios methodology.
    /// Single beats that deviate >20% from surrounding median are filtered.
    ///
    /// Uses an insertion-sorted sliding window: O(n * w) total — each step
    /// removes one element and inserts one via binary search, avoiding a
    /// full re-sort per position.
    func filterEctopicBeats(_ rrValues: [Double]) -> [Double] {
        guard rrValues.count > config.localMedianWindow else { return rrValues }
        let halfWindow = config.localMedianWindow / 2
        var cleanRRs: [Double] = []
        cleanRRs.reserveCapacity(rrValues.count)
        var sorted: [Double] = []
        sorted.reserveCapacity(config.localMedianWindow + 2)
        // Bootstrap the window centred on position 0.
        for j in 0 ..< min(rrValues.count, halfWindow + 1) {
            sorted.insert(rrValues[j], at: sorted.sortedInsertionIndex(of: rrValues[j]))
        }
        for i in 0 ..< rrValues.count {
            if i > 0 { slideWindow(&sorted, values: rrValues, to: i, halfWindow: halfWindow) }
            if keepsBeat(rrValues[i], window: sorted) { cleanRRs.append(rrValues[i]) }
        }
        return cleanRRs
    }

    /// Advances the sorted window one position: the beat entering on the right
    /// is inserted, the one leaving on the left removed.
    private func slideWindow(_ sorted: inout [Double], values: [Double], to i: Int, halfWindow: Int) {
        let newRight = i + halfWindow
        if newRight < values.count {
            sorted.insert(values[newRight], at: sorted.sortedInsertionIndex(of: values[newRight]))
        }
        let oldLeft = i - halfWindow - 1
        if oldLeft >= 0, let idx = sorted.sortedFirstIndex(of: values[oldLeft]) {
            sorted.remove(at: idx)
        }
    }

    /// Whether the beat is within the ectopic threshold of its local median.
    /// The median excludes the beat itself so a wild value can't drag the
    /// reference toward itself and survive.
    private func keepsBeat(_ rr: Double, window sorted: [Double]) -> Bool {
        let localMedian = medianExcluding(sorted, value: rr)
        guard localMedian > 0 else { return true }
        return abs(rr - localMedian) / localMedian <= config.ectopicThresholdPercent
    }

    // MARK: - Sliding Window Helpers

    /// Median of a sorted array, excluding one occurrence of `value`.
    /// Computes in-place without allocating a temporary array.
    private func medianExcluding(_ sorted: [Double], value: Double) -> Double {
        let n = sorted.count
        guard n > 1 else { return 0 }
        let skipIdx = sorted.firstIndex(of: value) ?? -1
        let effectiveCount = skipIdx >= 0 ? n - 1 : n
        guard effectiveCount > 0 else { return 0 }
        let mid = effectiveCount / 2
        guard effectiveCount.isMultiple(of: 2) else {
            return sorted[Self.realIndex(mid, skipping: skipIdx)]
        }
        return (sorted[Self.realIndex(mid - 1, skipping: skipIdx)]
            + sorted[Self.realIndex(mid, skipping: skipIdx)]) / 2.0
    }

    /// Maps a logical index in the "skipped" view onto the real array index.
    private static func realIndex(_ logical: Int, skipping skipIdx: Int) -> Int {
        guard skipIdx >= 0 else { return logical }
        return logical < skipIdx ? logical : logical + 1
    }

    /// Calculate RMSSD from RR intervals.
    /// RMSSD is the root mean square of successive differences, which is exactly
    /// `Statistics.rootMeanSquare` (sqrt(sumSq / N)) over the diff array.
    func calculateRMSSD(_ rrValues: [Double]) -> Double {
        guard rrValues.count >= 2 else { return 0 }

        var diffs = [Double]()
        diffs.reserveCapacity(rrValues.count - 1)
        for i in 1 ..< rrValues.count {
            diffs.append(rrValues[i] - rrValues[i - 1])
        }

        return Statistics.rootMeanSquare(diffs)
    }

    // MARK: - Helpers

    func formatTime(_ ms: Int64) -> String {
        let totalSeconds = Int(ms / 1000)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    // MARK: - Legacy API (for compatibility)

    func selectRecoveryWindow(
        series: RRSeries,
        flags: [ArtifactFlags],
        wakeTimeMs: Int64
    ) -> RecoveryWindow? {
        findBestWindow(in: series, flags: flags, wakeTimeMs: wakeTimeMs)
    }

    func selectRecoveryWindow(
        series: RRSeries,
        flags: [ArtifactFlags],
        sessionStart: Date,
        wakeTime: Date
    ) -> RecoveryWindow? {
        let wakeTimeMs = MillisecondOffset.between(wakeTime, and: sessionStart, fallback: 0)
        return findBestWindow(in: series, flags: flags, wakeTimeMs: wakeTimeMs)
    }
}
