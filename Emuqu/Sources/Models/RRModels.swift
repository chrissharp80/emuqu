import Foundation

/// A single RR interval point
struct RRPoint: Codable, Equatable {
    /// Start timestamp in milliseconds since session start (cumulative from RR intervals)
    let t_ms: Int64
    /// RR interval duration in milliseconds
    let rr_ms: Int
    /// Milliseconds since the stream started, read from the wall clock when
    /// this RR was received (for gap detection; unlike `t_ms` it does not
    /// drift after BLE drops). Only populated during streaming mode; nil for
    /// H10 internal recording.
    let wallClockMs: Int64?
    /// Heart rate calculated by the device (bpm)
    /// Only populated during streaming mode (from Polar H10 sensor); nil for internal recording
    let hr: Int?

    /// The same beat moved `offsetMs` later on both the session clock and the
    /// wall clock — how a child segment is re-based onto its parent's timeline
    /// when two recordings are merged.
    func shifted(by offsetMs: Int64) -> RRPoint {
        RRPoint(
            t_ms: t_ms + offsetMs,
            rr_ms: rr_ms,
            wallClockMs: wallClockMs.map { $0 + offsetMs },
            hr: hr
        )
    }

    /// Whether this RR interval falls within the physiologically valid range
    var isPhysiologicallyValid: Bool {
        HRVConstants.RRInterval.isValid(rr_ms)
    }

    /// Legacy initializer (for backwards compatibility with H10 internal recording)
    init(t_ms: Int64, rr_ms: Int) {
        self.t_ms = t_ms
        self.rr_ms = rr_ms
        wallClockMs = nil
        hr = nil
    }

    /// Full initializer with wall-clock timestamp (for streaming mode)
    init(t_ms: Int64, rr_ms: Int, wallClockMs: Int64?, hr: Int? = nil) {
        self.t_ms = t_ms
        self.rr_ms = rr_ms
        self.wallClockMs = wallClockMs
        self.hr = hr
    }

    /// End timestamp (start + duration)
    var endMs: Int64 {
        t_ms + Int64(rr_ms)
    }

    /// Midpoint timestamp for interpolation
    var midpointMs: Double {
        Double(t_ms) + Double(rr_ms) / 2.0
    }

    /// Gap between wall-clock time and cumulative RR time (indicates dropped data)
    /// Positive value = wall clock is ahead = data was likely dropped
    /// Only meaningful for streaming data with wallClockMs populated
    var clockDriftMs: Int64? {
        guard let wallClock = wallClockMs else { return nil }
        return wallClock - t_ms
    }
}

/// A series of RR intervals
struct RRSeries: Codable {
    let points: [RRPoint]
    let sessionId: UUID
    let startDate: Date

    /// Total duration from first to last beat end (based on cumulative RR intervals)
    var durationMs: Int64 {
        guard let first = points.first, let last = points.last else { return 0 }
        return last.endMs - first.t_ms
    }

    /// Duration in minutes
    var durationMinutes: Double {
        Double(durationMs) / 60000.0
    }

    /// Whether this series has wall-clock timestamps (streaming mode)
    var hasWallClockTimestamps: Bool {
        points.first?.wallClockMs != nil
    }

    /// Actual wall-clock duration (for streaming mode with wall-clock timestamps)
    /// Returns nil if wall-clock timestamps aren't available
    var wallClockDurationMs: Int64? {
        guard let firstWall = points.first?.wallClockMs,
              let lastWall = points.last?.wallClockMs else { return nil }
        return lastWall - firstWall
    }

    /// Estimated data loss percentage based on wall-clock vs cumulative RR time drift
    /// Positive value indicates data was likely dropped during streaming
    var estimatedDataLossPercent: Double? {
        guard let wallDuration = wallClockDurationMs, wallDuration > 0 else { return nil }
        let rrDuration = durationMs
        let drift = wallDuration - rrDuration
        guard drift > 0 else { return 0.0 } // No loss or clock drift backwards (unlikely)
        return (Double(drift) / Double(wallDuration)) * 100.0
    }

