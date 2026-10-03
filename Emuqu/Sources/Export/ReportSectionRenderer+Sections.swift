import Foundation
import UIKit

// Header, summary, metric sections, auto-pagination and the score breakdown.

extension ReportSectionRenderer {
    // MARK: - Header & Summary

    func drawHeader(session: HRVSession, result _: HRVAnalysisResult, in _: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        var yPosition = config.margins.top
        yPosition = drawHeaderBrand(yPosition: yPosition, contentWidth: contentWidth)
        yPosition = drawHeaderSessionInfo(session: session, yPosition: yPosition, contentWidth: contentWidth)
        return drawHeaderDemographics(yPosition: yPosition, contentWidth: contentWidth)
    }

    private func drawHeaderBrand(yPosition: CGFloat, contentWidth: CGFloat) -> CGFloat {
        // App brand with accent bar
        let accentRect = CGRect(x: config.margins.left, y: yPosition, width: 4, height: 44)
        config.primaryColor.setFill()
        UIBezierPath(roundedRect: accentRect, cornerRadius: 2).fill()

        let brandName = "Emuqu"
        let brandAttributes: [NSAttributedString.Key: Any] = [
            .font: config.titleFont,
            .foregroundColor: UIColor.black
        ]
        let brandRect = CGRect(x: config.margins.left + 12, y: yPosition, width: contentWidth - 12, height: 26)
        brandName.draw(in: brandRect, withAttributes: brandAttributes)
        return drawHeaderSubtitle(yPosition: yPosition, contentWidth: contentWidth)
    }

    private func drawHeaderSubtitle(yPosition: CGFloat, contentWidth: CGFloat) -> CGFloat {
        var yPosition = yPosition
        let subtitle = String(localized: "Recovery Report", bundle: LanguageManager.appBundle)
        let subtitleAttributes: [NSAttributedString.Key: Any] = [
            .font: config.subheadingFont,
            .foregroundColor: UIColor.darkGray
        ]
        let subtitleRect = CGRect(x: config.margins.left + 12, y: yPosition + 26, width: contentWidth - 12, height: 16)
        subtitle.draw(in: subtitleRect, withAttributes: subtitleAttributes)
        yPosition += 50
        return yPosition
    }

    private func drawHeaderSessionInfo(session: HRVSession, yPosition: CGFloat, contentWidth: CGFloat) -> CGFloat {
        var yPosition = yPosition
        let infoText = headerSessionInfoText(session: session)
        let infoAttributes: [NSAttributedString.Key: Any] = [
            .font: config.bodyFont,
            .foregroundColor: UIColor.darkGray
        ]
        let infoRect = CGRect(x: config.margins.left, y: yPosition, width: contentWidth, height: 16)
        infoText.draw(in: infoRect, withAttributes: infoAttributes)
        yPosition += 18
        return yPosition
    }

    /// Age and sex, when the user has set them — the reference ranges elsewhere
    /// in the report are age- and sex-specific, so the reader needs to see which.
    private func drawHeaderDemographics(yPosition: CGFloat, contentWidth: CGFloat) -> CGFloat {
        var yPosition = yPosition
        let demographicParts = headerDemographicParts()
        if !demographicParts.isEmpty {
            let demographicText = demographicParts.joined(separator: "  •  ")
            let demographicAttr: [NSAttributedString.Key: Any] = [
                .font: config.captionFont,
                .foregroundColor: UIColor.gray
            ]
            let demographicRect = CGRect(x: config.margins.left, y: yPosition, width: contentWidth, height: 14)
            demographicText.draw(in: demographicRect, withAttributes: demographicAttr)
            yPosition += 16
        }

        yPosition += 7
        yPosition += 7
        return yPosition
    }

    private func headerDemographicParts() -> [String] {
        // User demographics row (age and sex if available)
        let settings = settingsProvider()
        var demographicParts: [String] = []
        if let age = settings.age {
            demographicParts.append(String(localized: "Age: \(age)", bundle: LanguageManager.appBundle))
        }
        if let sex = settings.biologicalSex, sex != .other {
            demographicParts.append(String(localized: "Sex: \(sex.displayName)", bundle: LanguageManager.appBundle))
        }
        return demographicParts
    }

    func drawSummaryCard(result: HRVAnalysisResult, ans: ANSMetrics?, compositeScore: Double? = nil, yPosition: CGFloat, in context: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        var y = drawSummaryHero(result: result, ans: ans, compositeScore: compositeScore, y: yPosition, contentWidth: contentWidth, in: context)
        y = drawSummaryHRStats(result: result, y: y, contentWidth: contentWidth)
        return y
    }

    /// The big RMSSD number, its assessment badge and age context, with the
    /// readiness gauge on the right.
    private func drawSummaryHero(result: HRVAnalysisResult, ans: ANSMetrics?, compositeScore: Double?, y: CGFloat, contentWidth: CGFloat, in context: UIGraphicsPDFRendererContext) -> CGFloat {
        var y = y
        // Large HRV Hero Section
        let heroHeight: CGFloat = 90
        let heroRect = CGRect(x: config.margins.left, y: y, width: contentWidth, height: heroHeight)
        UIColor(white: 0.97, alpha: 1.0).setFill()
        UIBezierPath(roundedRect: heroRect, cornerRadius: 10).fill()
        drawHeroRMSSDValue(result: result, y: y, heroRect: heroRect)
        drawHeroAssessment(result: result, y: y)
        // Readiness gauge on the right side — prefer composite score (includes sleep/training/vitals)
        let gaugeScore: Double? = compositeScore.map { $0 / 10.0 } ?? ans?.readinessScore
        if let readiness = gaugeScore {
            drawReadinessGauge(score: readiness, centerX: heroRect.maxX - 70, centerY: y + 45, radius: 35, in: context)
        }

        y += heroHeight + 10
        return y
    }

