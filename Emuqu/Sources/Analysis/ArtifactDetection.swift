import Foundation

/// Artifact detection using rolling median and ratio-based classification
final class ArtifactDetector: Sendable {
    // MARK: - Configuration

    struct Config {
        /// Window size for rolling median (beats)
        var windowSize: Int = HRVConstants.Artifacts.windowSize
        /// Threshold for ectopic detection (ratio from median), on both sides
        var ectopicThreshold: Double = 0.20
        /// Threshold for missed beat detection (ratio from median, long side)
        var missedThreshold: Double = 0.50
        /// Threshold for extra beat detection (ratio from median, short side):
        /// a beat shorter than median × (1 − extraThreshold) is an extra
        /// detection.
        var extraThreshold: Double = 0.50
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
        let rrMs = series.points.map(\.rr_ms)
        let medians = referenceMedians(rrMs)
        return rrMs.indices.map { classify(rrMs: rrMs[$0], median: medians[$0]) }
    }

    /// Whether the beat is within the physiological range; one outside it is
    /// a technical artifact.
    private func isInRange(_ rrMs: Int) -> Bool {
        rrMs >= config.minRR && rrMs <= config.maxRR
    }

    /// The rolling median each beat is judged against, taken over the
    /// in-range beats only: a dropout (0 ms) or a 5 s gap is a technical
    /// artifact and must not drag the reference for the valid beats around
    /// it. An out-of-range beat's entry is 0 and is never read, since
    /// `classify` rejects it first.
    private func referenceMedians(_ rrMs: [Int]) -> [Double] {
        let validIndices = rrMs.indices.filter { isInRange(rrMs[$0]) }
        let validMedians = computeRollingMedian(validIndices.map { Double(rrMs[$0]) }, windowSize: config.windowSize)
        var medians = Array(repeating: 0.0, count: rrMs.count)
        for (median, index) in zip(validMedians, validIndices) {
            medians[index] = median
        }
        return medians
    }

    /// One beat, against the rolling median of its neighbourhood. The bands
    /// are symmetric around the median: shorter than (1 − extraThreshold) is
    /// an extra detection, longer than (1 + missedThreshold) a missed beat,
    /// and any other deviation beyond `ectopicThreshold` on either side an
    /// ectopic — which on the long side covers a post-ectopic compensatory
    /// pause (classically 20–50% long), so it can't inflate RMSSD via a large
    /// successive difference.
    ///
    /// Every flag carries confidence 1.0: each band is a hard threshold, and
    /// the classifier has no graded certainty to report.
    private func classify(rrMs: Int, median: Double) -> ArtifactFlags {
        guard isInRange(rrMs) else { return ArtifactFlags(isArtifact: true, type: .technical, confidence: 1.0) }
        let rr = Double(rrMs)
        if rr < median * (1 - config.extraThreshold) {
            return ArtifactFlags(isArtifact: true, type: .extra, confidence: 1.0)
        }
        if rr > median * (1 + config.missedThreshold) {
            return ArtifactFlags(isArtifact: true, type: .missed, confidence: 1.0)
        }
        if abs(rr - median) / median > config.ectopicThreshold {
            return ArtifactFlags(isArtifact: true, type: .ectopic, confidence: 1.0)
        }
        return .clean
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

    /// Compute rolling median for each position, over the beat itself and
    /// `windowSize / 2` beats on each side (51 beats for the default 50),
    /// fewer at the ends of the series.
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