    /// Find gaps in the data where wall-clock time advanced more than expected
    /// A gap is detected when wall-clock drift increases significantly between consecutive points
    /// - Parameter thresholdMs: Minimum gap size to report (default 2000ms = 2 seconds)
    /// - Returns: Array of (startIndex, endIndex, gapDurationMs) for each detected gap
    func detectGaps(thresholdMs: Int64 = 2000) -> [(startIndex: Int, endIndex: Int, gapDurationMs: Int64)] {
        guard hasWallClockTimestamps, points.count > 1 else { return [] }
        var gaps: [(startIndex: Int, endIndex: Int, gapDurationMs: Int64)] = []
        for i in 1 ..< points.count {
            guard let gap = gapMs(endingAt: i), gap >= thresholdMs else { continue }
            gaps.append((startIndex: i - 1, endIndex: i, gapDurationMs: gap))
        }
        return gaps
    }

    /// Wall-clock time between sample `i-1` and `i` minus the RR interval that
    /// should account for it. Nil when either sample lacks a wall clock.
    private func gapMs(endingAt i: Int) -> Int64? {
        guard let prevWall = points[i - 1].wallClockMs,
              let currWall = points[i].wallClockMs else { return nil }
        return (currWall - prevWall) - Int64(points[i - 1].rr_ms)
    }

    /// Total time lost to gaps (useful for adjusting sleep calculations)
    var totalGapDurationMs: Int64 {
        detectGaps().reduce(0) { $0 + $1.gapDurationMs }
    }

    /// Get the absolute timestamp for a point at a given index
    /// Uses cumulative RR time (t_ms) - accurate for H10 internal recording
    /// For streaming mode with gaps, use absoluteTimeWallClock() instead
    /// - Parameter index: Index of the RR point
    /// - Returns: Absolute Date for when this beat occurred
    func absoluteTime(at index: Int) -> Date? {
        guard index >= 0, index < points.count else { return nil }
        let point = points[index]
        return startDate.addingTimeInterval(TimeInterval(point.t_ms) / 1000.0)
    }

    /// Get the absolute timestamp using wall-clock time (streaming mode)
    /// This is more accurate than cumulative RR time when data gaps occurred
    /// Falls back to cumulative RR time if wall-clock not available
    /// - Parameter index: Index of the RR point
    /// - Returns: Absolute Date for when this beat was received
    func absoluteTimeWallClock(at index: Int) -> Date? {
        guard index >= 0, index < points.count else { return nil }
        let point = points[index]
        if let wallClock = point.wallClockMs {
            return startDate.addingTimeInterval(TimeInterval(wallClock) / 1000.0)
        }
        return startDate.addingTimeInterval(TimeInterval(point.t_ms) / 1000.0)
    }

    /// Get the absolute timestamp for a point's midpoint (useful for interpolation)
    /// - Parameter index: Index of the RR point
    /// - Returns: Absolute Date for the midpoint of this RR interval
    func absoluteMidpoint(at index: Int) -> Date? {
        guard index >= 0, index < points.count else { return nil }
        let point = points[index]
        return startDate.addingTimeInterval(point.midpointMs / 1000.0)
    }

    /// Get absolute timestamp for a relative millisecond offset
    /// - Parameter relativeMs: Milliseconds from session start
    /// - Returns: Absolute Date
    func absoluteTime(fromRelativeMs relativeMs: Int64) -> Date {
        startDate.addingTimeInterval(TimeInterval(relativeMs) / 1000.0)
    }