    private func drawHeroRMSSDValue(result: HRVAnalysisResult, y: CGFloat, heroRect: CGRect) {
        // Large RMSSD value in center-left
        let rmssd = result.timeDomain.rmssd
        let rmssdColor = hrvScoreColor(rmssd)

        let rmssdValueAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 48, weight: .bold),
            .foregroundColor: rmssdColor
        ]
        let rmssdValue = String(format: "%.0f", locale: .current, rmssd)
        let rmssdSize = rmssdValue.size(withAttributes: rmssdValueAttr)
        rmssdValue.draw(at: CGPoint(x: config.margins.left + 20, y: y + 15), withAttributes: rmssdValueAttr)

        // "ms" unit
        let unitAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 16, weight: .medium),
            .foregroundColor: UIColor.gray
        ]
        "ms".draw(at: CGPoint(x: config.margins.left + 25 + rmssdSize.width, y: y + 40), withAttributes: unitAttr)
    }

    /// "HRV (RMSSD)" caption plus the assessment badge and age-context line.
    private func drawHeroAssessment(result: HRVAnalysisResult, y: CGFloat) {
        let rmssd = result.timeDomain.rmssd
        // HRV label and assessment
        let hrvLabelAttr: [NSAttributedString.Key: Any] = [
            .font: config.captionFont,
            .foregroundColor: UIColor.gray
        ]
        String(localized: "HRV (RMSSD)", bundle: LanguageManager.appBundle).draw(at: CGPoint(x: config.margins.left + 20, y: y + 68), withAttributes: hrvLabelAttr)
        drawHeroBadge(rmssd: rmssd, y: y)
        drawHeroAgeContext(rmssd: rmssd, y: y)
    }

    private func drawHeroBadge(rmssd: Double, y: CGFloat) {
        let rmssdColor = hrvScoreColor(rmssd)
        // Assessment badge
        let assessment = hrvScoreLabel(rmssd)
        let badgeAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: rmssdColor
        ]
        let badgeSize = assessment.size(withAttributes: badgeAttr)
        let badgeRect = CGRect(x: config.margins.left + 85, y: y + 66, width: badgeSize.width + 12, height: 16)
        rmssdColor.withAlphaComponent(0.15).setFill()
        UIBezierPath(roundedRect: badgeRect, cornerRadius: 8).fill()
        assessment.draw(at: CGPoint(x: badgeRect.minX + 6, y: y + 68), withAttributes: badgeAttr)
    }

    private func drawHeroAgeContext(rmssd: Double, y: CGFloat) {
        let assessment = hrvScoreLabel(rmssd)
        let badgeAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8, weight: .semibold),
            .foregroundColor: UIColor.white
        ]
        let badgeSize = assessment.size(withAttributes: badgeAttr)
        let badgeRect = CGRect(x: config.margins.left + 85, y: y + 66, width: badgeSize.width + 12, height: 14)
        // Age context (e.g., "above average for your age")
        if let ageContext = hrvAgeContext(rmssd) {
            let contextAttr: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 8, weight: .regular),
                .foregroundColor: UIColor.gray
            ]
            ageContext.draw(at: CGPoint(x: badgeRect.maxX + 8, y: y + 68), withAttributes: contextAttr)
        }
    }

    private func drawSummaryHRStats(result: HRVAnalysisResult, y: CGFloat, contentWidth: CGFloat) -> CGFloat {
        let y = y
        // HR Stats Row
        let statsHeight: CGFloat = 50
        let statsRect = CGRect(x: config.margins.left, y: y, width: contentWidth, height: statsHeight)
        UIColor(white: 0.98, alpha: 1.0).setFill()
        UIBezierPath(roundedRect: statsRect, cornerRadius: 8).fill()

        let boxWidth = contentWidth / 4
        let hrStats: [(String, String, UIColor)] = [
            (String(localized: "Min HR", bundle: LanguageManager.appBundle), String(format: "%.0f bpm", locale: .current, result.timeDomain.minHR), config.secondaryColor),
            (String(localized: "Avg HR", bundle: LanguageManager.appBundle), String(format: "%.0f bpm", locale: .current, result.timeDomain.meanHR), config.accentColor),
            (String(localized: "Max HR", bundle: LanguageManager.appBundle), String(format: "%.0f bpm", locale: .current, result.timeDomain.maxHR), UIColor(red: 0.8, green: 0.4, blue: 0.5, alpha: 1)),
            ("SDNN", String(format: "%.1f ms", locale: .current, result.timeDomain.sdnn), config.primaryColor)
        ]
        drawHRStatBoxes(hrStats, y: y, boxWidth: boxWidth, statsHeight: statsHeight)
        return y + statsHeight + 15
    }

    private func drawHRStatBoxes(_ hrStats: [(String, String, UIColor)], y: CGFloat, boxWidth: CGFloat, statsHeight: CGFloat) {
        for (i, stat) in hrStats.enumerated() {
            let boxX = config.margins.left + CGFloat(i) * boxWidth
            drawCompactStatBox(
                title: stat.0,
                value: stat.1,
                color: stat.2,
                rect: CGRect(x: boxX + 4, y: y + 6, width: boxWidth - 8, height: statsHeight - 12)
            )
        }
    }

    func drawReadinessGauge(score: Double, centerX: CGFloat, centerY: CGFloat, radius: CGFloat, in context: UIGraphicsPDFRendererContext) {
        drawGaugeArcs(score: score, centerX: centerX, centerY: centerY, radius: radius, in: context)
        drawGaugeScoreText(score: score, centerX: centerX, centerY: centerY)
        drawGaugeLabel(centerX: centerX, centerY: centerY, radius: radius)
    }

    /// Grey track plus the coloured sweep proportional to the score.
    private func drawGaugeArcs(score: Double, centerX: CGFloat, centerY: CGFloat, radius: CGFloat, in context: UIGraphicsPDFRendererContext) {
        let ctx = context.cgContext
        ctx.saveGState()
        strokeGaugeTrack(centerX: centerX, centerY: centerY, radius: radius)
        strokeGaugeSweep(score: score, centerX: centerX, centerY: centerY, radius: radius)
        ctx.restoreGState()
    }

    private func strokeGaugeSweep(score: Double, centerX: CGFloat, centerY: CGFloat, radius: CGFloat) {
        readinessColor(score).setStroke()
        let scoreAngle = .pi * 0.75 + (.pi * 1.5 * CGFloat(score / 10.0))
        let scorePath = UIBezierPath(
            arcCenter: CGPoint(x: centerX, y: centerY),
            radius: radius,
            startAngle: .pi * 0.75,
            endAngle: scoreAngle,
            clockwise: true
        )
        scorePath.lineWidth = 8
        scorePath.lineCapStyle = .round
        scorePath.stroke()
    }

    private func drawGaugeScoreText(score: Double, centerX: CGFloat, centerY: CGFloat) {
        let scoreColor = readinessColor(score)
        // Score text in center
        let scoreText = String(format: "%.1f", locale: .current, score)
        let scoreAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 18, weight: .bold),
            .foregroundColor: scoreColor
        ]
        let scoreSize = scoreText.size(withAttributes: scoreAttr)
        scoreText.draw(at: CGPoint(x: centerX - scoreSize.width / 2, y: centerY - 10), withAttributes: scoreAttr)

        // "/10" below
        let subAttr: [NSAttributedString.Key: Any] = [
            .font: config.captionFont,
            .foregroundColor: UIColor.gray
        ]
        "/10".draw(at: CGPoint(x: centerX - 8, y: centerY + 8), withAttributes: subAttr)
    }

    func drawCompactStatBox(title: String, value: String, color: UIColor, rect: CGRect) {
        // Title
        let titleAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 7, weight: .medium),
            .foregroundColor: UIColor.gray
        ]
        title.draw(at: CGPoint(x: rect.minX + 4, y: rect.minY), withAttributes: titleAttr)

        // Value
        let valueAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 13, weight: .bold),
            .foregroundColor: color
        ]
        value.draw(at: CGPoint(x: rect.minX + 4, y: rect.minY + 12), withAttributes: valueAttr)
    }

    /// Get age-adjusted HRV interpretation using user settings
    func ageAdjustedInterpretation(_ rmssd: Double) -> RMSSDInterpretation {
        let settings = settingsProvider()
        let sex: AgeAdjustedHRV.Sex? = switch settings.biologicalSex {
        case .male: .male
        case .female: .female
        case .other, .none: nil
        }
        return AgeAdjustedHRV.interpret(rmssd: rmssd, age: settings.age, sex: sex)
    }

    func hrvScoreColor(_ rmssd: Double) -> UIColor {
        switch ageAdjustedInterpretation(rmssd).category {
        case .excellent: config.secondaryColor
        case .good: config.secondaryColor.withAlphaComponent(0.8)
        case .fair: UIColor(red: 0.85, green: 0.65, blue: 0.2, alpha: 1)
        case .reduced: UIColor.orange
        case .low: config.accentColor
        }
    }

    func hrvScoreLabel(_ rmssd: Double) -> String {
        ageAdjustedInterpretation(rmssd).localizedLabel
    }

    /// Age context for PDF reports, in the app language and sentence case.
    func hrvAgeContext(_ rmssd: Double) -> String? {
        ageAdjustedInterpretation(rmssd).localizedAgeContext
    }

    /// Readiness color aligned with RecoveryScoreCalculator.readinessLabel tiers (7.0/4.5/2.0)
    func readinessColor(_ score: Double) -> UIColor {
        if score >= 7.0 { return config.secondaryColor }
        if score >= 4.5 { return UIColor(red: 0.85, green: 0.65, blue: 0.2, alpha: 1) }
        if score >= 2.0 { return config.accentColor }
        return UIColor(red: 0.76, green: 0.42, blue: 0.42, alpha: 1)
    }

    func drawSummaryBox(title: String, value: String, color: UIColor, rect: CGRect) {
        // Value
        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 20, weight: .bold),
            .foregroundColor: color
        ]
        let valueRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 28)
        value.draw(in: valueRect, withAttributes: valueAttributes)

        // Title
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: config.captionFont,
            .foregroundColor: UIColor.gray
        ]
        let titleRect = CGRect(x: rect.minX, y: rect.minY + 30, width: rect.width, height: 14)
        title.draw(in: titleRect, withAttributes: titleAttributes)
    }

    // MARK: - Metric Sections

    func drawTimeDomainSection(_ td: TimeDomainMetrics, yPosition: CGFloat, in _: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        var y = yPosition

        y = drawSectionHeading(String(localized: "Time Domain HRV", bundle: LanguageManager.appBundle), yPosition: y, pageRect: pageRect)

        var metrics = [
            (String(localized: "Mean NN", bundle: LanguageManager.appBundle), String(format: "%.1f ms", locale: .current, td.meanRR)),
            ("SDNN", String(format: "%.1f ms", locale: .current, td.sdnn)),
            ("RMSSD", String(format: "%.1f ms", locale: .current, td.rmssd)),
            ("pNN50", String(format: "%.1f%%", locale: .current, td.pnn50)),
            (String(localized: "Mean HR", bundle: LanguageManager.appBundle), String(format: "%.0f bpm", locale: .current, td.meanHR)),
            ("SDSD", String(format: "%.1f ms", locale: .current, td.sdsd))
        ]

        if let tri = td.triangularIndex {
            metrics.append(("HRV TI", String(format: "%.1f", locale: .current, tri)))
        }

        y = drawCompactMetricsGrid(metrics, yPosition: y, pageRect: pageRect)

        return y + 8
    }

    func drawFrequencyDomainSection(_ fd: FrequencyDomainMetrics, yPosition: CGFloat, in _: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        var y = drawSectionHeading(String(localized: "Frequency Domain HRV", bundle: LanguageManager.appBundle), yPosition: yPosition, pageRect: pageRect)
        y = drawCompactMetricsGrid(frequencyGridMetrics(fd), yPosition: y, pageRect: pageRect)
        return y + 8
    }

    func drawNonlinearSection(_ nl: NonlinearMetrics, yPosition: CGFloat, in _: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        var y = drawSectionHeading(String(localized: "Nonlinear HRV", bundle: LanguageManager.appBundle), yPosition: yPosition, pageRect: pageRect)
        y = drawCompactMetricsGrid(nonlinearGridMetrics(nl), yPosition: y, pageRect: pageRect)
        return y + 8
    }

    func drawANSSection(_ ans: ANSMetrics, yPosition: CGFloat, in _: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        var y = drawSectionHeading(String(localized: "ANS Indexes", bundle: LanguageManager.appBundle), yPosition: yPosition, pageRect: pageRect)
        y = drawCompactMetricsGrid(ansGridMetrics(ans), yPosition: y, pageRect: pageRect)
        return y + 8
    }

    func drawQualitySection(_ result: HRVAnalysisResult, session: HRVSession, yPosition: CGFloat, in _: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        var y = drawSectionHeading(String(localized: "Data Quality", bundle: LanguageManager.appBundle), yPosition: yPosition, pageRect: pageRect)
        y = drawCompactMetricsGrid(qualityGridMetrics(result, session: session), yPosition: y, pageRect: pageRect)
        drawQualityNote(y: y, pageRect: pageRect)
        return y + 30
    }

    /// The window caveat, printed under the grid so the numbers above are not
    /// read as whole-session figures.
    private func drawQualityNote(y: CGFloat, pageRect: CGRect) {
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        // Add explanatory note
        let noteAttr: [NSAttributedString.Key: Any] = [
            .font: config.captionFont,
            .foregroundColor: UIColor.gray
        ]
        let noteText = String(localized: "Note: HRV metrics are calculated from a short analysis window selected for optimal data quality, not the full recording.", bundle: LanguageManager.appBundle)
        let noteRect = CGRect(x: config.margins.left, y: y + 4, width: contentWidth, height: 24)
        noteText.draw(in: noteRect, withAttributes: noteAttr)
    }

    func drawWindowSelectionSection(result: HRVAnalysisResult, yPosition: CGFloat, in _: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        let y = drawSectionHeading(String(localized: "Analysis Window", bundle: LanguageManager.appBundle), yPosition: yPosition, pageRect: pageRect)
        let cardHeight: CGFloat = 70
        drawWindowCardBackground(y: y, height: cardHeight, contentWidth: contentWidth)
        var infoY = y + 10
        infoY = drawWindowTimeRange(result: result, infoY: infoY)
        infoY = drawWindowStats(result: result, infoY: infoY)
        drawWindowSelectionReason(result: result, infoY: infoY, contentWidth: contentWidth)
        return y + cardHeight + 10
    }

    private func drawWindowCardBackground(y: CGFloat, height: CGFloat, contentWidth: CGFloat) {
        let cardRect = CGRect(x: config.margins.left, y: y, width: contentWidth, height: height)
        UIColor(white: 0.97, alpha: 1.0).setFill()
        UIBezierPath(roundedRect: cardRect, cornerRadius: 8).fill()
    }

    private func drawWindowTimeRange(result: HRVAnalysisResult, infoY: CGFloat) -> CGFloat {
        var infoY = infoY
        // Time range
        if let startMs = result.windowStartMs, let endMs = result.windowEndMs {
            let timeStr = "\(formatTimeMs(startMs)) – \(formatTimeMs(endMs)) (\(formatDurationMs(endMs - startMs)))"
            let timeAttr: [NSAttributedString.Key: Any] = [
                .font: config.bodyFont,
                .foregroundColor: UIColor.black
            ]
            String(localized: "Time Range: ", bundle: LanguageManager.appBundle).draw(at: CGPoint(x: config.margins.left + 10, y: infoY), withAttributes: [
                .font: config.captionFont,
                .foregroundColor: UIColor.gray
            ])
            timeStr.draw(at: CGPoint(x: config.margins.left + 70, y: infoY), withAttributes: timeAttr)
            infoY += 16
        }
        return infoY
    }

    /// Window mean HR and its stability, laid out left-to-right on one row.
    private func drawWindowStats(result: HRVAnalysisResult, infoY: CGFloat) -> CGFloat {
        var statsX = config.margins.left + 10
        statsX = drawWindowMeanHR(result: result, x: statsX, y: infoY)
        drawWindowStability(result: result, x: statsX, y: infoY)
        return infoY + 16
    }

    private func drawWindowMeanHR(result: HRVAnalysisResult, x: CGFloat, y infoY: CGFloat) -> CGFloat {
        var statsX = x
        if let meanHR = result.windowMeanHR {
            let hrStr = String(localized: "Window HR: \(String(format: "%.0f", locale: .current, meanHR)) bpm", bundle: LanguageManager.appBundle)
            hrStr.draw(at: CGPoint(x: statsX, y: infoY), withAttributes: [
                .font: config.captionFont,
                .foregroundColor: UIColor.darkGray
            ])
            statsX += 100
        }
        return statsX
    }

    private func drawWindowStability(result: HRVAnalysisResult, x statsX: CGFloat, y infoY: CGFloat) {
        if let stability = result.windowHRStability {
            let stabilityLabel = stabilityLabelFor(stability)
            let stabStr = String(localized: "Stability: \(stabilityLabel) (CV: \(String(format: "%.2f", locale: .current, stability)))", bundle: LanguageManager.appBundle)
            stabStr.draw(at: CGPoint(x: statsX, y: infoY), withAttributes: [
                .font: config.captionFont,
                .foregroundColor: stabilityColorFor(stability)
            ])
        }
    }

    private func drawWindowSelectionReason(result: HRVAnalysisResult, infoY: CGFloat, contentWidth: CGFloat) {
        // Selection reason
        if let reason = result.windowSelectionReason, !reason.isEmpty {
            let reasonAttr: [NSAttributedString.Key: Any] = [
                .font: config.captionFont,
                .foregroundColor: UIColor.darkGray
            ]
            let reasonRect = CGRect(x: config.margins.left + 10, y: infoY, width: contentWidth - 20, height: 24)
            reason.draw(in: reasonRect, withAttributes: reasonAttr)
        }
    }

    func formatTimeMs(_ ms: Int64) -> String {
        let totalSeconds = Int(ms / 1000)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    func formatDurationMs(_ ms: Int64) -> String {
        PDFDurationText.minutesSeconds(Int(clamping: ms / 1000))
    }

    func stabilityLabelFor(_ cv: Double) -> String {
        let bundle = LanguageManager.appBundle
        if cv < 0.03 { return String(localized: "Excellent", bundle: bundle) }
        if cv < 0.05 { return String(localized: "Good", bundle: bundle) }
        if cv < 0.08 { return String(localized: "Fair", bundle: bundle) }
        return String(localized: "Variable", bundle: bundle)
    }

    func stabilityColorFor(_ cv: Double) -> UIColor {
        if cv < 0.03 { return config.secondaryColor }
        if cv < 0.05 { return config.primaryColor }
        if cv < 0.08 { return UIColor.orange }
        return config.accentColor
    }

    func drawFooter(pageNumber: Int, in _: UIGraphicsPDFRendererContext, pageRect: CGRect) {
        let footerSize = drawPageFooterLine(pageNumber: pageNumber, pageRect: pageRect)
        drawWellnessDisclaimer(below: footerSize, pageRect: pageRect)
    }

    /// The centred "Emuqu • Page n • date" line. Returns its size so the
    /// disclaimer below can be positioned against it.
    private func drawPageFooterLine(pageNumber: Int, pageRect: CGRect) -> CGSize {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = LanguageManager.appLocale
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        let footer = String(localized: "Emuqu  •  Page \(pageNumber)  •  \(dateFormatter.string(from: Date()))", bundle: LanguageManager.appBundle)
        let footerAttributes: [NSAttributedString.Key: Any] = [
            .font: config.captionFont,
            .foregroundColor: UIColor.gray
        ]

        let footerSize = footer.size(withAttributes: footerAttributes)
        let footerRect = CGRect(
            x: (pageRect.width - footerSize.width) / 2,
            y: pageRect.height - config.margins.bottom + 15,
            width: footerSize.width,
            height: footerSize.height
        )
        footer.draw(in: footerRect, withAttributes: footerAttributes)
        return footerSize
    }

    private func drawWellnessDisclaimer(below footerSize: CGSize, pageRect: CGRect) {
        // Wellness disclaimer on EVERY page. The deep-dive pages
        // carry clinically-worded prose (VLF/inflammation, SpO2, illness
        // signals) and are shared externally; a single disclaimer on the
        // optional analysis-summary page is not enough (Summary preset and
        // the deep-dive pages could export with none).
        let disclaimer = String(localized: "For wellness and fitness use only. Not a medical device; not medical advice, diagnosis, or treatment.", bundle: LanguageManager.appBundle)
        let disclaimerAttributes: [NSAttributedString.Key: Any] = [
            .font: config.captionFont,
            .foregroundColor: UIColor.gray
        ]
        let disclaimerRect = CGRect(
            x: config.margins.left,
            y: pageRect.height - config.margins.bottom + 15 + footerSize.height + 1,
            width: pageRect.width - config.margins.left - config.margins.right,
            height: footerSize.height + 2
        )
        disclaimer.draw(in: disclaimerRect, withAttributes: disclaimerAttributes)
    }

    // MARK: - Auto-Pagination

    /// Ensure enough space remains on the current page; if not, end the current page and start a new one.
    func ensureSpace(needed: CGFloat, y: CGFloat, pageNumber: inout Int, context: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        let bottomLimit = pageRect.height - config.margins.bottom - 20 // 20pt buffer for footer
        if y + needed > bottomLimit {
            drawFooter(pageNumber: pageNumber, in: context, pageRect: pageRect)
            pageNumber += 1
            context.beginPage()
            return config.margins.top
        }
        return y
    }

    // MARK: - Score Breakdown Section

    /// Height of the composite-score badge. Named because the badge is drawn in
    /// one function and the cursor is advanced past it in the next.
    private static let compositeBadgeHeight: CGFloat = 28

    /// Height of one factor row; the loop advances by it and the row draws to it.
    private static let factorRowHeight: CGFloat = 38

    /// Colour for a factor's impact — green helping, red hurting, grey neutral.
    /// One definition; the dot and the bar fill both read from it.
    private func factorImpactColour(_ impact: RecoveryScoreCalculator.ScoreFactor.Impact) -> UIColor {
        switch impact {
        case .positive: config.secondaryColor
        case .neutral: UIColor.systemYellow
        case .negative: config.accentColor
        }
    }

    /// Draw the recovery score breakdown showing each factor's contribution and vitals penalties
    func drawScoreBreakdownSection(breakdown: RecoveryScoreCalculator.ScoreBreakdown, yPosition: CGFloat, in _: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        var y = yPosition

        y = drawSectionHeading(String(localized: "Recovery Score Breakdown", bundle: LanguageManager.appBundle), yPosition: y, pageRect: pageRect)
        y = drawCompositeScoreBadge(breakdown: breakdown, y: y, contentWidth: contentWidth)
        y = drawCompositeMessage(breakdown: breakdown, y: y, contentWidth: contentWidth)
        y = drawFactorBars(breakdown: breakdown, y: y, contentWidth: contentWidth)
        y = drawVitalsPenalties(breakdown: breakdown, y: y, contentWidth: contentWidth)
        return drawWeightedAverageNote(breakdown: breakdown, y: y, contentWidth: contentWidth)
    }

    private func drawCompositeScoreBadge(breakdown: RecoveryScoreCalculator.ScoreBreakdown, y: CGFloat, contentWidth: CGFloat) -> CGFloat {
        let badgeColor = diagnosticColorForScore(breakdown.compositeScore)
        let badgeRect = CGRect(x: config.margins.left, y: y, width: contentWidth, height: Self.compositeBadgeHeight)
        badgeColor.withAlphaComponent(0.1).setFill()
        UIBezierPath(roundedRect: badgeRect, cornerRadius: 6).fill()
        drawCompositeScoreBadgeLabels(breakdown: breakdown, badgeColor: badgeColor, y: y)
        return y
    }

    private func drawCompositeScoreBadgeLabels(
        breakdown: RecoveryScoreCalculator.ScoreBreakdown,
        badgeColor: UIColor,
        y: CGFloat
    ) {
        let scoreStr = String(format: "%.0f", locale: .current, breakdown.compositeScore)
        let tierStr = String(localized: "Tier \(breakdown.tier)", bundle: LanguageManager.appBundle)
        let scoreBadgeAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 16, weight: .bold),
            .foregroundColor: badgeColor
        ]
        scoreStr.draw(at: CGPoint(x: config.margins.left + 12, y: y + 5), withAttributes: scoreBadgeAttr)

        let tierAttr: [NSAttributedString.Key: Any] = [
            .font: config.captionFont,
            .foregroundColor: UIColor.gray
        ]
        tierStr.draw(at: CGPoint(x: config.margins.left + 50, y: y + 10), withAttributes: tierAttr)
    }

    private func drawCompositeMessage(breakdown: RecoveryScoreCalculator.ScoreBreakdown, y: CGFloat, contentWidth: CGFloat) -> CGFloat {
        var y = y
        // Composite message
        let msgAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9),
            .foregroundColor: UIColor.darkGray
        ]
        let msgSize = breakdown.message.size(withAttributes: msgAttr)
        breakdown.message.draw(at: CGPoint(x: config.margins.left + contentWidth - msgSize.width - 8, y: y + 9), withAttributes: msgAttr)

        y += Self.compositeBadgeHeight + 10
        return y
    }

    /// One horizontal bar per scoring factor, in the order the score uses them.
    private func drawFactorBars(breakdown: RecoveryScoreCalculator.ScoreBreakdown, y: CGFloat, contentWidth: CGFloat) -> CGFloat {
        var y = y
        for factor in breakdown.factors {
            drawFactorRow(factor: factor, y: y, contentWidth: contentWidth)
            y += Self.factorRowHeight + 4
        }
        return y
    }

    /// Colour dot and label — the left half of the line above the bar.
    private func drawFactorRow(factor: RecoveryScoreCalculator.ScoreFactor, y: CGFloat, contentWidth: CGFloat) {
        let barHeight = Self.factorRowHeight
        let factorRect = CGRect(x: config.margins.left, y: y, width: contentWidth, height: barHeight)
        UIColor(white: 0.97, alpha: 1.0).setFill()
        UIBezierPath(roundedRect: factorRect, cornerRadius: 4).fill()

        // Color dot
        factorImpactColour(factor.impact).setFill()
        UIBezierPath(ovalIn: CGRect(x: config.margins.left + 8, y: y + 6, width: 6, height: 6)).fill()

        // Label
        let labelAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: UIColor.black
        ]
        factor.label.draw(at: CGPoint(x: config.margins.left + 20, y: y + 3), withAttributes: labelAttr)
        drawFactorScoreAndWeight(factor: factor, y: y, contentWidth: contentWidth)
        drawFactorProgressBar(factor: factor, y: y, contentWidth: contentWidth)
    }

    /// The right-aligned "72 × 30%" pair.
    private func drawFactorScoreAndWeight(factor: RecoveryScoreCalculator.ScoreFactor, y: CGFloat, contentWidth: CGFloat) {
        // Score + weight
        let scoreValAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 11, weight: .bold),
            .foregroundColor: factorImpactColour(factor.impact)
        ]
        let weightAttr: [NSAttributedString.Key: Any] = [
            .font: config.captionFont,
            .foregroundColor: UIColor.gray
        ]
        let scoreText = String(format: "%.0f", locale: .current, factor.score)
        let weightText = String(format: " × %.0f%%", locale: .current, factor.weight * 100)
        let scoreSize = scoreText.size(withAttributes: scoreValAttr)
        let weightSize = weightText.size(withAttributes: weightAttr)
        let rightX = config.margins.left + contentWidth - scoreSize.width - weightSize.width - 12
        scoreText.draw(at: CGPoint(x: rightX, y: y + 3), withAttributes: scoreValAttr)
        weightText.draw(at: CGPoint(x: rightX + scoreSize.width, y: y + 5), withAttributes: weightAttr)
    }

    /// The progress track and its fill.
    private func drawFactorProgressBar(factor: RecoveryScoreCalculator.ScoreFactor, y: CGFloat, contentWidth: CGFloat) {
        // Progress bar
        let barTrackRect = CGRect(x: config.margins.left + 20, y: y + 20, width: contentWidth - 40, height: 4)
        UIColor(white: 0.88, alpha: 1.0).setFill()
        UIBezierPath(roundedRect: barTrackRect, cornerRadius: 2).fill()

        let fillWidth = barTrackRect.width * CGFloat(min(factor.score, 100) / 100.0)
        let barFillRect = CGRect(x: barTrackRect.minX, y: barTrackRect.minY, width: fillWidth, height: barTrackRect.height)
        factorImpactColour(factor.impact).setFill()
        UIBezierPath(roundedRect: barFillRect, cornerRadius: 2).fill()
        drawFactorDetail(factor: factor, y: y, contentWidth: contentWidth)
    }

    /// #17 — bounded and clipped to the factor row so a long vitals string
    /// cannot overrun into the page footer.
    private func drawFactorDetail(factor: RecoveryScoreCalculator.ScoreFactor, y: CGFloat, contentWidth: CGFloat) {
        // Detail text — #17: bounded + clipped to the factor row so a long
        // vitals string can't overrun into the page footer (it was drawn at
        // an unbounded point and interleaved "…Page 1…4:32 AM" into the
        // vitals line).
        let detailParagraph = NSMutableParagraphStyle()
        detailParagraph.lineBreakMode = .byTruncatingTail
        let detailAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 7.5),
            .foregroundColor: UIColor.gray,
            .paragraphStyle: detailParagraph
        ]
        let detailRect = CGRect(x: config.margins.left + 20, y: y + 27, width: contentWidth - 40, height: 10)
        factor.detail.draw(in: detailRect, withAttributes: detailAttr)
    }

    private func drawVitalsPenalties(breakdown: RecoveryScoreCalculator.ScoreBreakdown, y: CGFloat, contentWidth: CGFloat) -> CGFloat {
        guard !breakdown.penalties.isEmpty else { return y }
        var y = y + 4
        String(localized: "Vitals Penalties Applied:", bundle: LanguageManager.appBundle).draw(
            at: CGPoint(x: config.margins.left + 8, y: y),
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: config.accentColor
            ]
        )
        y += 14
        for penalty in breakdown.penalties {
            "  ⚠ \(penalty)".draw(at: CGPoint(x: config.margins.left + 8, y: y), withAttributes: [
                .font: UIFont.systemFont(ofSize: 8.5),
                .foregroundColor: UIColor(red: 0.6, green: 0.3, blue: 0.3, alpha: 1)
            ])
            y += 12
        }
        drawPenaltyExplanation(y: y + 2, contentWidth: contentWidth)
        return y + 28
    }

    /// Why penalties exist at all — they are deducted after the weighted
    /// composite, so the factor rows above will not add up to the badge.
    private func drawPenaltyExplanation(y: CGFloat, contentWidth: CGFloat) {
        let penaltyExplain = String(localized: "Vitals penalties are deducted after the weighted composite. Elevated respiratory rate, temperature, or low SpO₂ signal physiological stress that may not yet appear in HRV.", bundle: LanguageManager.appBundle)
        let explainRect = CGRect(x: config.margins.left + 8, y: y, width: contentWidth - 16, height: 24)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        NSAttributedString(string: penaltyExplain, attributes: [
            .font: UIFont.systemFont(ofSize: 7.5),
            .foregroundColor: UIColor.gray,
            .paragraphStyle: paragraphStyle
        ]).draw(in: explainRect)
    }

    /// Transparency line: when vitals penalties took more than a point off the
    /// weighted average, say so rather than letting the bars look wrong. A gap
    /// with no penalty behind it (baseline drift) is not labelled "Vitals".
    private func drawWeightedAverageNote(breakdown: RecoveryScoreCalculator.ScoreBreakdown, y: CGFloat, contentWidth: CGFloat) -> CGFloat {
        var y = y
        // Weighted average vs final (transparency)
        let weightedAvg = breakdown.factors.reduce(0.0) { $0 + $1.contribution }
        if !breakdown.penalties.isEmpty, weightedAvg - breakdown.compositeScore > 1 {
            let mathAttr: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 8, weight: .regular),
                .foregroundColor: UIColor.darkGray
            ]
            let penaltyTotal = weightedAvg - breakdown.compositeScore
            let mathStr = String(localized: "Weighted average: \(String(format: "%.1f", locale: .current, weightedAvg))  −  Vitals: \(String(format: "%.1f", locale: .current, penaltyTotal))  =  Final: \(String(format: "%.0f", locale: .current, breakdown.compositeScore))", bundle: LanguageManager.appBundle)
            mathStr.draw(at: CGPoint(x: config.margins.left + 8, y: y), withAttributes: mathAttr)
            y += 14
        }

        return y + 8
    }
}

