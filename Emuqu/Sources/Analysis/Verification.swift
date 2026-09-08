import Foundation

/// Data verification per design spec v8.1
/// Validates session data quality with pass/fail and detailed reporting
///
/// This is your "credibility moat" - explicit rejection states ensure data quality
/// and make it clear WHY a session was rejected (for user understanding and debugging)
struct Verification {
    // MARK: - Types

    /// Explicit rejection reasons - each represents a distinct failure mode
    enum RejectionReason: String, Codable, CaseIterable {
        // Duration failures
        case tooShort = "too_short" // Recording shorter than minimum duration
        case tooFewPoints = "too_few_points" // Insufficient RR intervals captured

        // Quality failures
        case excessiveArtifacts = "excessive_artifacts" // Artifact % above threshold
        case excessiveEctopy = "excessive_ectopy" // Too many ectopic beats
        case excessiveDrift = "excessive_drift" // RR intervals drifting unrealistically
        case signalLoss = "signal_loss" // Gaps in data suggesting sensor issues
        case outOfBoundsIntervals = "out_of_bounds" // Too many physiologically impossible values

        // Technical failures
        case corruptedData = "corrupted_data" // Data integrity issues
        case unknownDevice = "unknown_device" // Unrecognized source device

        var displayName: String {
            switch self {
            case .tooShort: "Recording Too Short"
            case .tooFewPoints: "Insufficient Data Points"
            case .excessiveArtifacts: "Excessive Artifacts"
            case .excessiveEctopy: "Excessive Ectopic Beats"
            case .excessiveDrift: "Signal Drift Detected"
            case .signalLoss: "Signal Loss Detected"
            case .outOfBoundsIntervals: "Out-of-Range Intervals"
            case .corruptedData: "Data Corrupted"
            case .unknownDevice: "Unknown Device"
            }
        }

        /// Deliberately not "may indicate arrhythmia or sensor issues": that
        /// crosses Apple Review 1.4.1 by implying a cardiac diagnosis from a
        /// wellness app. This wording describes the *signal* (irregular beats)
        /// and the *most-likely cause* (sensor noise) without naming a medical
        /// condition. The FDA copy linter (`Tools/copy_linter/lint.py`) blocks
        /// the term `arrhythmia` from entering source.
        static let excessiveEctopyExplanation =
            "Many irregular beats detected — most often from poor strap contact or sensor noise. Re-wet the electrodes, snug the strap, and try again."

        var explanation: String {
            switch self {
            case .tooShort:
                "The recording duration is below the minimum required for reliable analysis."
            case .tooFewPoints:
                "Not enough heartbeats were captured. Check chest strap contact."
            case .excessiveArtifacts:
                "Too many detected artifacts (noise, missed beats). May indicate poor sensor contact."
            case .excessiveEctopy:
                Self.excessiveEctopyExplanation
            case .excessiveDrift:
                "Heart rate drifted unrealistically. This often indicates electrode movement."
            case .signalLoss:
                "Gaps detected in the RR data. Check chest strap battery and contact."
            case .outOfBoundsIntervals:
                "RR intervals outside physiological range (\(HRVThresholds.minimumRRIntervalMs)-\(HRVThresholds.maximumRRIntervalMs)ms) detected."
            case .corruptedData:
                "Data integrity check failed. The recording may be incomplete."
            case .unknownDevice:
                "Data source could not be verified."
            }
        }
    }

    struct Result: Codable {
        let passed: Bool
        let rejectionReasons: [RejectionReason] // Explicit failure reasons
        let errors: [String] // Human-readable error messages
        let warnings: [String] // Non-fatal issues
        let metrics: Metrics

        /// Quick check if a specific rejection reason applies
        func isRejectedFor(_ reason: RejectionReason) -> Bool {
            rejectionReasons.contains(reason)
        }

        /// Summary for display
        var summary: String {
            if passed {
                return warnings.isEmpty ? "Passed verification" : "Passed with warnings"
            } else {
                let reasonNames = rejectionReasons.map(\.displayName).joined(separator: ", ")
                return "Rejected: \(reasonNames)"
            }
        }
    }

