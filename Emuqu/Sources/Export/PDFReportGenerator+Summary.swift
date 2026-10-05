//
//  PDFReportGenerator+Summary.swift
//  Emuqu
//
//  The "What This Means" section — the same AnalysisSummaryGenerator output
//  MorningResultsView shows, laid out for print.
//

import Foundation
import UIKit

extension PDFReportGenerator {
    // MARK: - Analysis Summary Section (Uses Shared Generator)

    /// Draws the analysis summary section using the shared AnalysisSummaryGenerator
    /// This ensures the PDF contains 100% of the same content as MorningResultsView
    ///
    /// Every block is measured before it is drawn and moves to a new page
    /// when it does not fit, so long or translated text neither overlaps the
    /// next line nor runs off the page.
    func drawAnalysisSummarySection(
        _ inputs: ReportInputs,
        yPosition: CGFloat,
        pageNumber: inout Int,
        in context: UIGraphicsPDFRendererContext,
        pageRect: CGRect
    ) -> CGFloat {
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        let summary = analysisSummary(
            result: inputs.result, session: inputs.session,
            sleepData: inputs.sleepData, sleepTrend: inputs.sleepTrend, recentSessions: inputs.recentSessions,
            trainingContext: inputs.trainingContext, baselineStats: inputs.baselineStats
        )
        var pager = SummaryPager(pageNumber: pageNumber, context: context, pageRect: pageRect)
        defer { pageNumber = pager.pageNumber }
        var y = drawSummaryTitle(y: yPosition)
        y = drawSummaryDiagnosticCard(summary, y: y, contentWidth: contentWidth)
        y = drawSummaryProbableCauses(summary, y: y, contentWidth: contentWidth, pager: &pager)
        y = drawSummaryKeyFindings(summary, y: y, contentWidth: contentWidth, pager: &pager)
        y = drawSummaryActionableSteps(summary, y: y, contentWidth: contentWidth, pager: &pager)
        return drawSummaryDisclaimer(y: pager.ensureSpace(40, y: y, generator: self), contentWidth: contentWidth)
    }

    /// The page state the summary's blocks share while they paginate.
    struct SummaryPager {
        var pageNumber: Int
        let context: UIGraphicsPDFRendererContext
        let pageRect: CGRect

        mutating func ensureSpace(_ needed: CGFloat, y: CGFloat, generator: PDFReportGenerator) -> CGFloat {
            generator.ensureSpace(needed: needed, y: y, pageNumber: &pageNumber, context: context, pageRect: pageRect)
        }
    }