    /// Convert a cumulative-RR-time offset (t_ms) to a wall-clock Date.
    /// Finds the closest RR point by t_ms and uses its wallClockMs for accuracy.
    /// Falls back to t_ms-based time when wall-clock timestamps aren't available.
    func wallClockTime(forTMs tMs: Int64) -> Date {
        guard hasWallClockTimestamps, !points.isEmpty else {
            return absoluteTime(fromRelativeMs: tMs)
        }
        let index = closestIndex(to: tMs) { $0.t_ms }
        return absoluteTimeWallClock(at: index) ?? absoluteTime(fromRelativeMs: tMs)
    }

    /// Binary search for the point whose `key` is closest to `target`.
    /// `points` must be non-empty and ordered by `key`.
    private func closestIndex(to target: Int64, key: (RRPoint) -> Int64) -> Int {
        var low = 0
        var high = points.count - 1
        while low < high {
            let mid = (low + high) / 2
            if key(points[mid]) < target {
                low = mid + 1
            } else {
                high = mid
            }
        }
        // Check if the point before is closer
        guard low > 0,
              abs(key(points[low - 1]) - target) < abs(key(points[low]) - target)
        else { return low }
        return low - 1
    }

    /// Get relative milliseconds from an absolute Date
    /// - Parameter date: Absolute Date
    /// - Returns: Milliseconds since session start
    func relativeMs(from date: Date) -> Int64 {
        MillisecondOffset.between(date, and: startDate, fallback: 0)
    }

    /// Find the RR point index closest to a given absolute time using wall-clock timestamps
    /// This is useful for aligning streaming data with Apple Sleep boundaries
    /// Falls back to cumulative RR time if wall-clock not available
    /// - Parameter date: The target absolute Date
    /// - Returns: Index of the closest RR point, or nil if series is empty
    func indexClosestToWallClock(_ date: Date) -> Int? {
        guard !points.isEmpty else { return nil }
        let targetMs = MillisecondOffset.between(date, and: startDate, fallback: 0)
        return closestIndex(to: targetMs) { $0.wallClockMs ?? $0.t_ms }
    }

    /// Get the actual end time of the series using wall-clock time if available
    /// More accurate than durationMs for streaming mode with data gaps
    var actualEndDate: Date {
        if let lastWall = points.last?.wallClockMs {
            return startDate.addingTimeInterval(TimeInterval(lastWall) / 1000.0)
        }
        return startDate.addingTimeInterval(TimeInterval(durationMs) / 1000.0)
    }
}

/// Artifact classification flags for each RR interval
struct ArtifactFlags: Codable, Equatable {
    /// True if this interval is considered an artifact
    let isArtifact: Bool
    /// Classification of artifact type
    let type: ArtifactType?
    /// Confidence score (0-1)
    let confidence: Double
    /// True if this artifact was corrected/interpolated
    let corrected: Bool

    enum ArtifactType: String, Codable {
        case none
        case ectopic // Premature beat
        case missed // Missed beat detection
        case extra // Extra detection (noise)
        case technical // Sensor artifact
    }

    static let clean = ArtifactFlags(isArtifact: false, type: ArtifactType.none, confidence: 1.0, corrected: false)

    /// Legacy initializer for backwards compatibility
    init(isArtifact: Bool, type: ArtifactType?, confidence: Double) {
        self.isArtifact = isArtifact
        self.type = type
        self.confidence = confidence
        corrected = false
    }

    /// Full initializer with corrected flag
    init(isArtifact: Bool, type: ArtifactType?, confidence: Double, corrected: Bool) {
        self.isArtifact = isArtifact
        self.type = type
        self.confidence = confidence
        self.corrected = corrected
    }
}

/// Time-domain HRV metrics
struct TimeDomainMetrics: Codable {
    static let currentSchemaVersion = 1

