//
//  PDFReportGenerator+Summary.swift
//  Emuqu
//
//  The "What This Means" section — the same AnalysisSummaryGenerator output
//  MorningResultsView shows, laid out for print. Split out of
//  PDFReportGenerator+Overnight to keep that file under 1000 lines.
//

import Foundation
import UIKit

extension PDFReportGenerator {
    // MARK: - Analysis Summary Section (Uses Shared Generator)

    /// Draws the analysis summary section using the shared AnalysisSummaryGenerator
    /// This ensures the PDF contains 100% of the same content as MorningResultsView
    func drawAnalysisSummarySection(
        _ inputs: ReportInputs,
        yPosition: CGFloat,
        pageRect: CGRect
    ) -> CGFloat {
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        let summary = analysisSummary(
            result: inputs.result, session: inputs.session,
            sleepData: inputs.sleepData, sleepTrend: inputs.sleepTrend, recentSessions: inputs.recentSessions
        )
        var y = drawSummaryTitle(y: yPosition)
        y = drawSummaryDiagnosticCard(summary, y: y, contentWidth: contentWidth)
        y = drawSummaryProbableCauses(summary, y: y, contentWidth: contentWidth, pageRect: pageRect)
        y = drawSummaryKeyFindings(summary, y: y, contentWidth: contentWidth, pageRect: pageRect)
        y = drawSummaryActionableSteps(summary, y: y, contentWidth: contentWidth, pageRect: pageRect)
        return drawSummaryDisclaimer(y: y, contentWidth: contentWidth)
    }