    struct Metrics: Codable {
        let pointCount: Int
        let nnCount: Int
        let durationHours: Double
        let artifactPercent: Double
        let ectopyCount: Int
        let outOfBoundsLowCount: Int
        let outOfBoundsHighCount: Int
        /// Maximum gap between consecutive beats (ms) - indicates signal loss
        let maxGapMs: Int64?
        /// RR interval drift over session (ms) - indicates electrode movement
        let rrDrift: Double?
    }

    // MARK: - Configuration

    struct Config {
        /// Minimum points required (~5 min at 60 bpm)
        var minPoints: Int = HRVConstants.MinimumBeats.forAnalysis
        /// Minimum duration in hours (5 minutes = 0.083 hours)
        /// Allows naps and short rest periods - window selection handles finding best 5-min segment
        var minDurationHours: Double = 0.083
        /// Maximum artifact percentage (hard fail)
        var maxArtifactPercent: Double = HRVConstants.Artifacts.maxPercentForAnalysis
        /// Warning threshold for artifacts
        var warnArtifactPercent: Double = HRVConstants.Artifacts.warnPercentThreshold

        static let `default` = Config()

        /// Strict config for when longer duration is desired (e.g. research use)
        static let strict = Config(
            minPoints: HRVConstants.MinimumBeats.forAnalysis,
            minDurationHours: 4.0,
            maxArtifactPercent: HRVConstants.Artifacts.maxPercentForAnalysis,
            warnArtifactPercent: HRVConstants.Artifacts.warnPercentThreshold
        )
    }

    private let config: Config

    init(config: Config = .default) {
        self.config = config
    }

    // MARK: - Verification

    /// The measurements every verification check and metric reads.
    struct SeriesStats {
        let artifacts: ArtifactBreakdown
        let durationHours: Double
        let maxGapMs: Int64
        let rrDrift: Double
    }

    /// Verify session data quality
    /// - Parameters:
    ///   - series: The RR series
    ///   - flags: Artifact flags for each point
    /// - Returns: Verification result with pass/fail, explicit rejection reasons, and metrics
    func verify(_ series: RRSeries, flags: [ArtifactFlags]) -> Result {
        let points = series.points
        // Early exit with minimal metrics when there is barely a recording.
        guard points.count >= config.minPoints else {
            return tooFewPointsResult(pointCount: points.count)
        }
        let stats = SeriesStats(
            artifacts: classifyArtifacts(points: points, flags: flags),
            durationHours: computeDurationHours(points: points),
            maxGapMs: findMaxGap(points: points),
            rrDrift: computeRRDrift(points: points)
        )
        let checks = runChecks(points: points, stats: stats)
        return Result(
            passed: checks.reasons.isEmpty, rejectionReasons: checks.reasons,
            errors: checks.errors, warnings: checks.warnings,
            metrics: metrics(points: points, flags: flags, stats: stats)
        )
    }

    /// Steps 2 and 4-8: duration, signal quality (gaps + drift), then the
    /// artifact/ectopy/out-of-bounds thresholds.
    private func runChecks(
        points: [RRPoint],
        stats: SeriesStats
    ) -> (reasons: [RejectionReason], errors: [String], warnings: [String]) {
        var rejectionReasons: [RejectionReason] = []
        var errors: [String] = []
        var warnings: [String] = []
        checkDuration(stats.durationHours, reasons: &rejectionReasons, errors: &errors)
        checkSignalQuality(
            maxGapMs: stats.maxGapMs, rrDrift: stats.rrDrift,
            reasons: &rejectionReasons, errors: &errors, warnings: &warnings
        )
        runThresholdChecks(
            artifacts: stats.artifacts, pointCount: points.count,
            reasons: &rejectionReasons, errors: &errors, warnings: &warnings
        )
        return (rejectionReasons, errors, warnings)
    }