    /// Height a wrapped string needs at `width`.
    private func wrappedHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        ceil(text.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
        ).height)
    }

    /// Runs the same generator MorningResultsView does, with the report's
    /// training context, so the two describe the same night the same way.
    /// There is no live-load snapshot here, so the cumulative-load gate reads
    /// the training context alone.
    private func analysisSummary(
        result: HRVAnalysisResult,
        session: HRVSession,
        sleepData: SleepData?,
        sleepTrend: SleepTrendData?,
        recentSessions: [HRVSession],
        trainingContext: TrainingContext?,
        baselineStats: BaselineTracker.RecoveryBaselineStats?
    ) -> AnalysisSummaryGenerator.AnalysisSummary {
        let sleepInput = summarySleepInput(sleepData: sleepData)
        let sleepTrendInput = summarySleepTrendInput(sleepTrend)
        // Use the shared generator - same code that powers MorningResultsView
        let settings = settingsProvider()
        let generator = AnalysisSummaryGenerator(
            result: result,
            session: session,
            recentSessions: recentSessions,
            selectedTags: Set(session.tags),
            sleep: sleepInput,
            sleepTrend: sleepTrendInput,
            trainingContext: trainingContext,
            userAge: settings.age,
            biologicalSex: settings.biologicalSex,
            canonicalBaselineRMSSD: baselineStats.map { exp($0.lnRmssdMean) },
            canonicalBaselineHR: baselineStats.map(\.meanHRBaseline)
        )
        let summary = generator.generate()
        return summary
    }

    private func summarySleepInput(sleepData: SleepData?) -> AnalysisSleepInput {
        // Convert sleep data to SleepInput for the generator
        let sleepInput: AnalysisSleepInput = if let sd = sleepData, sd.totalSleepMinutes > 0 {
            AnalysisSleepInput(
                totalSleepMinutes: sd.totalSleepMinutes,
                inBedMinutes: sd.inBedMinutes,
                deepSleepMinutes: sd.deepSleepMinutes,
                remSleepMinutes: sd.remSleepMinutes,
                awakeMinutes: sd.awakeMinutes,
                sleepEfficiency: sd.sleepEfficiency
            )
        } else {
            // No sleep record for the night: the report says so rather than
            // guessing sleep from how long the strap recorded.
            .empty
        }
        return sleepInput
    }

    private func drawSummaryTitle(y: CGFloat) -> CGFloat {
        var y = y
        // Title with icon
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: config.titleFont,
            .foregroundColor: UIColor.black
        ]
        String(localized: "What This Means", bundle: LanguageManager.appBundle).draw(at: CGPoint(x: config.margins.left, y: y), withAttributes: titleAttributes)
        y += 35
        return y
    }

    /// The headline verdict card: accent bar, title, and the explanation blurb.
    /// The card grows with its explanation rather than clipping it.
    private func drawSummaryDiagnosticCard(_ summary: AnalysisSummaryGenerator.AnalysisSummary, y: CGFloat, contentWidth: CGFloat) -> CGFloat {
        let explanation = summaryExplanationText(summary)
        let explanationHeight = max(55, wrappedHeight(explanation, width: contentWidth - 40))
        let cardHeight = 50 + explanationHeight + 5
        let color = diagnosticColorForScore(summary.headlineScore)
        drawSummaryCardFrame(color: color, y: y, contentWidth: contentWidth, cardHeight: cardHeight)
        drawSummaryCardCopy(summary, color: color, y: y, contentWidth: contentWidth)
        explanation.draw(in: CGRect(x: config.margins.left + 20, y: y + 50, width: contentWidth - 40, height: explanationHeight))
        return y + cardHeight + 20
    }

    private func drawSummaryCardFrame(color: UIColor, y: CGFloat, contentWidth: CGFloat, cardHeight: CGFloat) {
        // Diagnostic color based on score

        // Draw diagnostic card
        let cardRect = CGRect(x: config.margins.left, y: y, width: contentWidth, height: cardHeight)
        color.withAlphaComponent(0.08).setFill()
        UIBezierPath(roundedRect: cardRect, cornerRadius: 12).fill()

        // Left side: colored accent bar
        let accentRect = CGRect(x: config.margins.left, y: y, width: 6, height: cardHeight)
        color.setFill()
        UIBezierPath(roundedRect: accentRect, byRoundingCorners: [.topLeft, .bottomLeft], cornerRadii: CGSize(width: 12, height: 12)).fill()
    }

    private func drawSummaryCardCopy(_ summary: AnalysisSummaryGenerator.AnalysisSummary, color: UIColor, y: CGFloat, contentWidth: CGFloat) {
        // Title in card
        let diagTitleAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 18, weight: .bold),
            .foregroundColor: color
        ]
        summary.analysisTitle.draw(at: CGPoint(x: config.margins.left + 20, y: y + 12), withAttributes: diagTitleAttr)

        // "Primary Assessment" subtitle
        let subtitleAttr: [NSAttributedString.Key: Any] = [
            .font: config.captionFont,
            .foregroundColor: UIColor.gray
        ]
        String(localized: "Primary Assessment", bundle: LanguageManager.appBundle).draw(at: CGPoint(x: config.margins.left + 20, y: y + 34), withAttributes: subtitleAttr)
    }

    private func summaryExplanationText(_ summary: AnalysisSummaryGenerator.AnalysisSummary) -> NSAttributedString {
        NSAttributedString(string: summary.analysisExplanation, attributes: wrappedSummaryAttributes(size: 11))
    }

    private func wrappedSummaryAttributes(size: CGFloat) -> [NSAttributedString.Key: Any] {
        let paragraphStyle = PDFReadingDirection.paragraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        return [
            .font: UIFont.systemFont(ofSize: size),
            .foregroundColor: UIColor.darkGray,
            .paragraphStyle: paragraphStyle
        ]
    }

    private func drawSummaryProbableCauses(
        _ summary: AnalysisSummaryGenerator.AnalysisSummary, y: CGFloat, contentWidth: CGFloat, pager: inout SummaryPager
    ) -> CGFloat {
        guard !summary.probableCauses.isEmpty else { return y }
        var y = pager.ensureSpace(90, y: y, generator: self)
        y = drawSectionHeading(String(localized: "Possible Explanations", bundle: LanguageManager.appBundle), yPosition: y, pageRect: pager.pageRect)
        for (index, cause) in summary.probableCauses.enumerated() {
            let explanation = NSAttributedString(string: cause.explanation, attributes: wrappedSummaryAttributes(size: 8))
            let explanationHeight = wrappedHeight(explanation, width: contentWidth - 20)
            y = pager.ensureSpace(Self.causeCardHeight(explanationHeight: explanationHeight) + 8, y: y, generator: self)
            y = drawProbableCauseRow(
                rank: index + 1, cause: cause.cause, confidence: cause.confidenceLabel,
                explanation: explanation, explanationHeight: explanationHeight,
                yPosition: y, contentWidth: contentWidth
            )
        }
        return y + 10
    }

    private func drawSummaryKeyFindings(
        _ summary: AnalysisSummaryGenerator.AnalysisSummary, y: CGFloat, contentWidth: CGFloat, pager: inout SummaryPager
    ) -> CGFloat {
        var y = pager.ensureSpace(60, y: y, generator: self)
        y = drawSectionHeading(String(localized: "Key Findings", bundle: LanguageManager.appBundle), yPosition: y, pageRect: pager.pageRect)
        for finding in summary.keyFindings {
            let text = NSAttributedString(string: finding, attributes: wrappedSummaryAttributes(size: 10))
            let height = max(14, wrappedHeight(text, width: contentWidth - 30))
            y = pager.ensureSpace(height + 4, y: y, generator: self)
            drawSummaryFindingRow(text, y: y, height: height, contentWidth: contentWidth)
            y += height + 4
        }
        return y + 15
    }

    private func drawSummaryFindingRow(_ finding: NSAttributedString, y: CGFloat, height: CGFloat, contentWidth: CGFloat) {
        config.primaryColor.setFill()
        let bulletDot = CGRect(x: config.margins.left + 8, y: y + 5, width: 4, height: 4)
        UIBezierPath(ovalIn: bulletDot).fill()
        finding.draw(in: CGRect(x: config.margins.left + 20, y: y, width: contentWidth - 30, height: height))
    }

    private func drawSummaryActionableSteps(
        _ summary: AnalysisSummaryGenerator.AnalysisSummary, y: CGFloat, contentWidth: CGFloat, pager: inout SummaryPager
    ) -> CGFloat {
        var y = pager.ensureSpace(60, y: y, generator: self)
        y = drawSectionHeading(String(localized: "What To Do", bundle: LanguageManager.appBundle), yPosition: y, pageRect: pager.pageRect)
        for step in summary.actionableSteps {
            let text = NSAttributedString(string: step, attributes: wrappedSummaryAttributes(size: 10))
            let height = max(16, wrappedHeight(text, width: contentWidth - 32))
            y = pager.ensureSpace(height + 4, y: y, generator: self)
            drawSummaryStepRow(text, y: y, height: height, contentWidth: contentWidth)
            y += height + 4
        }
        return y
    }

    private func drawSummaryStepRow(_ step: NSAttributedString, y: CGFloat, height: CGFloat, contentWidth: CGFloat) {
        let arrowAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: config.secondaryColor
        ]
        let arrowX = PDFReadingDirection.startX(minX: config.margins.left + 6, width: contentWidth - 12, itemWidth: 12)
        PDFReadingDirection.bullet.draw(at: CGPoint(x: arrowX, y: y - 1), withAttributes: arrowAttr)
        let textX = config.margins.left + (PDFReadingDirection.isRightToLeft ? 10 : 22)
        step.draw(in: CGRect(x: textX, y: y, width: contentWidth - 32, height: height))
    }

    private func drawSummaryDisclaimer(y: CGFloat, contentWidth: CGFloat) -> CGFloat {
        var y = y
        // Disclaimer at bottom
        y += 15
        let disclaimerAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8),
            .foregroundColor: UIColor.gray
        ]
        let disclaimer = String(localized: "Note: This analysis is for informational purposes only and should not be used as a substitute for professional medical advice.", bundle: LanguageManager.appBundle)
        let disclaimerRect = CGRect(x: config.margins.left, y: y, width: contentWidth, height: 20)
        disclaimer.draw(in: disclaimerRect, withAttributes: disclaimerAttr)
        return y + 25
    }

    /// The card grows with its explanation: the title and confidence take the
    /// top 34 pt, the wrapped explanation follows.
    static func causeCardHeight(explanationHeight: CGFloat) -> CGFloat {
        max(50, 34 + explanationHeight + 8)
    }

    /// Draw a probable cause row (matches MorningResultsView's ProbableCauseRow)
    func drawProbableCauseRow(
        rank: Int,
        cause: String,
        confidence: String,
        explanation: NSAttributedString,
        explanationHeight: CGFloat,
        yPosition: CGFloat,
        contentWidth: CGFloat
    ) -> CGFloat {
        let y = yPosition
        let cardHeight = Self.causeCardHeight(explanationHeight: explanationHeight)
        UIColor(white: 0.97, alpha: 1.0).setFill()
        UIBezierPath(roundedRect: CGRect(x: config.margins.left, y: y, width: contentWidth, height: cardHeight), cornerRadius: 8).fill()
        drawCauseRankAndTitle(rank: rank, cause: cause, confidence: confidence, y: y)
        explanation.draw(in: CGRect(x: config.margins.left + 10, y: y + 34, width: contentWidth - 20, height: explanationHeight))
        return y + cardHeight + 8
    }

    private func drawCauseRankAndTitle(rank: Int, cause: String, confidence: String, y: CGFloat) {
        // Rank number
        let rankAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 14, weight: .bold),
            .foregroundColor: config.primaryColor
        ]
        "\(rank).".draw(at: CGPoint(x: config.margins.left + 10, y: y + 8), withAttributes: rankAttr)
        // Cause title
        let causeAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: UIColor.black
        ]
        cause.draw(at: CGPoint(x: config.margins.left + 30, y: y + 6), withAttributes: causeAttr)

        // Confidence badge
        let confidenceAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8, weight: .medium),
            .foregroundColor: UIColor.gray
        ]
        confidence.draw(at: CGPoint(x: config.margins.left + 30, y: y + 22), withAttributes: confidenceAttr)
    }

}

// MARK: - File-scope helpers
//
// Kept outside the type. Each touches no instance state —
// including the computed properties — and
// calls nothing inside it, so none is a method in anything but
// placement. `private` at file scope is fileprivate, so every call site in
// this file resolves the same way.
//
// This is what `check_aggregate_type_size.sh` measures: a type is the sum of
// its parts across every file, so code that does not need the type inflates
// that number without making the type do more.

private func summarySleepTrendInput(_ sleepTrend: PDFReportGenerator.SleepTrendData?) -> AnalysisSleepTrendInput? {
    // Convert sleep trend to SleepTrendInput
    let sleepTrendInput: AnalysisSleepTrendInput? = if let st = sleepTrend, st.nightsAnalyzed > 0 {
        AnalysisSleepTrendInput(
            averageSleepMinutes: st.averageSleepMinutes,
            averageDeepSleepMinutes: st.averageDeepSleepMinutes,
            averageEfficiency: st.averageEfficiency,
            trend: st.trend,
            nightsAnalyzed: st.nightsAnalyzed
        )
    } else {
        nil
    }
    return sleepTrendInput
}
