import Charts
import SwiftUI

/// The overnight HRV and heart-rate charts on the recovery-score detail screen,
/// with their hover pills and the inline window picker.
///
/// Split out of `RecoveryScoreDetailView` — 672 lines out of a
/// 1,930-line view, the same shape as [MorningDetailCards] and
/// [MorningReanalysisControls] on the morning screen.
///
/// Deliberately NOT a `View`. It returns the same view trees from the same
/// positions, so SwiftUI identity, animation and `@State` behaviour are
/// unchanged. The hover and window-preview state travels back through bindings
/// rather than being duplicated here.
@MainActor
struct RecoveryScoreCharts {
    let session: HRVSession
    let result: HRVAnalysisResult
    let onReanalyzeAt: ((Int64) async -> Void)?

    let hrChartSeries: [RecoveryScoreCharts.HRPoint]
    let rmssdChartSeries: [RecoveryScoreCharts.RMSSDPoint]
    let organizedZoneRanges: [HRVAnalysisResult.TimeRange]
    let recordingStartMs: Int64?
    let recordingEndMs: Int64?
    let analysisWindowDateRange: (start: Date, end: Date)?

    @Binding var hrHoverDate: Date?
    @Binding var hrvHoverDate: Date?
    @Binding var previewWindowMs: Int64?
    @Binding var selectedWindowSegment: RecoveryScoreDetailView.AnalysisWindowSegment
    @Binding var segmentBeforePick: RecoveryScoreDetailView.AnalysisWindowSegment
    @Binding var restoringSegment: Bool
    @Binding var windowChangedHere: Bool
    @Binding var isReanalyzing: Bool
    @Binding var didCompleteInitialLoad: Bool
    @Binding var fallbackHRSamples: [(date: Date, hr: Double)]
}

// MARK: - Forwarders

// Charts live in `RecoveryScoreCharts`, keeping 672 lines out of
// RecoveryScoreDetailView. `charts` is rebuilt on each access from the view's
// live state and every mutation travels back through a binding, so behaviour
// matches an inline implementation.

extension RecoveryScoreDetailView {
    var charts: RecoveryScoreCharts {
        RecoveryScoreCharts(
            session: session,
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
            isReanalyzing: $isReanalyzing,
            didCompleteInitialLoad: $didCompleteInitialLoad,
            fallbackHRSamples: $fallbackHRSamples
        )
    }

    nonisolated static func buildRMSSDSeries(
        series: RRSeries?,
        flags: [ArtifactFlags]?,
        sessionStartDate: Date
    ) -> [RecoveryScoreCharts.RMSSDPoint] {
        RecoveryScoreCharts.buildRMSSDSeries(
            series: series, flags: flags, sessionStartDate: sessionStartDate
        )
    }

    nonisolated static func buildHRSeries(
        series: RRSeries?,
        flags: [ArtifactFlags]?,
        sessionStartDate: Date,
        fallbackHRSamples: [(date: Date, hr: Double)]
    ) -> [RecoveryScoreCharts.HRPoint] {
        RecoveryScoreCharts.buildHRSeries(
            series: series, flags: flags, sessionStartDate: sessionStartDate,
            fallbackHRSamples: fallbackHRSamples
        )
    }

    var hrvOvernightChart: some View { charts.hrvOvernightChart }

    var heartRateOvernightChart: some View { charts.heartRateOvernightChart }
}
