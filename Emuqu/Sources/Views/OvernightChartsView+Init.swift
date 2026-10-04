import SwiftUI

// The convenience initialisers and the `OvernightStats` model, split out of
// `OvernightChartsView.swift`. The chart bodies and stat
// computation stay behind.

// MARK: - Convenience init (no inter-chart content)

// MARK: - ViewBuilder Init

extension OvernightChartsView {
    init(
        session: HRVSession,
        result: HRVAnalysisResult,
        healthKitSleep: SleepData? = nil,
        onReanalyzeAt: ((Int64) -> Void)? = nil,
        isManualWindowMode: Bool = false,
        manualResult: HRVAnalysisResult? = nil,
        hideSleepRow: Bool = false,
        @ViewBuilder interChartContent: () -> InterChartContent
    ) {
        self.session = session
        self.result = result
        self.healthKitSleep = healthKitSleep
        self.onReanalyzeAt = onReanalyzeAt
        self.isManualWindowMode = isManualWindowMode
        self.manualResult = manualResult
        self.hideSleepRow = hideSleepRow
        self.interChartContent = interChartContent()
    }
}

extension OvernightChartsView where InterChartContent == EmptyView {
    init(
        session: HRVSession,
        result: HRVAnalysisResult,
        healthKitSleep: SleepData? = nil,
        onReanalyzeAt: ((Int64) -> Void)? = nil,
        isManualWindowMode: Bool = false,
        manualResult: HRVAnalysisResult? = nil,
        hideSleepRow: Bool = false
    ) {
        self.session = session
        self.result = result
        self.healthKitSleep = healthKitSleep
        self.onReanalyzeAt = onReanalyzeAt
        self.isManualWindowMode = isManualWindowMode
        self.manualResult = manualResult
        self.hideSleepRow = hideSleepRow
        interChartContent = EmptyView()
    }
}

// MARK: - Overnight Stats Model

struct OvernightStats {
    let nadirHR: Double
    let nadirIndex: Int
    let nadirTimeMs: Int64
    let nadirTimeFormatted: String
    let minHR: Double
    let maxHR: Double
    let avgHR: Double
    let peakRMSSD: Double
    let peakHRVIndex: Int
    let peakHRVTimeMs: Int64
    let peakHRVTimeFormatted: String
    let avgRMSSD: Double
    let rollingRMSSD: [(index: Int, rmssd: Double)]
    let hrValues: [(index: Int, hr: Double)]
    /// Full recording HR/HRV data for chart plotting (no sleep boundary filter)
    let allHrValues: [(index: Int, hr: Double)]
    let allRollingRMSSD: [(index: Int, rmssd: Double)]
    let windowStartIndex: Int
    let windowEndIndex: Int
    let windowStartMs: Int64 // Timestamp in ms from session start for window start
    let windowEndMs: Int64 // Timestamp in ms from session start for window end
    let windowStartTimeFormatted: String // Clock time when analysis window starts
    let windowEndTimeFormatted: String // Clock time when analysis window ends

    // Sleep metrics: from HealthKit when available, otherwise only a rough
    // duration estimated from the recording length.
    let estimatedSleepDurationMinutes: Int
    let estimatedSleepDurationFormatted: String
    let deepSleepMinutes: Int? // HealthKit deep-stage minutes; nil when unknown
    let awakeningsCount: Int? // HealthKit awake periods inside the sleep span; nil when unknown
    let sleepEfficiency: Double? // Percent; nil when the night's wake was not measured
    let isHealthKitData: Bool // True if sleep data came from Apple Health

    /// Sleep segment boundaries for chart shading (ms from session start).
    /// Multiple entries for split nights; single entry for normal nights; empty when unknown.
    /// Values may be negative when HealthKit sleep extends before the recording start.
    let sleepSegmentRanges: [(startMs: Int64, endMs: Int64)]

    /// Chart viewport start in ms from session start.
    /// Extended beyond recording bounds when HealthKit HR data is available for uncovered segments.
    var chartStartMs: Int64
    /// Chart viewport end in ms from session start.
    var chartEndMs: Int64

    /// Apple Watch HR samples for sleep segments not covered by Polar data.
    /// Plotted as a lighter overlay so users can see HR across the full night.
    var healthKitHR: [(timeMs: Int64, hr: Double)]

    /// Organized-recovery zones (ms from session start). Rendered as faint
    /// green bands on the HRV chart so users can see where parasympathetic
    /// recovery was detected without trial-and-error window selection.
    var organizedRecoveryZones: [HRVAnalysisResult.TimeRange]