    /// Mean RR interval (ms)
    let meanRR: Double
    /// Standard deviation of RR intervals (ms)
    let sdnn: Double
    /// Root mean square of successive differences (ms)
    let rmssd: Double
    /// Percentage of successive RR differences > 50ms
    let pnn50: Double
    /// Standard deviation of successive differences (ms)
    let sdsd: Double
    /// Mean heart rate (bpm)
    let meanHR: Double
    /// Standard deviation of heart rate (bpm)
    let sdHR: Double
    /// Minimum heart rate (bpm)
    let minHR: Double
    /// Maximum heart rate (bpm)
    let maxHR: Double
    /// HRV Triangular Index (N / max histogram bin)
    let triangularIndex: Double?

    /// Convenience initializer for fixtures: min/max HR are approximated as
    /// mean ± SD, not measured. Production analysis passes measured values
    /// through the full initializer below.
    init(
        meanRR: Double,
        sdnn: Double,
        rmssd: Double,
        pnn50: Double,
        sdsd: Double,
        meanHR: Double,
        sdHR: Double,
        triangularIndex: Double?
    ) {
        self.meanRR = meanRR
        self.sdnn = sdnn
        self.rmssd = rmssd
        self.pnn50 = pnn50
        self.sdsd = sdsd
        self.meanHR = meanHR
        self.sdHR = sdHR
        minHR = meanHR - sdHR // Approximate from SD
        maxHR = meanHR + sdHR
        self.triangularIndex = triangularIndex
    }

    /// Full initializer with min/max HR
    init(
        meanRR: Double,
        sdnn: Double,
        rmssd: Double,
        pnn50: Double,
        sdsd: Double,
        meanHR: Double,
        sdHR: Double,
        minHR: Double,
        maxHR: Double,
        triangularIndex: Double?
    ) {
        self.meanRR = meanRR
        self.sdnn = sdnn
        self.rmssd = rmssd
        self.pnn50 = pnn50
        self.sdsd = sdsd
        self.meanHR = meanHR
        self.sdHR = sdHR
        self.minHR = minHR
        self.maxHR = maxHR
        self.triangularIndex = triangularIndex
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case meanRR, sdnn, rmssd, pnn50, sdsd, meanHR, sdHR, minHR, maxHR, triangularIndex
    }

    /// Codable with defaults for missing fields
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Schema version: absent in legacy data → defaults to 0
        _ = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        meanRR = try container.decode(Double.self, forKey: .meanRR)
        sdnn = try container.decode(Double.self, forKey: .sdnn)
        rmssd = try container.decode(Double.self, forKey: .rmssd)
        pnn50 = try container.decode(Double.self, forKey: .pnn50)
        sdsd = try container.decode(Double.self, forKey: .sdsd)
        meanHR = try container.decode(Double.self, forKey: .meanHR)
        sdHR = try container.decode(Double.self, forKey: .sdHR)
        triangularIndex = try container.decodeIfPresent(Double.self, forKey: .triangularIndex)
        // Default min/max from SD if not present (backwards compatibility)
        minHR = try container.decodeIfPresent(Double.self, forKey: .minHR) ?? (meanHR - sdHR)
        maxHR = try container.decodeIfPresent(Double.self, forKey: .maxHR) ?? (meanHR + sdHR)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(meanRR, forKey: .meanRR)
        try container.encode(sdnn, forKey: .sdnn)
        try container.encode(rmssd, forKey: .rmssd)
        try container.encode(pnn50, forKey: .pnn50)
        try container.encode(sdsd, forKey: .sdsd)
        try container.encode(meanHR, forKey: .meanHR)
        try container.encode(sdHR, forKey: .sdHR)
        try container.encode(minHR, forKey: .minHR)
        try container.encode(maxHR, forKey: .maxHR)
        try container.encodeIfPresent(triangularIndex, forKey: .triangularIndex)
    }
}

/// Frequency-domain HRV metrics
struct FrequencyDomainMetrics: Codable {
    /// Very low frequency power (ms²) - nil if window < 10 min
    let vlf: Double?
    /// Low frequency power (ms²) - 0.04-0.15 Hz
    let lf: Double
    /// High frequency power (ms²) - 0.15-0.4 Hz
    let hf: Double
    /// LF/HF ratio - nil if HF is 0
    let lfHfRatio: Double?
    /// Total power (VLF + LF + HF)
    let totalPower: Double

