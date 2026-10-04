import Foundation
import PDFKit
import UIKit

// The page-drawing helpers. Members are internal rather than `private` because
// Swift's `private` does not reach across files.

extension PDFReportGenerator {
    // MARK: - Page Drawing Helpers

    /// Draw Page 1: header, summary card, optional sections, tags, and footer
    @discardableResult
    func drawPage1_SummaryAndMetrics(
        _ inputs: ReportInputs,
        pageNumber: inout Int,
        in context: UIGraphicsPDFRendererContext, pageRect: CGRect
    ) -> CGFloat {
        context.beginPage()
        var y = drawHeader(session: inputs.session, result: inputs.result, in: context, pageRect: pageRect)
        y = drawSummaryCard(
            result: inputs.result,
            ans: inputs.result.ansMetrics,
            compositeScore: inputs.compositeRecoveryScore,
            yPosition: y,
            in: context,
            pageRect: pageRect
        )
        y = drawPage1Sections(inputs, y: y, pageNumber: &pageNumber, in: context, pageRect: pageRect)
        y = drawPage1Tail(inputs, y: y, pageNumber: &pageNumber, in: context, pageRect: pageRect)
        drawFooter(pageNumber: pageNumber, in: context, pageRect: pageRect)
        pageNumber += 1
        return y
    }

    /// The optional stat sections, each drawn only when its data exists and the
    /// caller asked for it.
    func drawPage1Sections(
        _ inputs: ReportInputs,
        y: CGFloat,
        pageNumber: inout Int,
        in context: UIGraphicsPDFRendererContext, pageRect: CGRect
    ) -> CGFloat {
        var y = y
        y = drawOvernightStatsIfAvailable(inputs, y: y, in: context, pageRect: pageRect)
        if inputs.sections.contains(.sleep), let sleep = inputs.sleepData, sleep.totalSleepMinutes > 0 {
            y = drawSleepAnalysisSection(sleep: sleep, yPosition: y, in: context, pageRect: pageRect)
        }
        if inputs.sections.contains(.trainingLoad), let training = inputs.trainingContext {
            y = drawTrainingLoadSection(training: training, yPosition: y, in: context, pageRect: pageRect)
        }
        if inputs.sections.contains(.vitals), let vitalsData = inputs.vitals, vitalsData.hasAnyData {
            y = drawVitalsSection(vitals: vitalsData, yPosition: y, in: context, pageRect: pageRect)
        }
        if inputs.sections.contains(.scoreBreakdown), let breakdown = inputs.scoreBreakdown {
            y = ensureSpace(needed: 120, y: y, pageNumber: &pageNumber, context: context, pageRect: pageRect)
            y = drawScoreBreakdownSection(breakdown: breakdown, yPosition: y, in: context, pageRect: pageRect)
        }
        return y
    }

    /// Sleep, nadir and peak HRV — only meaningful with a raw RR series.
    func drawOvernightStatsIfAvailable(
        _ inputs: ReportInputs,
        y: CGFloat,
        in context: UIGraphicsPDFRendererContext, pageRect: CGRect
    ) -> CGFloat {
        guard inputs.sections.contains(.overnightStats), inputs.hasRawData, let series = inputs.series else { return y }
        return drawOvernightStatsSection(inputs, series: series, yPosition: y, pageRect: pageRect)
    }

    /// Detailed tables, tags/notes, and the imported-data caveat.
    func drawPage1Tail(
        _ inputs: ReportInputs,
        y: CGFloat,
        pageNumber: inout Int,
        in context: UIGraphicsPDFRendererContext, pageRect: CGRect
    ) -> CGFloat {
        var y = y
        if inputs.style == .comprehensive, inputs.sections.contains(.deepDive) {
            y = drawDetailedMetricTables(
                result: inputs.result,
                yPosition: y,
                pageNumber: &pageNumber,
                in: context,
                pageRect: pageRect
            )
        }
        if !inputs.session.tags.isEmpty || inputs.session.notes != nil {
            y = ensureSpace(needed: 50, y: y, pageNumber: &pageNumber, context: context, pageRect: pageRect)
            y = drawTagsAndNotesSection(session: inputs.session, yPosition: y, in: context, pageRect: pageRect)
        }
        if !inputs.hasRawData {
            y = drawImportedDataNote(yPosition: y, session: inputs.session, in: context, pageRect: pageRect)
        }
        return y
    }

