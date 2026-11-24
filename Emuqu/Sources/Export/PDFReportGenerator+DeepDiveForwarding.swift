import Foundation
import PDFKit
import UIKit

// Deep-dive pages live in `DeepDiveReportRenderer`, which needs exactly two
// members of the generator: the report config and the page-break helper.
// These forwarders give `PDFReportGenerator` callers the same entry points.

extension PDFReportGenerator {
    /// The deep-dive page renderer: a stateless value wrapping `self`, built
    /// afresh on every forwarder call (not cached). Only the deep-dive
    /// forwarders reach it, so a `.summary` report never builds one.
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
}