    /// LF in normalized units (LF / (LF + HF) * 100)
    var lfNu: Double? {
        let sum = lf + hf
        guard sum > 0 else { return nil }
        return lf / sum * 100
    }

    /// HF in normalized units (HF / (LF + HF) * 100)
    var hfNu: Double? {
        let sum = lf + hf
        guard sum > 0 else { return nil }
        return hf / sum * 100
    }
}

/// Nonlinear HRV metrics (Poincaré plot, entropy, DFA)
struct NonlinearMetrics: Codable {
    /// Short-term variability (perpendicular to line of identity)
    let sd1: Double
    /// Long-term variability (along line of identity)
    let sd2: Double
    /// SD1/SD2 ratio
    let sd1Sd2Ratio: Double
    /// Sample entropy (complexity measure)
    let sampleEntropy: Double?
    /// Approximate entropy
    let approxEntropy: Double?
    /// DFA α1 (short-term fractal scaling, 4-16 beats)
    let dfaAlpha1: Double?
    /// DFA α2 (long-term fractal scaling, 16-64 beats)
    let dfaAlpha2: Double?
    /// R² fit quality for α1
    let dfaAlpha1R2: Double?
}

/// ANS Indexes (Autonomic Nervous System)
struct ANSMetrics: Codable {
    /// Baevsky's Stress Index (SI)
    let stressIndex: Double?
    /// Parasympathetic Nervous System Index (-3 to +3 typical)
    let pnsIndex: Double?
    /// Sympathetic Nervous System Index (-3 to +3 typical)
    let snsIndex: Double?
    /// HRV-only readiness score (1-10 scale) from the analysis pipeline.
    /// This is the *input* to RecoveryScoreCalculator, which combines it with
    /// sleep quality and vitals (v3.oct2026 architecture) to produce the
    /// composite `HRVSession.recoveryScore`.
    let readinessScore: Double?
    /// Estimated respiration rate (breaths/min)
    let respirationRate: Double?
    /// Nocturnal HR dip percentage: (daytimeHR - sleepHR) / daytimeHR * 100
    /// Normal range: 10-20%. <10% = blunted (cardiovascular risk), >20% = exaggerated
    let nocturnalHRDip: Double?
    /// Daytime resting HR used for dip calculation (bpm)
    let daytimeRestingHR: Double?
    /// Nocturnal median HR used for dip calculation (bpm)
    let nocturnalMedianHR: Double?
}

/// Peak autonomic capacity metrics - highest sustained HRV values observed
/// These represent physiological capacity, NOT readiness for training
/// "Sustained" = ≥4 min contiguous, artifact-clean, not an isolated spike
struct PeakCapacity: Codable {
    /// Highest sustained RMSSD observed (ms)
    let peakRMSSD: Double
    /// SDNN at the peak RMSSD window (ms)
    let peakSDNN: Double
    /// Total spectral power at the peak window (ms²), if available
    let peakTotalPower: Double?
    /// Duration of the peak window in minutes
    let windowDurationMinutes: Double
    /// Relative position of peak window within sleep (0.0-1.0)
    let windowRelativePosition: Double?
    /// Mean HR during the peak window (bpm)
    let windowMeanHR: Double?
}

/// Training context snapshot - captured at time of HRV recording
/// Stores ATL/CTL/TSB so historical reports show training state from that day
struct TrainingContext: Codable, Sendable {
    /// Acute Training Load (7-day EWMA of TRIMP) - "fatigue"
    let atl: Double
    /// Chronic Training Load (42-day EWMA of TRIMP) - "fitness"
    let ctl: Double
    /// Training-load balance (CTL - ATL) - "form/freshness"
    let tsb: Double
    /// Yesterday's TRIMP (training load day before this reading)
    let yesterdayTrimp: Double
    /// VO2max at time of recording (user override or HealthKit)
    var vo2Max: Double?
    /// Days since last hard workout
    let daysSinceHardWorkout: Int?
    /// Recent workout summary (last 3 days for context)
    let recentWorkouts: [WorkoutSnapshot]?