    /// Draw detailed metric tables (time domain, frequency domain, nonlinear, ANS)
    func drawDetailedMetricTables(
        result: HRVAnalysisResult, yPosition: CGFloat, pageNumber: inout Int,
        in context: UIGraphicsPDFRendererContext, pageRect: CGRect
    ) -> CGFloat {
        var y = ensureSpace(needed: 60, y: yPosition, pageNumber: &pageNumber, context: context, pageRect: pageRect)
        y = drawTimeDomainSection(result.timeDomain, yPosition: y, in: context, pageRect: pageRect)

        if let fd = result.frequencyDomain {
            y = ensureSpace(needed: 60, y: y, pageNumber: &pageNumber, context: context, pageRect: pageRect)
            y = drawFrequencyDomainSection(fd, yPosition: y, in: context, pageRect: pageRect)
        }

        y = ensureSpace(needed: 60, y: y, pageNumber: &pageNumber, context: context, pageRect: pageRect)
        y = drawNonlinearSection(result.nonlinear, yPosition: y, in: context, pageRect: pageRect)

        if let ans = result.ansMetrics {
            y = ensureSpace(needed: 60, y: y, pageNumber: &pageNumber, context: context, pageRect: pageRect)
            y = drawANSSection(ans, yPosition: y, in: context, pageRect: pageRect)
        }

        return y
    }

    /// Draw Page 2: visualizations (overnight HR chart, Poincare, PSD, tachogram)
    @discardableResult
    func drawPage2_Visualizations(
        _ inputs: ReportInputs,
        pageNumber: inout Int,
        in context: UIGraphicsPDFRendererContext, pageRect: CGRect
    ) -> CGFloat {
        context.beginPage()
        var y = config.margins.top
        guard let series = inputs.series else { return y }
        y = drawOvernightHRChart(series: series, result: inputs.result, yPosition: y, in: context, pageRect: pageRect)
        y = drawPoincarePlot(series: series, flags: inputs.artifactFlags, result: inputs.result, yPosition: y, in: context, pageRect: pageRect)

        if let fd = inputs.result.frequencyDomain {
            let window = inputs.result.windowStart ..< max(inputs.result.windowStart, inputs.result.windowEnd)
            y = drawPSDGraph(series: series, flags: inputs.artifactFlags, fd: fd, window: window, yPosition: y, in: context, pageRect: pageRect)
        }

        y = drawTachogram(series: series, flags: inputs.artifactFlags, result: inputs.result, yPosition: y, in: context, pageRect: pageRect)
        y = drawQualitySection(inputs.result, session: inputs.session, yPosition: y, in: context, pageRect: pageRect)

        if inputs.result.windowStartMs != nil || inputs.result.windowSelectionReason != nil {
            y = drawWindowSelectionSection(result: inputs.result, yPosition: y, in: context, pageRect: pageRect)
        }
        drawFooter(pageNumber: pageNumber, in: context, pageRect: pageRect)
        pageNumber += 1
        return y
    }

    /// Draw deep-dive analysis pages and analysis summary
    func drawDeepDivePages(
        _ inputs: ReportInputs,
        pageNumber: inout Int,
        in context: UIGraphicsPDFRendererContext, pageRect: CGRect
    ) {
        context.beginPage()
        var y = drawDeepHRVAnalysis(
            result: inputs.result,
            session: inputs.session,
            recentSessions: inputs.recentSessions,
            pageNumber: &pageNumber,
            yPosition: config.margins.top,
            in: context,
            pageRect: pageRect
        )
        y = drawDeepSleepIfAvailable(inputs, y: y, pageNumber: &pageNumber, in: context, pageRect: pageRect)
        y = drawDeepTrainingAndVitals(inputs, y: y, pageNumber: &pageNumber, in: context, pageRect: pageRect)
        _ = y
        drawFooter(pageNumber: pageNumber, in: context, pageRect: pageRect)
        pageNumber += 1
        drawAnalysisSummaryPage(inputs, pageNumber: pageNumber, in: context, pageRect: pageRect)
    }

