import Foundation

/// Artifact detection using rolling median and ratio-based classification
final class ArtifactDetector: Sendable {
    // MARK: - Configuration

    struct Config {
        /// Window size for rolling median (beats)
        var windowSize: Int = HRVConstants.Artifacts.windowSize
        /// Threshold for ectopic detection (ratio from median)
        var ectopicThreshold: Double = 0.20
        /// Threshold for missed beat detection (ratio from median)
        var missedThreshold: Double = 0.50
        /// Threshold for extra beat detection (ratio from median)
        var extraThreshold: Double = 0.30
        /// Minimum RR interval (ms)
        var minRR: Int = HRVConstants.RRInterval.minimum
        /// Maximum RR interval (ms)
        var maxRR: Int = HRVConstants.RRInterval.maximum

        static let `default` = Config()
    }

    private let config: Config

    init(config: Config = .default) {
        self.config = config
    }

    // MARK: - Public API

    /// Detect artifacts in an RR series
    /// - Parameter series: The RR series to analyze
    /// - Returns: Array of artifact flags for each point
    func detectArtifacts(in series: RRSeries) -> [ArtifactFlags] {
        let points = series.points
        guard !points.isEmpty else { return [] }
        let medians = computeRollingMedian(points.map { Double($0.rr_ms) }, windowSize: config.windowSize)
        var flags = [ArtifactFlags]()
        flags.reserveCapacity(points.count)
        for i in 0 ..< points.count {
            flags.append(classify(rrMs: points[i].rr_ms, median: medians[i]))
        }
        return flags
    }

    /// One beat, against the rolling median of its neighbourhood.
    private func classify(rrMs: Int, median: Double) -> ArtifactFlags {
        // Technical artifacts: out of physiological range.
        guard rrMs >= config.minRR, rrMs <= config.maxRR else {
            return ArtifactFlags(isArtifact: true, type: .technical, confidence: 1.0)
        }
        let rr = Double(rrMs)
        let ratio = abs(rr - median) / median
        if rr < median * (1 - config.extraThreshold) {
            return shortBeatFlags(rr: rr, median: median, ratio: ratio)
        }
        if rr > median * (1 + config.ectopicThreshold) {
            return longBeatFlags(rr: rr, median: median, ratio: ratio)
        }
        if ratio > config.ectopicThreshold {
            // General deviation beyond ectopic threshold.
            return ArtifactFlags(
                isArtifact: true, type: .ectopic,
                confidence: min(1.0, ratio / config.ectopicThreshold)
            )
        }
        return .clean
    }

    /// Shorter than expected: a very short beat is an extra detection, a
    /// moderately short one may be ectopic.
    private func shortBeatFlags(rr: Double, median: Double, ratio: Double) -> ArtifactFlags {
        let confidence = min(1.0, ratio / config.extraThreshold)
        guard rr >= median * 0.5 else {
            return ArtifactFlags(isArtifact: true, type: .extra, confidence: confidence)
        }
        return ArtifactFlags(
            isArtifact: ratio > config.ectopicThreshold, type: .ectopic, confidence: confidence
        )
    }

    /// Longer than expected: a missed beat above the missed threshold,
    /// otherwise an ectopic.
    ///
    /// Symmetric long-beat ectopic gate. The short
    /// side flags an ectopic at deviation > 0.20 (config.ectopicThreshold); if
    /// the long side only typed a beat as `.missed` above 0.50
    /// (config.missedThreshold), leaving the gap 0.20–0.50 to the generic
    /// `ratio > 0.20` branch. That made the long side's ectopic decision depend
    /// on branch ordering rather than an explicit symmetric rule — a
    /// post-ectopic compensatory pause (classically 20–50% long) is exactly the
    /// case that must be excluded so it can't inflate RMSSD via a large
    /// successive difference.
    private func longBeatFlags(rr: Double, median: Double, ratio: Double) -> ArtifactFlags {
        guard rr <= median * (1 + config.missedThreshold) else {
            return ArtifactFlags(
                isArtifact: true, type: .missed,
                confidence: min(1.0, ratio / config.missedThreshold)
            )
        }
        return ArtifactFlags(
            isArtifact: true, type: .ectopic,
            confidence: min(1.0, ratio / config.ectopicThreshold)
        )
    }

    /// Calculate artifact percentage for a window
    /// - Parameters:
    ///   - flags: Artifact flags array
    ///   - start: Window start index
    ///   - end: Window end index (exclusive)
    /// - Returns: Percentage of artifacts (0-100)
    func artifactPercentage(_ flags: [ArtifactFlags], start: Int, end: Int) -> Double {
        let clampedStart = max(0, start)
        let clampedEnd = min(flags.count, end)
        guard clampedEnd > clampedStart else { return 0 }

        let window = flags[clampedStart ..< clampedEnd]
        let artifactCount = window.filter(\.isArtifact).count
        return Double(artifactCount) / Double(window.count) * 100.0
    }

    // MARK: - Private

    /// Compute rolling median for each position.
    /// Uses an insertion-sorted sliding window: O(n * w) total — each step
    /// removes one element and inserts one via binary search, avoiding a
    /// full re-sort per position.
    private func computeRollingMedian(_ values: [Double], windowSize: Int) -> [Double] {
        guard !values.isEmpty else { return [] }
        let halfWindow = windowSize / 2
        var medians = [Double]()
        medians.reserveCapacity(values.count)
        var sorted = [Double]()
        sorted.reserveCapacity(windowSize + 1)
        // Bootstrap the centred window for position 0.
        for j in 0 ..< min(values.count, halfWindow + 1) {
            sorted.insert(values[j], at: sorted.sortedInsertionIndex(of: values[j]))
        }
        medians.append(medianOf(sorted))
        for i in 1 ..< values.count {
            slideWindow(&sorted, values: values, to: i, halfWindow: halfWindow)
            medians.append(medianOf(sorted))
        }
        return medians
    }

    /// Advances the sorted window one position: the beat entering on the right
    /// is inserted, the one leaving on the left removed.
    private func slideWindow(_ sorted: inout [Double], values: [Double], to i: Int, halfWindow: Int) {
        let newRight = i + halfWindow
        if newRight < values.count {
            sorted.insert(values[newRight], at: sorted.sortedInsertionIndex(of: values[newRight]))
        }
        let oldLeft = i - halfWindow - 1
        if oldLeft >= 0, let removeIdx = sorted.sortedFirstIndex(of: values[oldLeft]) {
            sorted.remove(at: removeIdx)
        }
    }

    /// Median of a sorted array.
    private func medianOf(_ sorted: [Double]) -> Double {
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2.0
        }
        return sorted[mid]
    }
}

// MARK: - Sorted-array binary search

/// Binary searches over an ascending `[Double]`, used by the sliding-window
/// median filters here and in `WindowSelector` to keep their window sorted
/// without re-sorting per step.
extension Array where Element == Double {
    /// Index at which `value` inserts while keeping the array sorted.
    func sortedInsertionIndex(of value: Double) -> Int {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if self[mid] < value { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// First index holding exactly `value`, or nil when absent.
    func sortedFirstIndex(of value: Double) -> Int? {
        let lo = sortedInsertionIndex(of: value)
        guard lo < count, self[lo] == value else { return nil }
        return lo
    }
}