    init(atl: Double, ctl: Double, tsb: Double, yesterdayTrimp: Double, vo2Max: Double?, daysSinceHardWorkout: Int?, recentWorkouts: [WorkoutSnapshot]?) {
        self.atl = atl
        self.ctl = ctl
        self.tsb = tsb
        self.yesterdayTrimp = yesterdayTrimp
        self.vo2Max = vo2Max
        self.daysSinceHardWorkout = daysSinceHardWorkout
        self.recentWorkouts = recentWorkouts
    }

    /// Acute:Chronic Ratio (injury risk indicator)
    var acuteChronicRatio: Double? {
        guard ctl > 0 else { return nil }
        return atl / ctl
    }

    /// Create a TrainingContext snapshot from a TrainingLoad
    /// - Parameters:
    ///   - load: The training load data from HealthKit
    ///   - referenceDate: Anchor date for "yesterday" TRIMP lookup.
    ///     For live sessions this is now; for historical sessions pass the session's end date.
    init?(from load: HealthKitManager.TrainingLoad, relativeTo referenceDate: Date = Date()) {
        guard let metrics = load.metrics else { return nil }

        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: referenceDate))
        let yesterdayTrimp = yesterday.flatMap { metrics.dailyTrimp[$0] } ?? 0

        let snapshots = Self.snapshots(of: load)
        let safe = Self.sanitized(metrics)
        atl = safe.atl
        ctl = safe.ctl
        tsb = safe.tsb
        self.yesterdayTrimp = yesterdayTrimp
        vo2Max = load.vo2Max
        daysSinceHardWorkout = load.daysSinceHardWorkout
        recentWorkouts = snapshots.isEmpty ? nil : snapshots
    }

    /// Sanitize against NaN/Inf at the source. This is the ONE
    /// place a training snapshot is built from computed PMC metrics, and a
    /// non-finite atl/ctl here would be frozen straight into a session's
    /// trainingSnapshot (seen in device logs: "was atl=nan/ctl=nan"). Downstream
    /// scoring heals it and swallows NaN, but a persisted NaN pollutes the
    /// stored snapshot, the reanalyze diff, and any future consumer. Clamp
    /// to finite here so the corruption can never leave the initializer.
    ///
    /// TSB is definitionally ctl − atl; if the computed value is non-finite,
    /// derive it from the sanitized components rather than storing NaN.
    private static func sanitized(
        _ metrics: TrainingMetrics
    ) -> (atl: Double, ctl: Double, tsb: Double) {
        let safeAtl = metrics.atl.isFinite ? metrics.atl : 0
        let safeCtl = metrics.ctl.isFinite ? metrics.ctl : 0
        let safeTsb = metrics.tsb.isFinite ? metrics.tsb : (safeCtl - safeAtl)
        return (safeAtl, safeCtl, safeTsb)
    }

    /// The five most recent workouts, flattened to the fields a snapshot keeps.
    private static func snapshots(of load: HealthKitManager.TrainingLoad) -> [WorkoutSnapshot] {
        load.recentWorkouts.prefix(5).map { workout in
            WorkoutSnapshot(
                date: workout.date,
                type: workout.typeDescription,
                durationMinutes: workout.durationMinutes,
                trimp: workout.userScaledLoad
            )
        }
    }

    static let empty = TrainingContext(
        atl: 0, ctl: 0, tsb: 0, yesterdayTrimp: 0,
        vo2Max: nil, daysSinceHardWorkout: nil, recentWorkouts: nil
    )
}

