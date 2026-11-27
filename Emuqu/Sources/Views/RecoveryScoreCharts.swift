import Charts
import SwiftUI

/// The overnight HRV and heart-rate charts on the recovery-score detail screen,
/// with their hover pills and the inline window picker.
///
/// Deliberately NOT a `View`: it returns view trees into the host view's
/// body, so SwiftUI identity, animation and `@State` stay the host's. The
/// hover and window-preview state travels back through bindings rather than
/// being duplicated here.
@MainActor
struct RecoveryScoreCharts {
    let session: HRVSession
    /// The session's beats (`effectiveRRSeries`), which place every `t_ms`
    /// position on the chart's clock (`HRVSession.clockTime(forTMs:series:)`);
    /// nil for a lightweight session whose beats have not loaded.
    let rrSeries: RRSeries?
    let result: HRVAnalysisResult
    let onReanalyzeAt: ((Int64) async -> Bool)?

    let hrChartSeries: [RecoveryScoreCharts.HRPoint]
    let rmssdChartSeries: [RecoveryScoreCharts.RMSSDPoint]
    let organizedZoneRanges: [HRVAnalysisResult.TimeRange]
    let recordingStartMs: Int64?
    let recordingEndMs: Int64?
    let analysisWindowDateRange: (start: Date, end: Date)?

    @Binding var hrHoverDate: Date?
    @Binding var hrvHoverDate: Date?
    @Binding var previewWindowMs: Int64?
    @Binding var selectedWindowSegment: RecoveryScoreDetailView.AnalysisWindowSegment?
    @Binding var segmentBeforePick: RecoveryScoreDetailView.AnalysisWindowSegment?
    @Binding var restoringSegment: Bool
    @Binding var windowChangedHere: Bool
    @Binding var isReanalyzing: Bool
    @Binding var reanalysisFailed: Bool
    @Binding var didCompleteInitialLoad: Bool
    @Binding var fallbackHRSamples: [(date: Date, hr: Double)]
}

// MARK: - Host accessor

// `charts` is rebuilt on each access from the view's live state, and every
// mutation travels back through a binding.

extension RecoveryScoreDetailView {
    var charts: RecoveryScoreCharts {
        RecoveryScoreCharts(
            session: session, rrSeries: effectiveRRSeries,
            result: result,
            onReanalyzeAt: onReanalyzeAt,
            hrChartSeries: hrChartSeries,
            rmssdChartSeries: rmssdChartSeries,
            organizedZoneRanges: organizedZoneRanges,
            recordingStartMs: recordingStartMs,
            recordingEndMs: recordingEndMs,
            analysisWindowDateRange: analysisWindowDateRange,
            hrHoverDate: $hrHoverDate,
            hrvHoverDate: $hrvHoverDate,
            previewWindowMs: $previewWindowMs,
            selectedWindowSegment: $selectedWindowSegment,
            segmentBeforePick: $segmentBeforePick, restoringSegment: $restoringSegment,
            windowChangedHere: $windowChangedHere,
            isReanalyzing: $isReanalyzing, reanalysisFailed: $reanalysisFailed,
            didCompleteInitialLoad: $didCompleteInitialLoad,
            fallbackHRSamples: $fallbackHRSamples
        )
    }

    nonisolated static func buildRMSSDSeries(
        series: RRSeries?,
        flags: [ArtifactFlags]?
    ) -> [RecoveryScoreCharts.RMSSDPoint] {
        RecoveryScoreCharts.buildRMSSDSeries(series: series, flags: flags)
    }

    nonisolated static func buildHRSeries(
        series: RRSeries?,
        flags: [ArtifactFlags]?,
        fallbackHRSamples: [(date: Date, hr: Double)]
    ) -> [RecoveryScoreCharts.HRPoint] {
        RecoveryScoreCharts.buildHRSeries(series: series, flags: flags, fallbackHRSamples: fallbackHRSamples)
    }

    var hrvOvernightChart: some View { charts.hrvOvernightChart }

    var heartRateOvernightChart: some View { charts.heartRateOvernightChart }
}
