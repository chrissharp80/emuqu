import Foundation
import PDFKit
import UIKit

// Report body sections and their charts live in `ReportSectionRenderer` —
// the largest cut out of PDFReportGenerator, after the deep-dive and
// overnight pages.
//
// These forwarders keep every existing call site working, including the other
// two renderers: `DeepDiveReportRenderer` reaches `ensureSpace` and
// `OvernightReportRenderer` reaches `drawCompactStatBox` through the generator,
// and both of those primitives moved with the sections that own them.

extension PDFReportGenerator {
    /// The body-section renderer. Every report draws body sections, so this is
    /// built on the first page rather than lazily deferred any further.
    var sections: ReportSectionRenderer {
        ReportSectionRenderer(generator: self)
    }

    func drawANSSection(_ ans: ANSMetrics, yPosition: CGFloat, in context: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        return sections.drawANSSection(ans, yPosition: yPosition, in: context, pageRect: pageRect)
    }

    func drawCompactStatBox(title: String, value: String, color: UIColor, rect: CGRect) {
        sections.drawCompactStatBox(title: title, value: value, color: color, rect: rect)
    }

    func drawFooter(pageNumber: Int, in arg1: UIGraphicsPDFRendererContext, pageRect: CGRect) {
        sections.drawFooter(pageNumber: pageNumber, in: arg1, pageRect: pageRect)
    }

    func drawFrequencyDomainSection(_ fd: FrequencyDomainMetrics, yPosition: CGFloat, in context: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        return sections.drawFrequencyDomainSection(fd, yPosition: yPosition, in: context, pageRect: pageRect)
    }

    func drawHeader(session: HRVSession, result arg1: HRVAnalysisResult, in context: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        return sections.drawHeader(session: session, result: arg1, in: context, pageRect: pageRect)
    }

    func drawNonlinearSection(_ nl: NonlinearMetrics, yPosition: CGFloat, in context: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        return sections.drawNonlinearSection(nl, yPosition: yPosition, in: context, pageRect: pageRect)
    }

    func drawPSDGraph(
        series: RRSeries, flags: [ArtifactFlags], fd: FrequencyDomainMetrics, window: Range<Int>?,
        yPosition: CGFloat, in arg4: UIGraphicsPDFRendererContext, pageRect: CGRect
    ) -> CGFloat {
        return sections.drawPSDGraph(series: series, flags: flags, fd: fd, window: window, yPosition: yPosition, in: arg4, pageRect: pageRect)
    }

    func drawPoincarePlot(
        series: RRSeries, flags: [ArtifactFlags], result: HRVAnalysisResult, yPosition: CGFloat, in context: UIGraphicsPDFRendererContext, pageRect: CGRect
    ) -> CGFloat {
        return sections.drawPoincarePlot(series: series, flags: flags, result: result, yPosition: yPosition, in: context, pageRect: pageRect)
    }

    func drawQualitySection(_ result: HRVAnalysisResult, session: HRVSession, yPosition: CGFloat, in context: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        return sections.drawQualitySection(result, session: session, yPosition: yPosition, in: context, pageRect: pageRect)
    }

    func drawScoreBreakdownSection(breakdown: RecoveryScoreCalculator.ScoreBreakdown, yPosition: CGFloat, in context: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        return sections.drawScoreBreakdownSection(breakdown: breakdown, yPosition: yPosition, in: context, pageRect: pageRect)
    }

    func drawSummaryCard(result: HRVAnalysisResult, ans: ANSMetrics?, compositeScore: Double? = nil, yPosition: CGFloat, in context: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        return sections.drawSummaryCard(result: result, ans: ans, compositeScore: compositeScore, yPosition: yPosition, in: context, pageRect: pageRect)
    }

    func drawTachogram(
        series: RRSeries, flags: [ArtifactFlags], result: HRVAnalysisResult, yPosition: CGFloat, in arg4: UIGraphicsPDFRendererContext, pageRect: CGRect
    ) -> CGFloat {
        return sections.drawTachogram(series: series, flags: flags, result: result, yPosition: yPosition, in: arg4, pageRect: pageRect)
    }

    func drawTimeDomainSection(_ td: TimeDomainMetrics, yPosition: CGFloat, in context: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        return sections.drawTimeDomainSection(td, yPosition: yPosition, in: context, pageRect: pageRect)
    }

    func drawWindowSelectionSection(result: HRVAnalysisResult, yPosition: CGFloat, in context: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        return sections.drawWindowSelectionSection(result: result, yPosition: yPosition, in: context, pageRect: pageRect)
    }

    func ensureSpace(needed: CGFloat, y: CGFloat, pageNumber: inout Int, context: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        return sections.ensureSpace(needed: needed, y: y, pageNumber: &pageNumber, context: context, pageRect: pageRect)
    }

    func readinessColor(_ score: Double) -> UIColor {
        return sections.readinessColor(score)
    }
}