    /// Runs the same generator MorningResultsView does, so the two can never
    /// describe the same night differently.
    private func analysisSummary(
        result: HRVAnalysisResult,
        session: HRVSession,
        sleepData: SleepData?,
        sleepTrend: SleepTrendData?,
        recentSessions: [HRVSession]
    ) -> AnalysisSummaryGenerator.AnalysisSummary {
        let sleepInput = summarySleepInput(sleepData: sleepData, session: session)
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
            userAge: settings.age,
            biologicalSex: settings.biologicalSex
        )
        let summary = generator.generate()
        return summary
    }

    private func summarySleepInput(sleepData: SleepData?, session: HRVSession) -> AnalysisSleepInput {
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
            // Fall back to estimation from session data
            computeSleepInputFromSession(session)
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
    private func drawSummaryDiagnosticCard(_ summary: AnalysisSummaryGenerator.AnalysisSummary, y: CGFloat, contentWidth: CGFloat) -> CGFloat {
        let cardHeight: CGFloat = 110
        let color = diagnosticColorForScore(summary.diagnosticScore)
        drawSummaryCardFrame(color: color, y: y, contentWidth: contentWidth, cardHeight: cardHeight)
        drawSummaryCardCopy(summary, color: color, y: y, contentWidth: contentWidth)
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
        drawSummaryCardExplanation(summary, y: y, contentWidth: contentWidth)
    }

    private func drawSummaryCardExplanation(_ summary: AnalysisSummaryGenerator.AnalysisSummary, y: CGFloat, contentWidth: CGFloat) {
        // Explanation
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping

        let attributedExplanation = NSAttributedString(string: summary.analysisExplanation, attributes: [
            .font: UIFont.systemFont(ofSize: 11),
            .foregroundColor: UIColor.darkGray,
            .paragraphStyle: paragraphStyle
        ])
        let explainRect = CGRect(x: config.margins.left + 20, y: y + 50, width: contentWidth - 40, height: 55)
        attributedExplanation.draw(in: explainRect)
    }

    private func drawSummaryProbableCauses(_ summary: AnalysisSummaryGenerator.AnalysisSummary, y: CGFloat, contentWidth: CGFloat, pageRect: CGRect) -> CGFloat {
        var y = y
        // === MOST LIKELY EXPLANATIONS (Probable Causes) ===
        if !summary.probableCauses.isEmpty {
            y = drawSectionHeading(String(localized: "Most Likely Explanations", bundle: LanguageManager.appBundle), yPosition: y, pageRect: pageRect)

            for (index, cause) in summary.probableCauses.enumerated() {
                y = drawProbableCauseRow(
                    rank: index + 1,
                    cause: cause.cause,
                    confidence: cause.confidence,
                    explanation: cause.explanation,
                    yPosition: y,
                    contentWidth: contentWidth,
                    pageRect: pageRect
                )
            }
            y += 10
        }
        return y
    }

    private func drawSummaryKeyFindings(_ summary: AnalysisSummaryGenerator.AnalysisSummary, y: CGFloat, contentWidth: CGFloat, pageRect: CGRect) -> CGFloat {
        var y = drawSectionHeading(String(localized: "Key Findings", bundle: LanguageManager.appBundle), yPosition: y, pageRect: pageRect)
        for finding in summary.keyFindings {
            drawSummaryFindingRow(finding, y: y, contentWidth: contentWidth)
            y += 18
        }
        return y + 15
    }

    private func drawSummaryFindingRow(_ finding: String, y: CGFloat, contentWidth: CGFloat) {
        // Draw bullet point
        config.primaryColor.setFill()
        let bulletDot = CGRect(x: config.margins.left + 8, y: y + 5, width: 4, height: 4)
        UIBezierPath(ovalIn: bulletDot).fill()

        // Draw finding text with word wrap
        let findingParagraphStyle = NSMutableParagraphStyle()
        findingParagraphStyle.lineBreakMode = .byWordWrapping

        let attributedFinding = NSAttributedString(string: finding, attributes: [
            .font: UIFont.systemFont(ofSize: 10),
            .foregroundColor: UIColor.darkGray,
            .paragraphStyle: findingParagraphStyle
        ])

        let findingRect = CGRect(x: config.margins.left + 20, y: y, width: contentWidth - 30, height: 32)
        attributedFinding.draw(in: findingRect)
    }

    private func drawSummaryActionableSteps(_ summary: AnalysisSummaryGenerator.AnalysisSummary, y: CGFloat, contentWidth: CGFloat, pageRect: CGRect) -> CGFloat {
        var y = drawSectionHeading(String(localized: "What To Do", bundle: LanguageManager.appBundle), yPosition: y, pageRect: pageRect)
        for step in summary.actionableSteps {
            drawSummaryStepRow(step, y: y, contentWidth: contentWidth)
            y += 20
        }
        return y
    }

    private func drawSummaryStepRow(_ step: String, y: CGFloat, contentWidth: CGFloat) {
        // Draw arrow
        let arrowAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: config.secondaryColor
        ]
        "→".draw(at: CGPoint(x: config.margins.left + 6, y: y - 1), withAttributes: arrowAttr)

        // Draw recommendation text with word wrap
        let recParagraphStyle = NSMutableParagraphStyle()
        recParagraphStyle.lineBreakMode = .byWordWrapping

        let attributedRec = NSAttributedString(string: step, attributes: [
            .font: UIFont.systemFont(ofSize: 10),
            .foregroundColor: UIColor.darkGray,
            .paragraphStyle: recParagraphStyle
        ])

        let recRect = CGRect(x: config.margins.left + 22, y: y, width: contentWidth - 32, height: 32)
        attributedRec.draw(in: recRect)
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

    /// Draw a probable cause row (matches MorningResultsView's ProbableCauseRow)
    func drawProbableCauseRow(
        rank: Int,
        cause: String,
        confidence: String,
        explanation: String,
        yPosition: CGFloat,
        contentWidth: CGFloat,
        pageRect _: CGRect
    ) -> CGFloat {
        let y = yPosition
        let cardHeight: CGFloat = 50
        UIColor(white: 0.97, alpha: 1.0).setFill()
        UIBezierPath(roundedRect: CGRect(x: config.margins.left, y: y, width: contentWidth, height: cardHeight), cornerRadius: 8).fill()
        drawCauseRankAndTitle(rank: rank, cause: cause, confidence: confidence, y: y)
        drawCauseExplanation(explanation, y: y, contentWidth: contentWidth)
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

    private func drawCauseExplanation(_ explanation: String, y: CGFloat, contentWidth: CGFloat) {
        // Explanation (truncated if needed)
        let explainAttr: [NSAttributedString.Key: Any] = [
            .font: config.captionFont,
            .foregroundColor: UIColor.darkGray
        ]
        let truncatedExplanation = explanation.count > 120 ? String(explanation.prefix(117)) + "..." : explanation
        let explainRect = CGRect(x: config.margins.left + 10, y: y + 34, width: contentWidth - 20, height: 14)
        truncatedExplanation.draw(in: explainRect, withAttributes: explainAttr)
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
