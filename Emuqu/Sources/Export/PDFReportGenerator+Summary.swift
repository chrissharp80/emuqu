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
    /// with MorningResultsView's inputs (see `analysisSummary`), so the PDF says
    /// what the screen says
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
        let summary = analysisSummary(inputs)
        var pager = SummaryPager(pageNumber: pageNumber, context: context, pageRect: pageRect)
        defer { pageNumber = pager.pageNumber }
        var y = drawSummaryTitle(y: yPosition)
        y = drawSummaryDiagnosticCard(summary, y: y, contentWidth: contentWidth)
        y = drawSummaryProbableCauses(summary, y: y, contentWidth: contentWidth, pager: &pager)
        y = drawSummaryKeyFindings(summary, y: y, contentWidth: contentWidth, pager: &pager)
        y = drawSummaryActionableSteps(summary, y: y, contentWidth: contentWidth, pager: &pager)
        let disclaimer = summaryDisclaimerText()
        let disclaimerHeight = wrappedHeight(disclaimer, width: contentWidth)
        let disclaimerTop = pager.ensureSpace(disclaimerHeight + 25, y: y, generator: self)
        return drawSummaryDisclaimer(disclaimer, height: disclaimerHeight, y: disclaimerTop, contentWidth: contentWidth)
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

    /// Runs the same generator MorningResultsViewModel does with its inputs:
    /// the session's frozen load, today's live load snapshot when the caller
    /// captured one for today's session, and the canonical baseline. The
    /// report has no live readiness yet, so the readiness-driven
    /// post-workout steps are not reproduced.
    private func analysisSummary(_ inputs: ReportInputs) -> AnalysisSummaryGenerator.AnalysisSummary {
        let settings = settingsProvider()
        let generator = AnalysisSummaryGenerator(
            result: inputs.result,
            session: inputs.session,
            recentSessions: inputs.recentSessions,
            selectedTags: Set(inputs.session.tags),
            sleep: summarySleepInput(sleepData: inputs.sleepData),
            sleepTrend: summarySleepTrendInput(inputs.sleepTrend),
            trainingContext: inputs.frozenTrainingContext,
            userAge: settings.age,
            biologicalSex: settings.biologicalSex,
            liveLoadSnapshot: inputs.adviceLiveLoad,
            canonicalBaselineRMSSD: inputs.baselineStats.map { exp($0.lnRmssdMean) },
            canonicalBaselineHR: inputs.baselineStats.map(\.meanHRBaseline)
        )
        return generator.generate()
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
        String(localized: "What This Means", bundle: LanguageManager.appBundle).pdfDraw(at: CGPoint(x: config.margins.left, y: y), withAttributes: titleAttributes)
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
        explanation.pdfDraw(in: CGRect(x: config.margins.left + 20, y: y + 50, width: contentWidth - 40, height: explanationHeight))
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
        summary.analysisTitle.pdfDraw(at: CGPoint(x: config.margins.left + 20, y: y + 12), withAttributes: diagTitleAttr)

        // "Primary Assessment" subtitle
        let subtitleAttr: [NSAttributedString.Key: Any] = [
            .font: config.captionFont,
            .foregroundColor: UIColor.gray
        ]
        String(localized: "Primary Assessment", bundle: LanguageManager.appBundle).pdfDraw(at: CGPoint(x: config.margins.left + 20, y: y + 34), withAttributes: subtitleAttr)
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
        guard !summary.keyFindings.isEmpty else { return y }
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
        finding.pdfDraw(in: CGRect(x: config.margins.left + 20, y: y, width: contentWidth - 30, height: height))
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
        PDFReadingDirection.bullet.pdfDraw(at: CGPoint(x: config.margins.left + 6, y: y - 1), withAttributes: arrowAttr)
        step.pdfDraw(in: CGRect(x: config.margins.left + 22, y: y, width: contentWidth - 32, height: height))
    }

    /// The not-medical-advice note, wrapped at 8 pt.
    private func summaryDisclaimerText() -> NSAttributedString {
        let paragraphStyle = PDFReadingDirection.paragraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        let disclaimer = String(localized: "Note: This analysis is for informational purposes only and should not be used as a substitute for professional medical advice.", bundle: LanguageManager.appBundle)
        return NSAttributedString(string: disclaimer, attributes: [
            .font: UIFont.systemFont(ofSize: 8),
            .foregroundColor: UIColor.gray,
            .paragraphStyle: paragraphStyle
        ])
    }

    /// Draws the disclaimer 15 pt below `y` at its full wrapped height, so a
    /// longer translation is not cut.
    private func drawSummaryDisclaimer(_ disclaimer: NSAttributedString, height: CGFloat, y: CGFloat, contentWidth: CGFloat) -> CGFloat {
        let top = y + 15
        disclaimer.pdfDraw(in: CGRect(x: config.margins.left, y: top, width: contentWidth, height: height))
        return top + height + 10
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
        drawCauseRankAndTitle(rank: rank, cause: cause, confidence: confidence, y: y, contentWidth: contentWidth)
        explanation.pdfDraw(in: CGRect(x: config.margins.left + 10, y: y + 34, width: contentWidth - 20, height: explanationHeight))
        return y + cardHeight + 8
    }

    private func drawCauseRankAndTitle(rank: Int, cause: String, confidence: String, y: CGFloat, contentWidth: CGFloat) {
        // Rank number
        let rankAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 14, weight: .bold),
            .foregroundColor: config.primaryColor
        ]
        "\(rank).".pdfDraw(at: CGPoint(x: config.margins.left + 10, y: y + 8), withAttributes: rankAttr)
        drawCauseTitle(cause, y: y, contentWidth: contentWidth)

        // Confidence badge
        let confidenceAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8, weight: .medium),
            .foregroundColor: UIColor.gray
        ]
        confidence.pdfDraw(at: CGPoint(x: config.margins.left + 30, y: y + 22), withAttributes: confidenceAttr)
    }

    /// The cause title, held to the card's width (ending in an ellipsis if it
    /// would run past it) so a long or translated cause stays on the card.
    private func drawCauseTitle(_ cause: String, y: CGFloat, contentWidth: CGFloat) {
        let titleStyle = PDFReadingDirection.paragraphStyle()
        titleStyle.lineBreakMode = .byTruncatingTail
        let causeAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: UIColor.black,
            .paragraphStyle: titleStyle
        ]
        cause.pdfDraw(in: CGRect(x: config.margins.left + 30, y: y + 6, width: contentWidth - 40, height: 16), withAttributes: causeAttr)
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

/// The report's trend is already the generator's input type; a trend over no
/// nights is passed as none.
private func summarySleepTrendInput(_ sleepTrend: PDFReportGenerator.SleepTrendData?) -> AnalysisSleepTrendInput? {
    guard let sleepTrend, sleepTrend.nightsAnalyzed > 0 else { return nil }
    return sleepTrend
}
