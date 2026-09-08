import Foundation
import PDFKit
import UIKit

// Overnight pages live in `OvernightReportRenderer`, cut out of
// PDFReportGenerator.
//
// These forwarders keep every existing call site working.

extension PDFReportGenerator {
    /// The overnight page renderer. Lazy — a daytime reading never draws these
    /// pages and never builds it.
    var overnight: OvernightReportRenderer {
        OvernightReportRenderer(generator: self)
    }

    func drawOvernightHRChart(
        series: RRSeries,
        result: HRVAnalysisResult,
        yPosition: CGFloat,
        in context: UIGraphicsPDFRendererContext,
        pageRect: CGRect
    ) -> CGFloat {
        overnight.drawOvernightHRChart(
            series: series, result: result, yPosition: yPosition,
            in: context, pageRect: pageRect
        )
    }

    func drawOvernightStatsSection(
        _ inputs: ReportInputs,
        series: RRSeries,
        yPosition: CGFloat,
        pageRect: CGRect
    ) -> CGFloat {
        overnight.drawOvernightStatsSection(
            inputs, series: series, yPosition: yPosition, pageRect: pageRect
        )
    }

    func drawTagsAndNotesSection(
        session: HRVSession,
        yPosition: CGFloat,
        in context: UIGraphicsPDFRendererContext,
        pageRect: CGRect
    ) -> CGFloat {
        overnight.drawTagsAndNotesSection(
            session: session, yPosition: yPosition, in: context, pageRect: pageRect
        )
    }

    func diagnosticColorForScore(_ score: Double) -> UIColor {
        overnight.diagnosticColorForScore(score)
    }

    func computeSleepInputFromSession(_ session: HRVSession) -> AnalysisSleepInput {
        overnight.computeSleepInputFromSession(session)
    }
}