    /// Each deep-dive block honours its own section switch too: turning off
    /// Recovery Vitals before sending the report to a coach must keep the
    /// vitals analysis out of the deep dive as well.
    func drawDeepTrainingAndVitals(
        _ inputs: ReportInputs,
        y: CGFloat,
        pageNumber: inout Int,
        in context: UIGraphicsPDFRendererContext, pageRect: CGRect
    ) -> CGFloat {
        var y = y
        if inputs.sections.contains(.trainingLoad), let training = inputs.trainingContext {
            y = ensureSpace(needed: 100, y: y, pageNumber: &pageNumber, context: context, pageRect: pageRect)
            y = drawDeepTrainingAnalysis(training: training, pageNumber: &pageNumber, yPosition: y, in: context, pageRect: pageRect)
        }

        if inputs.sections.contains(.vitals), let vitalsData = inputs.vitals, vitalsData.hasAnyData {
            y = ensureSpace(needed: 100, y: y, pageNumber: &pageNumber, context: context, pageRect: pageRect)
            y = drawDeepVitalsAnalysis(vitals: vitalsData, pageNumber: &pageNumber, yPosition: y, in: context, pageRect: pageRect)
        }
        return y
    }

    func drawDeepSleepIfAvailable(
        _ inputs: ReportInputs,
        y: CGFloat,
        pageNumber: inout Int,
        in context: UIGraphicsPDFRendererContext, pageRect: CGRect
    ) -> CGFloat {
        guard inputs.sections.contains(.sleep), let sleep = inputs.sleepData, sleep.totalSleepMinutes > 0 else { return y }
        let y = ensureSpace(needed: 100, y: y, pageNumber: &pageNumber, context: context, pageRect: pageRect)
        return drawDeepSleepAnalysis(
            sleep: sleep,
            sleepTrend: inputs.sleepTrend,
            pageNumber: &pageNumber,
            yPosition: y,
            in: context,
            pageRect: pageRect
        )
    }

    func drawAnalysisSummaryPage(
        _ inputs: ReportInputs,
        pageNumber: Int,
        in context: UIGraphicsPDFRendererContext, pageRect: CGRect
    ) {
        context.beginPage()
        var page = pageNumber
        _ = drawAnalysisSummarySection(inputs, yPosition: config.margins.top, pageNumber: &page, in: context, pageRect: pageRect)
        drawFooter(pageNumber: page, in: context, pageRect: pageRect)
    }

    /// Generate and save PDF to temporary file, return URL
    /// - Parameters:
    ///   - session: The HRV session to generate a report for
    ///   - sleepData: HealthKit sleep data for accurate sleep reporting
    ///   - sleepTrend: Sleep trend data for context
    ///   - recentSessions: Recent sessions for trend comparison
    ///   - healthKitHR: HealthKit heart rate statistics (mean, min, max, nadir time) for accurate HR reporting
    ///   - vitals: Recovery vitals data for the report
    ///   - compositeRecoveryScore: Composite recovery score (0-100)
    func generateReportURL(
        for session: HRVSession,
        sleepData: SleepData? = nil,
        sleepTrend: SleepTrendData? = nil,
        recentSessions: [HRVSession] = [],
        healthKitHR: HeartRateStats? = nil,
        vitals: VitalsData? = nil,
        compositeRecoveryScore: Double? = nil,
        scoreBreakdown: RecoveryScoreCalculator.ScoreBreakdown? = nil,
        baselineStats: BaselineTracker.RecoveryBaselineStats? = nil,
        liveLoadSnapshot: TrainingLoadRegistry.TrainingLoad? = nil,
        style: ReportStyle = .comprehensive,
        sections: ReportSections = .all
    ) -> URL? {
        guard let data = generateReport(
            for: session,
            sleepData: sleepData,
            sleepTrend: sleepTrend,
            recentSessions: recentSessions,
            healthKitHR: healthKitHR,
            vitals: vitals,
            compositeRecoveryScore: compositeRecoveryScore,
            scoreBreakdown: scoreBreakdown,
            baselineStats: baselineStats,
            liveLoadSnapshot: liveLoadSnapshot,
            style: style,
            sections: sections
        ) else { return nil }
        return writeReport(data, for: session)
    }

    /// Writes the rendered PDF to a timestamped temp file. Returns nil (and
    /// logs) rather than throwing, because every caller treats a failed export
    /// as "no share sheet" rather than an error to surface.
    func writeReport(_ data: Data, for session: HRVSession) -> URL? {
        // A machine stamp, the same in every locale and calendar.
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let reportDate = session.endDate ?? session.startDate
        let filename = "Emuqu_Recovery_\(dateFormatter.string(from: reportDate)).pdf"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: fileURL)
            return fileURL
        } catch {
            debugLog("[PDFReportGenerator] Failed to write PDF: \(error)")
            return nil
        }
    }
}