// MARK: - File-scope helpers
//
// Kept out of the type. Each touches no instance state — including the
// computed properties — and calls nothing inside it, so none is a method
// in anything but placement. `private` at file scope is fileprivate, so
// every call site in this file resolves the same way.
//
// This is what `check_aggregate_type_size.sh` measures: a type is the sum of
// its parts across every file, so code that does not need the type inflates
// that number without making the type do more.

/// The "Recording: … (n beats)" line. A HealthKit summary import has no raw
/// beats, so it says so rather than printing "0.0 min (0 beats)" above
/// populated HR figures (#6).
private func headerSessionInfoText(session: HRVSession) -> String {
    let dateFormatter = DateFormatter()
    dateFormatter.locale = LanguageManager.appLocale
    dateFormatter.dateStyle = .medium
    dateFormatter.timeStyle = .short

    let totalBeats = session.rrSeries?.points.count ?? 0
    let reportDate = session.endDate ?? session.startDate
    // #6 — don't render "Recording: 0.0 min (0 beats)" above populated HR
    // for a HealthKit summary import; say so instead.
    let infoText = totalBeats > 0
        ? String(localized: "Date: \(dateFormatter.string(from: reportDate))  •  Recording: \(String(format: "%.1f", locale: .current, session.rrSeries?.durationMinutes ?? 0)) min (\(totalBeats) beats)", bundle: LanguageManager.appBundle)
        : String(localized: "Date: \(dateFormatter.string(from: reportDate))  •  Summary import (no raw beat data)", bundle: LanguageManager.appBundle)
    return infoText
}