    /// Return a copy with HealthKit HR data and updated chart bounds.
    ///
    /// Updates the summary fields too, not just the chart payload. If
    /// `minHR` / `maxHR` / `nadirHR` / `avgHR` stayed
    /// at whatever the RR-derived path produced, then when the strap
    /// recorded RR-only (no `point.hr` field) and the RR-window
    /// fallback yielded no usable HR samples, the summary card would sit at
    /// 0-0 bpm even though the chart renders real Apple Watch
    /// data right next to it. So: if the existing summary is zero,
    /// derive min / max / nadir / avg from the HK samples too. The
    /// chart and the summary now agree about which session they're
    /// describing. A backfilled nadir also gets its clock time, so the card
    /// and its VoiceOver label never read "at" with no time after it.
    /// `sessionStart` is the date the samples' `timeMs` offsets count from.
    func withHealthKitHR(
        _ hr: [(timeMs: Int64, hr: Double)], sessionStart: Date, chartStartMs: Int64, chartEndMs: Int64
    ) -> OvernightStats {
        let s = resolvedHRSummary(from: hr)
        return OvernightStats(
            nadirHR: s.nadir, nadirIndex: nadirIndex, nadirTimeMs: s.nadirTimeMs,
            nadirTimeFormatted: resolvedNadirTimeFormatted(s, sessionStart: sessionStart), minHR: s.min, maxHR: s.max, avgHR: s.avg,
            peakRMSSD: peakRMSSD, peakHRVIndex: peakHRVIndex, peakHRVTimeMs: peakHRVTimeMs,
            peakHRVTimeFormatted: peakHRVTimeFormatted, avgRMSSD: avgRMSSD,
            rollingRMSSD: rollingRMSSD, hrValues: hrValues, allHrValues: allHrValues,
            allRollingRMSSD: allRollingRMSSD, windowStartIndex: windowStartIndex,
            windowEndIndex: windowEndIndex, windowStartMs: windowStartMs, windowEndMs: windowEndMs,
            windowStartTimeFormatted: windowStartTimeFormatted, windowEndTimeFormatted: windowEndTimeFormatted,
            estimatedSleepDurationMinutes: estimatedSleepDurationMinutes,
            estimatedSleepDurationFormatted: estimatedSleepDurationFormatted,
            deepSleepMinutes: deepSleepMinutes, awakeningsCount: awakeningsCount,
            sleepEfficiency: sleepEfficiency, isHealthKitData: isHealthKitData,
            sleepSegmentRanges: sleepSegmentRanges, chartStartMs: chartStartMs, chartEndMs: chartEndMs,
            healthKitHR: hr, organizedRecoveryZones: organizedRecoveryZones
        )
    }

    /// The five HR summary fields, backfilled from HK samples when the
    /// RR-derived path produced none. `OvernightStats` uses let-bound fields,
    /// so the caller builds a fresh instance from the union of values.
    private func resolvedHRSummary(from hr: [(timeMs: Int64, hr: Double)]) -> HRSummary {
        let needsBackfill = (minHR == 0 || maxHR == 0 || nadirHR == 0) && !hr.isEmpty
        guard needsBackfill else {
            return HRSummary(min: minHR, max: maxHR, nadir: nadirHR, nadirTimeMs: nadirTimeMs, avg: avgHR)
        }
        let sorted = hr.map(\.hr).sorted()
        return HRSummary(
            min: sorted.first ?? 0,
            max: sorted.last ?? 0,
            nadir: sorted.first ?? 0,
            nadirTimeMs: hr.min(by: { $0.hr < $1.hr })?.timeMs ?? nadirTimeMs,
            avg: Self.trimmedMean(sorted)
        )
    }

    private func resolvedNadirTimeFormatted(_ summary: HRSummary, sessionStart: Date) -> String {
        guard nadirTimeFormatted.isEmpty, summary.nadir > 0 else { return nadirTimeFormatted }
        let date = sessionStart.addingTimeInterval(TimeInterval(summary.nadirTimeMs) / 1000)
        return OvernightChartFormatters.clockTimeFormatter.string(from: date)
    }

    struct HRSummary {
        let min: Double
        let max: Double
        let nadir: Double
        let nadirTimeMs: Int64
        let avg: Double
    }

    /// 5–95 % trimmed mean once there are enough samples for trimming to mean
    /// anything; a plain mean below that.
    private static func trimmedMean(_ sorted: [Double]) -> Double {
        guard sorted.count >= 10 else {
            return sorted.reduce(0, +) / Double(max(sorted.count, 1))
        }
        let lo = Int(Double(sorted.count) * 0.05)
        let hi = Int(Double(sorted.count) * 0.95)
        let trimmed = Array(sorted[lo ..< hi])
        return trimmed.reduce(0, +) / Double(trimmed.count)
    }

    static let empty = OvernightStats(
        nadirHR: 0, nadirIndex: 0, nadirTimeMs: 0, nadirTimeFormatted: "",
        minHR: 0, maxHR: 0, avgHR: 0,
        peakRMSSD: 0, peakHRVIndex: 0, peakHRVTimeMs: 0, peakHRVTimeFormatted: "",
        avgRMSSD: 0, rollingRMSSD: [], hrValues: [],
        allHrValues: [], allRollingRMSSD: [],
        windowStartIndex: 0, windowEndIndex: 0,
        windowStartMs: 0, windowEndMs: 0,
        windowStartTimeFormatted: "", windowEndTimeFormatted: "",
        estimatedSleepDurationMinutes: 0, estimatedSleepDurationFormatted: "",
        deepSleepMinutes: 0, awakeningsCount: 0, sleepEfficiency: nil,
        isHealthKitData: false,
        sleepSegmentRanges: [],
        chartStartMs: 0, chartEndMs: 0,
        healthKitHR: [],
        organizedRecoveryZones: []
    )
}
