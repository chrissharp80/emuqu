import Foundation
import PDFKit
import UIKit

// Deep-dive pages live in `DeepDiveReportRenderer` — well over a thousand
// lines kept out of PDFReportGenerator, one of the largest types in the
// codebase.
//
// This seam and not another because the deep-dive pages needed exactly two
// members of the generator: the report config and the page-break helper. The
// forwarders below keep every existing call site working.

extension PDFReportGenerator {
    /// The deep-dive page renderer. Lazy — a `.summary` report never draws
    /// these pages and never builds it.
    var deepDive: DeepDiveReportRenderer {
        DeepDiveReportRenderer(generator: self)
    }

    func drawDeepHRVAnalysis(
        result: HRVAnalysisResult,
        session: HRVSession,
        recentSessions: [HRVSession],
        pageNumber: inout Int,
        yPosition: CGFloat,
        in context: UIGraphicsPDFRendererContext,
        pageRect: CGRect
    ) -> CGFloat {
        deepDive.drawDeepHRVAnalysis(
            result: result, session: session, recentSessions: recentSessions,
            pageNumber: &pageNumber, yPosition: yPosition,
            in: context, pageRect: pageRect
        )
    }

    func drawDeepSleepAnalysis(
        sleep: SleepData,
        sleepTrend: SleepTrendData?,
        pageNumber: inout Int,
        yPosition: CGFloat,
        in context: UIGraphicsPDFRendererContext,
        pageRect: CGRect
    ) -> CGFloat {
        deepDive.drawDeepSleepAnalysis(
            sleep: sleep, sleepTrend: sleepTrend,
            pageNumber: &pageNumber, yPosition: yPosition,
            in: context, pageRect: pageRect
        )
    }

    func drawDeepTrainingAnalysis(
        training: TrainingContext,
        pageNumber: inout Int,
        yPosition: CGFloat,
        in context: UIGraphicsPDFRendererContext,
        pageRect: CGRect
    ) -> CGFloat {
        deepDive.drawDeepTrainingAnalysis(
            training: training,
            pageNumber: &pageNumber, yPosition: yPosition,
            in: context, pageRect: pageRect
        )
    }

    func drawDeepVitalsAnalysis(
        vitals: VitalsData,
        pageNumber: inout Int,
        yPosition: CGFloat,
        in context: UIGraphicsPDFRendererContext,
        pageRect: CGRect
    ) -> CGFloat {
        deepDive.drawDeepVitalsAnalysis(
            vitals: vitals,
            pageNumber: &pageNumber, yPosition: yPosition,
            in: context, pageRect: pageRect
        )
    }

    func drawWrappedText(
        _ text: String,
        style: DeepDiveReportRenderer.TextStyle,
        y: CGFloat,
        contentWidth: CGFloat,
        pageNumber: inout Int,
        context: UIGraphicsPDFRendererContext,
        pageRect: CGRect
    ) -> CGFloat {
        deepDive.drawWrappedText(
            text, style: style, y: y, contentWidth: contentWidth,
            pageNumber: &pageNumber, context: context, pageRect: pageRect
        )
    }
}