private func strokeGaugeTrack(centerX: CGFloat, centerY: CGFloat, radius: CGFloat) {
    UIColor(white: 0.9, alpha: 1.0).setStroke()
    let bgPath = UIBezierPath(
        arcCenter: CGPoint(x: centerX, y: centerY),
        radius: radius,
        startAngle: .pi * 0.75,
        endAngle: .pi * 2.25,
        clockwise: true
    )
    bgPath.lineWidth = 8
    bgPath.lineCapStyle = .round
    bgPath.stroke()
}

private func drawGaugeLabel(centerX: CGFloat, centerY: CGFloat, radius: CGFloat) {
    // "Recovery" label below gauge
    let labelAttr: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 7, weight: .medium),
        .foregroundColor: UIColor.gray
    ]
    String(localized: "Recovery", bundle: LanguageManager.appBundle).draw(at: CGPoint(x: centerX - 16, y: centerY + radius + 2), withAttributes: labelAttr)
}

/// The grid rows, as data. Which rows appear depends on what the analysis
/// produced, so the omissions live here rather than inside the drawing.
private func frequencyGridMetrics(_ fd: FrequencyDomainMetrics) -> [(String, String)] {
    var metrics: [(String, String)] = []

    if let vlf = fd.vlf {
        metrics.append(("VLF", String(format: "%.0f ms²", locale: .current, vlf)))
    }
    metrics.append(("LF", String(format: "%.0f ms²", locale: .current, fd.lf)))
    metrics.append(("HF", String(format: "%.0f ms²", locale: .current, fd.hf)))
    if let ratio = fd.lfHfRatio {
        metrics.append(("LF/HF", String(format: "%.2f", locale: .current, ratio)))
    }
    metrics.append((String(localized: "Total", bundle: LanguageManager.appBundle), String(format: "%.0f ms²", locale: .current, fd.totalPower)))
    if let lfNu = fd.lfNu, let hfNu = fd.hfNu {
        metrics.append(("LF n.u.", String(format: "%.1f%%", locale: .current, lfNu)))
        metrics.append(("HF n.u.", String(format: "%.1f%%", locale: .current, hfNu)))
    }
    return metrics
}