/// Lightweight workout snapshot for storing with session
struct WorkoutSnapshot: Codable {
    let date: Date
    let type: String
    let durationMinutes: Double
    let trimp: Double
}

/// Complete HRV analysis result for a window
struct HRVAnalysisResult: Codable, Sendable {
    let windowStart: Int
    let windowEnd: Int
    let timeDomain: TimeDomainMetrics
    let frequencyDomain: FrequencyDomainMetrics?
    let nonlinear: NonlinearMetrics
    let ansMetrics: ANSMetrics?
    let artifactPercentage: Double
    let cleanBeatCount: Int
    let analysisDate: Date

    // Window selection info (for display)
    var windowStartMs: Int64?
    var windowEndMs: Int64?
    var windowMeanHR: Double?
    var windowHRStability: Double?
    var windowSelectionReason: String?
    /// Relative position of analysis window within sleep episode (0.0-1.0)
    var windowRelativePosition: Double?
    /// Whether the window represents consolidated recovery (sustained plateau AND stable HR)
    /// This distinguishes true readiness from mere high HRV capacity
    var isConsolidated: Bool?
    /// Whether the window shows organized parasympathetic control (DFA α1 ~0.75-1.0, low LF/HF)
    /// vs high variability without organization (capacity, not recovery)
    var isOrganizedRecovery: Bool?
    /// Classification label for the selected window (Organized Recovery vs High Variability)
    var windowClassification: String?
    /// All organized-recovery zones found in the 30–70% sleep band.
    /// Used by the overnight chart to paint green highlights showing where
    /// organized parasympathetic control was detected — so the user can see
    /// at a glance where recovery lives instead of trial-and-error with
    /// manual window selection.
    var organizedRecoveryZones: [TimeRange]?

    /// A simple millisecond time range, Codable for archive persistence.
    struct TimeRange: Codable, Equatable {
        let startMs: Int64
        let endMs: Int64
    }

    /// Peak autonomic capacity - highest sustained HRV values observed during the night
    /// This represents physiological capacity, separate from readiness assessment
    var peakCapacity: PeakCapacity?
    /// Training context snapshot - ATL/CTL/TSB frozen at time of this reading
    var trainingContext: TrainingContext?
    /// Provenance: which sleep segment this analysis covers (e.g., "Segment 2 (6:30–9:00 AM)")
    var analysisSegmentLabel: String?
    /// Provenance: whether this result came from a reanalysis (vs original analysis)
    var isReanalysis: Bool?

    /// Whole-session HR summary computed across the FULL recording (not just the
    /// analysis window). The user reasons about "what was my nadir last night"
    /// over the whole night, not over a 5-minute slice. Persisted on the result
    /// so the AI assistant, history view, and exports all see the same value
    /// without needing to re-scan the RR series. `nadirTimeMs` is relative to
    /// session start; pair with `RRSeries.wallClockTime(forTMs:)` for clock time.
    var overnightNadirHR: Double?
    var overnightNadirTimeMs: Int64?
    var overnightMinHR: Double?
    var overnightMaxHR: Double?
    var overnightMeanHR: Double?
}

// MARK: - Display labels

extension HRVAnalysisResult {
    /// `windowClassification` in the app's language. The stored value is an
    /// English storage key (a `WindowClassification` raw value or "Peak
    /// Capacity"); an unrecognised one is shown as stored.
    var displayWindowClassification: String? {
        guard let stored = windowClassification else { return nil }
        let b = LanguageManager.appBundle
        return switch stored {
        case "Organized Recovery": String(localized: "Organized Recovery", bundle: b)
        case "Flexible / Unconsolidated": String(localized: "Flexible / Unconsolidated", bundle: b)
        case "High Variability": String(localized: "High Variability", bundle: b)
        case "Insufficient Data": String(localized: "Insufficient Data", bundle: b)
        case "Peak Capacity": String(localized: "Peak Capacity", bundle: b)
        default: stored
        }
    }

