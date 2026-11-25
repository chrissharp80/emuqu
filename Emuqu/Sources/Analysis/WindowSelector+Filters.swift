import Foundation

// MARK: - Filtering & Helpers

extension WindowSelector {
    /// Filter out isolated spikes: windows whose RMSSD is ≥50% higher than BOTH neighbors.
    /// Edge windows (first/last) are never classified as spikes, so a
    /// non-empty input always leaves a non-empty result.
    /// Threshold lives on `WindowSelector.Config.isolatedSpikeRatio`.
    ///
    /// "Neighbours" are the adjacent SURVIVING windows of the scan, not grid
    /// positions. Grid-adjacent windows overlap (step ≤ half a window), share
    /// most of their successive differences, and so practically never differ
    /// by 1.5×: in practice the filter fires on a window whose grid neighbours
    /// were rejected by the artifact or clean-beat gates — a clean stretch
    /// standing alone between rejected ones, compared with the nearest clean
    /// windows on either side.
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

    /// RMSSD over successive differences between beats that are ADJACENT in
    /// the original series (`index`), both kept by the ectopic gate
    /// (`TimeDomainAnalyzer.ectopicKeepMask`), and not
    /// separated by a recording break (`breaks`: indices whose beat follows
    /// one, `TimeDomainAnalyzer.isRecordingBreak`). The
    /// Task Force definition is the difference between adjacent NN intervals;
    /// differencing the collapsed array instead adds one spurious large
    /// difference per removed beat. Same estimator as the reported RMSSD
    /// (`TimeDomainAnalyzer.computeTimeDomain`), so the window is chosen on the
    /// value it then reports. 0 when no such pair exists.
    func maskedRMSSD(_ rrValues: [(index: Int, rr: Double)], kept: [Bool], breaks: Set<Int> = []) -> Double {
        guard rrValues.count >= 2, kept.count == rrValues.count else { return 0 }
        var diffs = [Double]()
        diffs.reserveCapacity(rrValues.count - 1)
        for k in 1 ..< rrValues.count
        where kept[k] && kept[k - 1] && rrValues[k].index == rrValues[k - 1].index + 1
            && !breaks.contains(rrValues[k].index) {
            diffs.append(rrValues[k].rr - rrValues[k - 1].rr)
        }
        return diffs.isEmpty ? 0 : Statistics.rootMeanSquare(diffs)
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

    /// `findBestWindow` with only a wake time. Kept for the window-selection
    /// tests, its only callers.
    func selectRecoveryWindow(
        series: RRSeries,
        flags: [ArtifactFlags],
        wakeTimeMs: Int64
    ) -> RecoveryWindow? {
        findBestWindow(in: series, flags: flags, wakeTimeMs: wakeTimeMs)
    }
}