/// The grid rows, as data. SD1/SD2 are always present; the entropies and DFA
/// exponents only appear when the analysis produced them.
private func nonlinearGridMetrics(_ nl: NonlinearMetrics) -> [(String, String)] {
    var metrics: [(String, String)] = [
        ("SD1", String(format: "%.1f ms", locale: .current, nl.sd1)),
        ("SD2", String(format: "%.1f ms", locale: .current, nl.sd2)),
        ("SD1/SD2", String(format: "%.3f", locale: .current, nl.sd1Sd2Ratio))
    ]

    if let approxEntropy = nl.approxEntropy {
        metrics.append(("ApEn", String(format: "%.3f", locale: .current, approxEntropy)))
    }
    if let sampleEntropy = nl.sampleEntropy {
        metrics.append(("SampEn", String(format: "%.3f", locale: .current, sampleEntropy)))
    }
    if let a1 = nl.dfaAlpha1 {
        metrics.append(("DFA α1", String(format: "%.3f", locale: .current, a1)))
    }
    if let a2 = nl.dfaAlpha2 {
        metrics.append(("DFA α2", String(format: "%.3f", locale: .current, a2)))
    }
    return metrics
}

/// The grid rows, as data. Which rows appear depends on what the analysis
/// produced, so the omissions live here rather than inside the drawing.
private func ansGridMetrics(_ ans: ANSMetrics) -> [(String, String)] {
    var metrics: [(String, String)] = []

    if let stressIndex = ans.stressIndex {
        metrics.append((String(localized: "Stress Index", bundle: LanguageManager.appBundle), String(format: "%.1f", locale: .current, stressIndex)))
    }
    if let pns = ans.pnsIndex {
        metrics.append((String(localized: "PNS Index", bundle: LanguageManager.appBundle), String(format: "%+.2f", locale: .current, pns)))
    }
    if let sns = ans.snsIndex {
        metrics.append((String(localized: "SNS Index", bundle: LanguageManager.appBundle), String(format: "%+.2f", locale: .current, sns)))
    }
    if let readiness = ans.readinessScore {
        metrics.append((String(localized: "HRV Readiness", bundle: LanguageManager.appBundle), String(format: "%.1f/10", locale: .current, readiness)))
    }
    if let resp = ans.respirationRate {
        metrics.append((String(localized: "Resp Rate", bundle: LanguageManager.appBundle), String(format: "%.1f/min", locale: .current, resp)))
    }
    return metrics
}

private func qualityGridMetrics(_ result: HRVAnalysisResult, session: HRVSession) -> [(String, String)] {
    // Calculate window duration for context
    let windowDurationMs = result.windowEndMs.map { end in
        result.windowStartMs.map { start in end - start } ?? 0
    } ?? 0
    let windowDurationMin = Double(windowDurationMs) / 60000.0
    let windowDurationStr = windowDurationMin > 0
        ? String(localized: "\(windowDurationMin, specifier: "%.1f") min", bundle: LanguageManager.appBundle)
        : "—"

    let metrics: [(String, String)] = [
        (String(localized: "Recorded Beats", bundle: LanguageManager.appBundle), "\(session.rrSeries?.points.count ?? 0)"),
        (String(localized: "Analysis Window", bundle: LanguageManager.appBundle), windowDurationStr),
        (String(localized: "Window Beats", bundle: LanguageManager.appBundle), "\(result.cleanBeatCount)"),
        (String(localized: "Artifacts", bundle: LanguageManager.appBundle), String(format: "%.1f%%", locale: .current, result.artifactPercentage))
    ]
    return metrics
}