    /// `windowSelectionReason` in the app's language. The stored value is an
    /// English line the window selector writes in one of four fixed shapes;
    /// its numbers are read back out and set in a translated sentence. A
    /// line in none of those shapes is shown as stored.
    var displayWindowSelectionReason: String? {
        guard let stored = windowSelectionReason else { return nil }
        return WindowSelectionReasonText.localized(stored) ?? stored
    }
}

/// Reads the window selector's stored English reason lines
/// (`WindowSelector.selectionReason`, `peakSelectionReason`,
/// `manualSelectionReason`) back into their numbers.
enum WindowSelectionReasonText {
    private struct Numbers {
        let value: String
        let alpha1: String
        let cv: String
        let position: Int
    }

    static func localized(_ stored: String) -> String? {
        let b = LanguageManager.appBundle
        if stored == "No consolidated recovery detected" {
            return String(localized: "No consolidated recovery detected", bundle: b)
        }
        if stored.hasPrefix("Organized Recovery ("), let n = numbers(in: stored, valueAfter: "(RMSSD ") {
            return String(localized: "Organized recovery at \(n.position)% of the recording (RMSSD \(n.value) ms, α1 \(n.alpha1), HR CV \(n.cv)%)", bundle: b)
        }
        if stored.hasPrefix("Manual selection at "), let n = numbers(in: stored, valueAfter: "(RMSSD ") {
            return String(localized: "Manual selection at \(n.position)% of the recording (RMSSD \(n.value) ms, α1 \(n.alpha1), HR CV \(n.cv)%)", bundle: b)
        }
        if stored.hasPrefix("Peak "), let metric = field(stored, after: "Peak ", before: " ("),
           let n = numbers(in: stored, valueAfter: nil) {
            return String(localized: "Peak \(metric) at \(n.position)% of the recording (\(n.value) ms, α1 \(n.alpha1), HR CV \(n.cv)%)", bundle: b)
        }
        return nil
    }

    /// The measured value (after `valueAfter`, or the last "(" before
    /// " ms, α1=" when nil), α1, heart-rate CV and position in the recording.
    private static func numbers(in stored: String, valueAfter marker: String?) -> Numbers? {
        let rawValue = marker.flatMap { field(stored, after: $0, before: " ms") } ?? bracketedValue(in: stored)
        guard let value = rawValue.flatMap(Double.init),
              let rawAlpha = field(stored, after: "α1=", before: ","),
              let cv = field(stored, after: "CV ", before: "%").flatMap(Double.init),
              let position = positionPercent(in: stored) else { return nil }
        let alpha1 = Double(rawAlpha).map { formatted($0, digits: 2) } ?? "—"
        return Numbers(value: formatted(value, digits: 1), alpha1: alpha1, cv: formatted(cv, digits: 1), position: position)
    }

    /// "… at 52%" at the end, or "Manual selection at 52% (…".
    private static func positionPercent(in stored: String) -> Int? {
        if stored.hasPrefix("Manual selection at ") {
            return field(stored, after: "Manual selection at ", before: "%").flatMap { Int($0) }
        }
        guard let at = stored.range(of: ") at ", options: .backwards) else { return nil }
        return Int(stored[at.upperBound...].dropLast())
    }

    private static func bracketedValue(in stored: String) -> String? {
        guard let end = stored.range(of: " ms, α1="),
              let open = stored.range(of: "(", options: .backwards, range: stored.startIndex ..< end.lowerBound)
        else { return nil }
        return String(stored[open.upperBound ..< end.lowerBound])
    }

    private static func field(_ text: String, after start: String, before end: String) -> String? {
        guard let lower = text.range(of: start),
              let upper = text.range(of: end, range: lower.upperBound ..< text.endIndex) else { return nil }
        return String(text[lower.upperBound ..< upper.lowerBound])
    }

    private static func formatted(_ value: Double, digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(digits)).locale(LanguageManager.appLocale))
    }
}