    /// Steps 6-8: artifact rate, ectopy, and out-of-bounds beats.
    private func runThresholdChecks(
        artifacts: ArtifactBreakdown,
        pointCount: Int,
        reasons rejectionReasons: inout [RejectionReason],
        errors: inout [String],
        warnings: inout [String]
    ) {
        checkArtifactThresholds(artifactPercent: artifacts.artifactPercent, reasons: &rejectionReasons, errors: &errors, warnings: &warnings)
        checkEctopy(ectopyCount: artifacts.ectopyCount, pointCount: pointCount, reasons: &rejectionReasons, errors: &errors, warnings: &warnings)
        checkOutOfBounds(
            oobLowCount: artifacts.oobLowCount,
            oobHighCount: artifacts.oobHighCount,
            pointCount: pointCount,
            reasons: &rejectionReasons,
            errors: &errors,
            warnings: &warnings
        )
    }

    private func metrics(
        points: [RRPoint],
        flags: [ArtifactFlags],
        stats: SeriesStats
    ) -> Metrics {
        let artifactCount = flags.filter(\.isArtifact).count
        return Metrics(
            pointCount: points.count, nnCount: points.count - artifactCount,
            durationHours: stats.durationHours, artifactPercent: stats.artifacts.artifactPercent,
            ectopyCount: stats.artifacts.ectopyCount, outOfBoundsLowCount: stats.artifacts.oobLowCount,
            outOfBoundsHighCount: stats.artifacts.oobHighCount, maxGapMs: stats.maxGapMs, rrDrift: stats.rrDrift
        )
    }

    // MARK: - Verification Helpers

    private func tooFewPointsResult(pointCount: Int) -> Result {
        Result(
            passed: false,
            rejectionReasons: [.tooFewPoints],
            errors: ["Too few points: \(pointCount) (minimum \(config.minPoints) required)"],
            warnings: [],
            metrics: Metrics(
                pointCount: pointCount,
                nnCount: 0,
                durationHours: 0,
                artifactPercent: 0,
                ectopyCount: 0,
                outOfBoundsLowCount: 0,
                outOfBoundsHighCount: 0,
                maxGapMs: nil,
                rrDrift: nil
            )
        )
    }

    private func computeDurationHours(points: [RRPoint]) -> Double {
        let durationMs = points.last.map { $0.t_ms + Int64($0.rr_ms) } ?? 0
        return Double(durationMs) / 3_600_000.0
    }

    private func checkDuration(
        _ durationHours: Double,
        reasons: inout [RejectionReason],
        errors: inout [String]
    ) {
        if durationHours < config.minDurationHours {
            reasons.append(.tooShort)
            errors.append(String(format: "Duration %.2fh < %.1fh minimum", durationHours, config.minDurationHours))
        }
    }

    /// Bound by BOTH arrays: a length mismatch would otherwise trap on
    /// flags[i]. min() makes the invariant safe.
    private func classifyArtifacts(points: [RRPoint], flags: [ArtifactFlags]) -> ArtifactBreakdown {
        var ectopyCount = 0, oobLowCount = 0, oobHighCount = 0
        for i in 0 ..< min(points.count, flags.count) where flags[i].isArtifact {
            switch flags[i].type {
            case .some(.ectopic), .some(.extra), .some(.missed):
                ectopyCount += 1
            case .some(.technical):
                Self.countOutOfBounds(points[i].rr_ms, low: &oobLowCount, high: &oobHighCount)
            case .some(ArtifactFlags.ArtifactType.none), nil:
                break
            }
        }
        return ArtifactBreakdown(
            artifactPercent: Double(flags.filter(\.isArtifact).count) / Double(points.count) * 100,
            ectopyCount: ectopyCount,
            oobLowCount: oobLowCount,
            oobHighCount: oobHighCount
        )
    }

    /// A technical artifact inside the valid range counts as neither — it was
    /// flagged for some other reason (signal quality, not interval length).
    private static func countOutOfBounds(_ rrMs: Int, low: inout Int, high: inout Int) {
        if rrMs < HRVThresholds.minimumRRIntervalMs { low += 1 }
        if rrMs > HRVThresholds.maximumRRIntervalMs { high += 1 }
    }

    private func findMaxGap(points: [RRPoint]) -> Int64 {
        guard points.count > 1 else { return 0 }

        var maxGapMs: Int64 = 0
        for i in 1 ..< points.count {
            let gap = points[i].t_ms - points[i - 1].endMs
            if gap > maxGapMs { maxGapMs = gap }
        }
        return maxGapMs
    }

    private func computeRRDrift(points: [RRPoint]) -> Double {
        let tenPercent = max(10, points.count / 10)
        let firstMeanRR = Double(points.prefix(tenPercent).map(\.rr_ms).reduce(0, +)) / Double(tenPercent)
        let lastMeanRR = Double(points.suffix(tenPercent).map(\.rr_ms).reduce(0, +)) / Double(tenPercent)
        return lastMeanRR - firstMeanRR
    }

    private func checkSignalQuality(
        maxGapMs: Int64,
        rrDrift: Double,
        reasons: inout [RejectionReason],
        errors: inout [String],
        warnings: inout [String]
    ) {
        if maxGapMs > HRVThresholds.verificationMaxGapMs {
            reasons.append(.signalLoss)
            errors.append(String(format: "Signal gap detected: %.1fs", Double(maxGapMs) / 1000.0))
        }
        if abs(rrDrift) > HRVThresholds.verificationDriftWarnMs {
            warnings.append(String(format: "RR drift detected: %.0fms", rrDrift))
        }
        if abs(rrDrift) > HRVThresholds.verificationDriftRejectMs {
            reasons.append(.excessiveDrift)
            errors.append(String(format: "Excessive RR drift: %.0fms (electrode movement suspected)", rrDrift))
        }
    }

    private func checkArtifactThresholds(
        artifactPercent: Double,
        reasons: inout [RejectionReason],
        errors: inout [String],
        warnings: inout [String]
    ) {
        if artifactPercent > config.maxArtifactPercent {
            reasons.append(.excessiveArtifacts)
            errors.append(String(format: "Artifacts %.1f%% > %.0f%% limit", artifactPercent, config.maxArtifactPercent))
        } else if artifactPercent > config.warnArtifactPercent {
            warnings.append(String(format: "Artifacts %.1f%%", artifactPercent))
        }
    }

    private func checkEctopy(
        ectopyCount: Int,
        pointCount: Int,
        reasons: inout [RejectionReason],
        errors: inout [String],
        warnings: inout [String]
    ) {
        let ectopyPercent = Double(ectopyCount) / Double(pointCount) * 100
        if ectopyPercent > HRVThresholds.verificationEctopyRejectPercent {
            reasons.append(.excessiveEctopy)
            errors.append(String(format: "Ectopic beats %.1f%% (>\(ectopyCount) beats)", ectopyPercent))
        } else if ectopyCount > HRVThresholds.verificationEctopyWarnCount {
            warnings.append("Elevated ectopy count: \(ectopyCount)")
        }
    }

    private func checkOutOfBounds(
        oobLowCount: Int,
        oobHighCount: Int,
        pointCount: Int,
        reasons: inout [RejectionReason],
        errors: inout [String],
        warnings: inout [String]
    ) {
        let oobTotal = oobLowCount + oobHighCount
        let oobPercent = Double(oobTotal) / Double(pointCount) * 100
        if oobPercent > HRVThresholds.verificationOutOfBoundsRejectPercent {
            reasons.append(.outOfBoundsIntervals)
            errors.append(String(format: "Out-of-range intervals: %.1f%% (%d low, %d high)", oobPercent, oobLowCount, oobHighCount))
        } else {
            // Reference the canonical bounds in the warning copy so a
            // future bound change updates the user-visible numbers too.
            if oobLowCount > HRVThresholds.verificationOutOfBoundsWarnCount {
                warnings.append("Many short intervals (<\(HRVThresholds.minimumRRIntervalMs)ms): \(oobLowCount)")
            }
            if oobHighCount > HRVThresholds.verificationOutOfBoundsWarnCount {
                warnings.append("Many long intervals (>\(HRVThresholds.maximumRRIntervalMs)ms): \(oobHighCount)")
            }
        }
    }
}
