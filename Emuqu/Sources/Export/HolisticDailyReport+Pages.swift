import CoreLocation
import Foundation
import PDFKit
import UIKit

// The two report pages and the drawing primitives they share. Members are
// internal rather than `private` because Swift's `private` does not reach
// across files.

extension HolisticDailyReport {
    // MARK: - Page 1: Today, in one glance

    func drawTodayInOneGlancePage(ctx: UIGraphicsPDFRendererContext) {
        ctx.beginPage()
        var y = config.margin
        let contentW = config.pageSize.width - 2 * config.margin
        let bundle = LanguageManager.appBundle
        y = drawGlanceHeader(y: y, contentW: contentW, bundle: bundle)
        y = drawGlanceHero(y: y, contentW: contentW, bundle: bundle)
        drawGlanceColumns(y: y, contentW: contentW, bundle: bundle)
    }

    /// Title strip and the date line under it.
    func drawGlanceHeader(y: CGFloat, contentW: CGFloat, bundle: Bundle) -> CGFloat {
        var y = y
        // Header strip
        drawText(String(localized: "EMUQU · DAILY REPORT", bundle: LanguageManager.appBundle),
                 at: CGPoint(x: config.margin, y: y),
                 font: UIFont.systemFont(ofSize: 9, weight: .semibold),
                 color: config.textTertiary)
        y += 14
        drawDivider(at: y, width: contentW, strong: true)
        y += 14

        drawText(Self.headerDate(workoutSession.startDate),
                 at: CGPoint(x: config.margin, y: y),
                 font: UIFont.systemFont(ofSize: 14, weight: .semibold),
                 color: config.textSecondary)
        drawLoadAsOf(y: y, contentW: contentW)
        y += 26
        return y
    }

    /// Right of the date: which era the training-load numbers in this PDF
    /// are from, so a reader comparing them with the dashboard knows they
    /// are its live values. Absent for a past day, whose load is the one
    /// frozen with its sessions.
    func drawLoadAsOf(y: CGFloat, contentW: CGFloat) {
        guard let asOf = loadAsOfDisplay() else { return }
        let font = UIFont.systemFont(ofSize: 9, weight: .regular)
        let width = ceil((asOf as NSString).size(withAttributes: [.font: font]).width)
        drawText(asOf, at: CGPoint(x: config.margin + contentW - width, y: y + 4), font: font, color: config.textTertiary)
    }

    /// The full date in the app's language, upper-cased for the header.
    static func headerDate(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = LanguageManager.appLocale
        df.dateStyle = .full
        df.timeStyle = .none
        return df.string(from: date).uppercased(with: LanguageManager.appLocale)
    }

    /// The loop verdict — the one line a reader takes away from the page.
    func drawGlanceHero(y: CGFloat, contentW: CGFloat, bundle: Bundle) -> CGFloat {
        let analysis = self.analysis()
        let heroColor = toneColor(analysis.verdictTone)
        // At least 96 pt, taller when a long or translated blurb needs it.
        let blurbHeight = wrappedTextHeight(
            analysis.verdict.blurb, width: contentW - 44, font: UIFont.systemFont(ofSize: 12, weight: .regular), lineHeight: 15
        )
        let heroRect = CGRect(x: config.margin, y: y, width: contentW, height: max(96, 48 + blurbHeight + 16))
        heroColor.withAlphaComponent(0.10).setFill()
        UIBezierPath(roundedRect: heroRect, cornerRadius: 12).fill()
        heroColor.setFill()
        UIBezierPath(rect: CGRect(x: heroRect.minX, y: heroRect.minY, width: 6, height: heroRect.height)).fill()
        drawGlanceHeroText(analysis.verdict, heroColor: heroColor, in: heroRect)
        return y + heroRect.height + 22
    }

    func drawGlanceHeroText(_ v: (label: String, blurb: String), heroColor: UIColor, in heroRect: CGRect) {
        drawText(v.label,
                 at: CGPoint(x: heroRect.minX + 22, y: heroRect.minY + 16),
                 font: UIFont.systemFont(ofSize: 22, weight: .heavy),
                 color: heroColor)
        _ = drawWrappedText(v.blurb,
                            at: CGPoint(x: heroRect.minX + 22, y: heroRect.minY + 48),
                            width: heroRect.width - 44,
                            font: UIFont.systemFont(ofSize: 12, weight: .regular),
                            color: config.textPrimary,
                            lineHeight: 15)
    }

    /// This Morning on the left, Today's Workout on the right, then the loop
    /// paragraph and tomorrow's line across the full width beneath them.
    func drawGlanceColumns(y: CGFloat, contentW: CGFloat, bundle: Bundle) {
        // Two columns: This Morning | Today's Workout
        let colGap: CGFloat = 18
        let colW = (contentW - colGap) / 2
        let rightX = config.margin + colW + colGap
        let leftY = drawGlanceMorningColumn(y: y, colW: colW, bundle: bundle)
        let rightY = drawGlanceWorkoutColumn(y: y, colW: colW, rightX: rightX, bundle: bundle)
        var y = max(leftY, rightY)
        y = drawGlanceLoopParagraph(y: y, contentW: contentW, bundle: bundle)
        drawGlanceTomorrow(y: y, contentW: contentW, bundle: bundle)
    }

    func drawGlanceMorningColumn(y: CGFloat, colW: CGFloat, bundle: Bundle) -> CGFloat {
        var leftY = y
        // Left column header
        drawText(String(localized: "THIS MORNING", bundle: LanguageManager.appBundle),
                 at: CGPoint(x: config.margin, y: leftY),
                 font: UIFont.systemFont(ofSize: 11, weight: .bold),
                 color: config.primary)
        leftY += 18
        drawDivider(at: leftY - 4, width: colW, strong: false)
        leftY += 4
        return drawGlanceRecoveryRows(leftY: leftY, colW: colW, bundle: bundle)
    }

    func drawGlanceRecoveryRows(leftY: CGFloat, colW _: CGFloat, bundle _: Bundle) -> CGFloat {
        drawGlanceStatRows(morningRecoveryRows(), x: config.margin, y: leftY)
    }

    /// One stat block per row: small label, big value, optional coloured
    /// sub-line. Both glance columns draw the same shape at different x — the
    /// two copies had already been kept in step by hand.
    func drawGlanceStatRows(_ rows: [GlanceRow], x: CGFloat, y: CGFloat) -> CGFloat {
        var y = y
        for row in rows {
            drawText(row.label,
                     at: CGPoint(x: x, y: y),
                     font: UIFont.systemFont(ofSize: 9, weight: .regular),
                     color: config.textTertiary)
            y += 11
            drawText(row.value,
                     at: CGPoint(x: x, y: y),
                     font: UIFont.systemFont(ofSize: 18, weight: .semibold),
                     color: config.textPrimary)
            y += drawGlanceStatSubline(row, x: x, y: y)
            y += 6
        }
        return y
    }

    /// Height consumed by the row's value line plus its sub-line, if any.
    func drawGlanceStatSubline(_ row: GlanceRow, x: CGFloat, y: CGFloat) -> CGFloat {
        guard let sub = row.sub else { return 22 }
        drawText(sub,
                 at: CGPoint(x: x + 4, y: y + 22),
                 font: UIFont.systemFont(ofSize: 9, weight: .regular),
                 color: row.subColour ?? config.textSecondary)
        return 22 + 12
    }

    func drawGlanceWorkoutColumn(y: CGFloat, colW: CGFloat, rightX: CGFloat, bundle: Bundle) -> CGFloat {
        var rightY = y
        // Right column header
        drawText(String(localized: "TODAY'S WORKOUT", bundle: LanguageManager.appBundle),
                 at: CGPoint(x: rightX, y: rightY),
                 font: UIFont.systemFont(ofSize: 11, weight: .bold),
                 color: config.primary)
        rightY += 18
        return drawGlanceWorkoutRows(rightY: rightY, colW: colW, rightX: rightX, bundle: bundle)
    }

    func drawGlanceWorkoutRows(rightY: CGFloat, colW: CGFloat, rightX: CGFloat, bundle _: Bundle) -> CGFloat {
        var rightY = rightY
        // Divider for right column
        if let cgctx = UIGraphicsGetCurrentContext() {
            cgctx.setStrokeColor(config.divider.cgColor)
            cgctx.setLineWidth(0.5)
            cgctx.move(to: CGPoint(x: rightX, y: rightY - 4))
            cgctx.addLine(to: CGPoint(x: rightX + colW, y: rightY - 4))
            cgctx.strokePath()
        }
        rightY += 4
        return drawGlanceStatRows(workoutOutputRows(), x: rightX, y: rightY)
    }

    /// The cause-and-effect sentence tying the morning reading to the session.
    func drawGlanceLoopParagraph(y: CGFloat, contentW: CGFloat, bundle: Bundle) -> CGFloat {
        var y = y
        // The Loop — the cause-and-effect paragraph
        drawText(String(localized: "THE LOOP", bundle: LanguageManager.appBundle),
                 at: CGPoint(x: config.margin, y: y),
                 font: UIFont.systemFont(ofSize: 11, weight: .bold),
                 color: config.primary)
        y += 18
        let loopProse = loopParagraph()
        y = drawWrappedText(loopProse,
                            at: CGPoint(x: config.margin, y: y),
                            width: contentW,
                            font: UIFont.systemFont(ofSize: 12, weight: .regular),
                            color: config.textPrimary,
                            lineHeight: 16)
        y += 18
        return y
    }

    func drawGlanceTomorrow(y: CGFloat, contentW: CGFloat, bundle: Bundle) {
        drawText(String(localized: "TOMORROW", bundle: bundle),
                 at: CGPoint(x: config.margin, y: y),
                 font: UIFont.systemFont(ofSize: 11, weight: .bold),
                 color: config.primary)
        drawTomorrowAction(y: y + 18, contentW: contentW)
        drawFooter(pageNumber: 1)
    }

    /// The arrow plus the single specific thing to do tomorrow.
    func drawTomorrowAction(y: CGFloat, contentW: CGFloat) {
        let tom = tomorrowAction()
        let arrow = "→ "
        drawText(arrow,
                 at: CGPoint(x: config.margin, y: y),
                 font: UIFont.systemFont(ofSize: 12, weight: .bold),
                 color: config.sage)
        _ = drawWrappedText(tom,
                            at: CGPoint(x: config.margin + 16, y: y),
                            width: contentW - 16,
                            font: UIFont.systemFont(ofSize: 12, weight: .regular),
                            color: config.textPrimary,
                            lineHeight: 16)
    }

    /// Sage above 7.5, amber above 5.5, primary below — the same bands the
    /// dashboard pill uses.
    func readinessBandColour(_ value: Double) -> UIColor {
        if value >= 7.5 { return config.sage }
        if value >= 5.5 { return config.amber }
        return config.primary
    }

    /// The left "morning recovery" column, one stat per row.
    func morningRecoveryRows() -> [GlanceRow] {
        let bundle = LanguageManager.appBundle
        guard overnightSession != nil else {
            return [GlanceRow(String(localized: "Status", bundle: bundle), String(localized: "No morning data", bundle: bundle), String(localized: "Start an overnight session to enable the loop story.", bundle: bundle), config.amber)]
        }
        return [
            morningHRVRow(bundle: bundle),
            morningSleepRow(bundle: bundle),
            morningTrainingBalanceRow(bundle: bundle)
        ].compactMap { $0 }
    }

    func morningHRVRow(bundle: Bundle) -> GlanceRow? {
        guard let rmssd = overnightSession?.rmssd else { return nil }
        var sub: String?
        var subColor: UIColor?
        if let pct = analysis().hrvPercentVsBaseline {
            let dir = pct >= 0 ? "+" : ""
            sub = String(localized: "\(dir)\(Int(pct.rounded()))% vs your recent baseline", bundle: bundle)
            subColor = pct >= 5 ? config.sage : (pct <= -5 ? config.primary : config.textSecondary)
        }
        return GlanceRow(String(localized: "HRV (RMSSD)", bundle: bundle), "\(Int(rmssd.rounded())) ms", sub, subColor)
    }

    func morningSleepRow(bundle: Bundle) -> GlanceRow? {
        guard let sleep = overnightSession?.sleepSnapshot else { return nil }
        let total = sleep.nightSleepMinutes
        let dur = reportHoursMinutes(total)
        // Efficiency is already a 0-100 percentage; nil when the night's wake was not measured.
        let eff = if let efficiency = sleep.measuredSleepEfficiency {
            String(localized: "\(Int(efficiency.rounded()))% efficiency", bundle: bundle)
        } else {
            String(localized: "Efficiency not measured", bundle: bundle)
        }
        return GlanceRow(String(localized: "Sleep", bundle: bundle), dur, eff, config.textSecondary)
    }

    func morningTrainingBalanceRow(bundle: Bundle) -> GlanceRow? {
        guard let snap = trainingLoadForReport() else { return nil }
        let tsbStr = String(format: "%+.1f", locale: LanguageManager.appLocale, snap.tsb)
        let interp: String
        let interpColor: UIColor
        if snap.tsb > 5 {
            interp = String(localized: "Fresh — quality session ready", bundle: bundle); interpColor = config.sage
        } else if snap.tsb < -10 {
            interp = String(localized: "Tired — go easy or rest", bundle: bundle); interpColor = config.primary
        } else {
            interp = String(localized: "Balanced load", bundle: bundle); interpColor = config.textSecondary
        }
        return GlanceRow(String(localized: "Training balance (TSB)", bundle: bundle), tsbStr, interp, interpColor)
    }

    /// The right "today's workout" column.
    func workoutOutputRows() -> [GlanceRow] {
        let bundle = LanguageManager.appBundle
        return [
            workoutSummaryRow(bundle: bundle),
            workoutInternalLoadRow(bundle: bundle),
            workoutTSSRow(bundle: bundle),
            workoutHRRRow(bundle: bundle)
        ].compactMap { $0 }
    }

    func workoutSummaryRow(bundle: Bundle) -> GlanceRow? {
        let meta = workoutSession.workoutMetadata
        let sport = meta?.sport.localizedName ?? String(localized: "Workout", bundle: bundle)
        let dist = meta?.distanceMeters.map { units.formatDistance(meters: $0) } ?? "—"
        let durSec = workoutSession.duration ?? 0
        let durStr = formatDuration(Int(durSec))
        return GlanceRow(sport.uppercased(with: LanguageManager.appLocale), "\(dist) · \(durStr)", nil, nil)
    }

    func workoutInternalLoadRow(bundle: Bundle) -> GlanceRow? {
        let meta = workoutSession.workoutMetadata
        guard let trimp = meta?.luciaTRIMP else { return nil }
        let intensity = analysis().workoutIntensity
        let label: String
        let color: UIColor
        switch intensity {
        case .easy: label = String(localized: "Easy aerobic", bundle: bundle); color = config.sage
        case .moderate: label = String(localized: "Tempo / sub-threshold", bundle: bundle); color = config.sage
        case .hard: label = String(localized: "Hard / threshold", bundle: bundle); color = config.primary
        }
        return GlanceRow(String(localized: "Internal load", bundle: bundle), "TRIMP \(Int(trimp.rounded()))", label, color)
    }

    func workoutTSSRow(bundle: Bundle) -> GlanceRow? {
        let meta = workoutSession.workoutMetadata
        guard let hrTSS = meta?.hrTSS else { return nil }
        return GlanceRow("hrTSS", "\(Int(hrTSS.rounded()))", String(localized: "1hr@LTHR = 100", bundle: bundle), config.textSecondary)
    }

    func workoutHRRRow(bundle: Bundle) -> GlanceRow? {
        let meta = workoutSession.workoutMetadata
        guard let one = meta?.hrrSamples?.bestAtOneMinute else { return nil }
        let interp: String
        let color: UIColor
        if one.drop >= 18 {
            interp = String(localized: "Strong vagal recovery", bundle: bundle)
            color = config.sage
        } else if one.drop >= 12 {
            // The register's `hrr-12bpm-band` asks for the cut-off's
            // original context (Cole 1999, maximal testing) to be stated.
            interp = String(localized: "At or above 12 bpm (cut-off from maximal testing)", bundle: bundle)
            color = config.sage
        } else {
            interp = String(localized: "Below 12 bpm (cut-off from maximal testing)", bundle: bundle)
            color = config.amber
        }
        return GlanceRow(String(localized: "1-min HRR", bundle: bundle), "−\(one.drop) bpm", interp, color)
    }

    /// Delegates to the shared analysis so the PDF and the Dashboard
    /// card render identical prose.
    func loopParagraph() -> String { analysis().loopParagraph }
    func tomorrowAction() -> String { analysis().tomorrowAction }

    // MARK: - Page 2: Why Your Score Is What It Is

    func drawWhyYourScorePage(ctx: UIGraphicsPDFRendererContext, narrative: [String: String]) {
        ctx.beginPage()
        var y = config.margin
        let contentW = config.pageSize.width - 2 * config.margin

        drawText(String(localized: "WHY", bundle: LanguageManager.appBundle),
                 at: CGPoint(x: config.margin, y: y),
                 font: UIFont.systemFont(ofSize: 22, weight: .heavy),
                 color: config.textPrimary)
        y += 32
        drawDivider(at: y, width: contentW, strong: true)
        y += 16

        let bundle = LanguageManager.appBundle
        y = drawScoreSynthesis(y: y, contentW: contentW, bundle: bundle)
        y = drawContributionBars(y: y, contentW: contentW, narrative: narrative)
        drawHelpingHurting(y: y, contentW: contentW, bundle: bundle)
    }

    /// The one-line "why" — combined readiness plus what drove it.
    func drawScoreSynthesis(y: CGFloat, contentW: CGFloat, bundle: Bundle) -> CGFloat {
        let readiness = combinedReadinessScore()
        let scoreColor = readinessBandColour(readiness.value)
        let scoreRect = CGRect(x: config.margin, y: y, width: contentW, height: 60)
        scoreColor.withAlphaComponent(0.10).setFill()
        UIBezierPath(roundedRect: scoreRect, cornerRadius: 8).fill()
        drawScoreSynthesisLabels(readiness: readiness, scoreColor: scoreColor, in: scoreRect)
        return y + scoreRect.height + 22
    }

    func drawScoreSynthesisLabels(
        readiness: (value: Double, tier: String, contributions: [ScoreContribution]),
        scoreColor: UIColor,
        in scoreRect: CGRect
    ) {
        drawText(String(format: "%.1f / 10", locale: LanguageManager.appLocale, readiness.value),
                 at: CGPoint(x: scoreRect.minX + 16, y: scoreRect.minY + 12),
                 font: UIFont.systemFont(ofSize: 22, weight: .heavy),
                 color: scoreColor)
        drawText(String(localized: "Combined Readiness", bundle: LanguageManager.appBundle),
                 at: CGPoint(x: scoreRect.minX + 16, y: scoreRect.minY + 38),
                 font: UIFont.systemFont(ofSize: 9, weight: .regular),
                 color: config.textTertiary)
        drawText(readiness.tier,
                 at: CGPoint(x: scoreRect.minX + 200, y: scoreRect.minY + 22),
                 font: UIFont.systemFont(ofSize: 12, weight: .semibold),
                 color: config.textPrimary)
    }

    func drawContributionBars(y: CGFloat, contentW: CGFloat, narrative: [String: String]) -> CGFloat {
        var y = y
        let readiness = combinedReadinessScore()
        let scoreColor = readinessBandColour(readiness.value)
        // Contributions bars
        drawText(String(localized: "CONTRIBUTIONS", bundle: LanguageManager.appBundle),
                 at: CGPoint(x: config.margin, y: y),
                 font: UIFont.systemFont(ofSize: 11, weight: .bold),
                 color: config.primary)
        y += 22
        for c in readiness.contributions {
            let shown = ScoreContribution(name: c.name, score: c.score, weight: c.weight, note: narrative[c.note] ?? c.note)
            y = drawContributionBar(contribution: shown, scoreColor: scoreColor, y: y, contentW: contentW)
        }
        return y
    }

    /// One labelled bar: name on the left, filled track, value on the right.
    func drawContributionBar(contribution c: ScoreContribution, scoreColor: UIColor, y: CGFloat, contentW: CGFloat) -> CGFloat {
        var y = y
        // Label and weight
        drawText(c.name,
                 at: CGPoint(x: config.margin, y: y),
                 font: UIFont.systemFont(ofSize: 11, weight: .regular),
                 color: config.textPrimary)
        let valueLabel = String(format: "%.1f × %d%%", locale: LanguageManager.appLocale, c.score, Int(c.weight * 100))
        let valueAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: config.textSecondary
        ]
        let valueSize = (valueLabel as NSString).size(withAttributes: valueAttr)
        drawText(valueLabel,
                 at: CGPoint(x: config.margin + contentW - valueSize.width, y: y + 1),
                 font: UIFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                 color: config.textSecondary)
        y += 16
        drawContributionTrack(contribution: c, scoreColor: scoreColor, y: y, contentW: contentW)
        y += 12
        return drawContributionSubline(contribution: c, y: y, contentW: contentW)
    }

    /// The filled track itself.
    func drawContributionTrack(contribution c: ScoreContribution, scoreColor: UIColor, y: CGFloat, contentW: CGFloat) {
        // Bar
        let barH: CGFloat = 6
        let barRect = CGRect(x: config.margin, y: y, width: contentW, height: barH)
        config.divider.setFill()
        UIBezierPath(roundedRect: barRect, cornerRadius: barH / 2).fill()
        let fillW = max(0, min(1, c.score / 10)) * contentW
        let fillRect = CGRect(x: config.margin, y: y, width: fillW, height: barH)
        scoreColor.setFill()
        UIBezierPath(roundedRect: fillRect, cornerRadius: barH / 2).fill()
    }

    func drawContributionSubline(contribution c: ScoreContribution, y: CGFloat, contentW: CGFloat) -> CGFloat {
        var y = y
        // Sub-line interpretation
        drawText(c.note,
                 at: CGPoint(x: config.margin, y: y),
                 font: UIFont.systemFont(ofSize: 9, weight: .regular),
                 color: config.textTertiary)
        y += 18
        return y
    }

    func drawHelpingHurting(y: CGFloat, contentW: CGFloat, bundle: Bundle) {
        // One parameterised section rather than two near-identical blocks
        // differing only in heading, bullet colour and cap (4 vs 3), so the
        // two cannot drift apart by hand.
        var y = drawHelpingHurtingSection(
            title: String(localized: "WHAT'S HELPING", bundle: bundle),
            points: whatsHelpingPoints(), limit: 4, bulletColour: config.sage,
            y: y, contentW: contentW
        )
        if !whatsHelpingPoints().isEmpty { y += 10 }
        _ = drawHelpingHurtingSection(
            title: String(localized: "WHAT'S HURTING", bundle: bundle),
            points: whatsHurtingPoints(), limit: 3, bulletColour: config.primary,
            y: y, contentW: contentW
        )
        drawFooter(pageNumber: 2)
    }

    /// A titled run of dotted bullets; returns the y it was given when the
    /// section has nothing to say, so an empty one prints no heading.
    func drawHelpingHurtingSection(
        title: String,
        points: [String],
        limit: Int,
        bulletColour: UIColor,
        y: CGFloat,
        contentW: CGFloat
    ) -> CGFloat {
        guard !points.isEmpty else { return y }
        drawText(title,
                 at: CGPoint(x: config.margin, y: y),
                 font: UIFont.systemFont(ofSize: 11, weight: .bold),
                 color: config.primary)
        var y = y + 18
        for point in points.prefix(limit) {
            bulletColour.setFill()
            UIBezierPath(ovalIn: CGRect(x: config.margin + 2, y: y + 6, width: 5, height: 5)).fill()
            y = drawWrappedText(point,
                                at: CGPoint(x: config.margin + 16, y: y),
                                width: contentW - 16,
                                font: UIFont.systemFont(ofSize: 11, weight: .regular),
                                color: config.textPrimary,
                                lineHeight: 14) + 4
        }
        return y
    }

    // MARK: - Drawing primitives (mirror WorkoutPDFReport's helpers)

    func drawText(_ text: String, at origin: CGPoint, font: UIFont, color: UIColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        (text as NSString).draw(at: origin, withAttributes: attrs)
    }

    @discardableResult
    func drawWrappedText(_ text: String, at origin: CGPoint, width: CGFloat, font: UIFont, color: UIColor, lineHeight: CGFloat) -> CGFloat {
        let attr = wrappedAttributedText(text, font: font, color: color, lineHeight: lineHeight)
        let height = wrappedTextHeight(text, width: width, font: font, lineHeight: lineHeight)
        attr.draw(in: CGRect(origin: origin, size: CGSize(width: width, height: height)))
        return origin.y + height
    }

    /// The height `drawWrappedText` will use for `text`, so a box can be sized
    /// to its contents before it is drawn.
    func wrappedTextHeight(_ text: String, width: CGFloat, font: UIFont, lineHeight: CGFloat) -> CGFloat {
        wrappedAttributedText(text, font: font, color: .black, lineHeight: lineHeight)
            .boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            .height
    }

    private func wrappedAttributedText(_ text: String, font: UIFont, color: UIColor, lineHeight: CGFloat) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = max(0, lineHeight - font.lineHeight)
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
    }

    func drawDivider(at y: CGFloat, width: CGFloat, strong: Bool) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setStrokeColor((strong ? config.primary.withAlphaComponent(0.5) : config.divider).cgColor)
        ctx.setLineWidth(strong ? 1.2 : 0.5)
        ctx.move(to: CGPoint(x: config.margin, y: y))
        ctx.addLine(to: CGPoint(x: config.margin + width, y: y))
        ctx.strokePath()
    }

    func drawFooter(pageNumber: Int) {
        let y = config.pageSize.height - config.margin + 6
        let contentW = config.pageSize.width - 2 * config.margin
        drawDivider(at: y, width: contentW, strong: false)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        drawText(String(localized: "Emuqu · Daily Report · Page \(pageNumber) · \(iso.string(from: Date()))", bundle: LanguageManager.appBundle),
                 at: CGPoint(x: config.margin, y: y + 4),
                 font: config.captionFont,
                 color: config.textTertiary)
        // Wellness disclaimer on every page (shared externally).
        drawText(String(localized: "For wellness and fitness use only. Not a medical device; not medical advice, diagnosis, or treatment.", bundle: LanguageManager.appBundle),
                 at: CGPoint(x: config.margin, y: y + 4 + config.captionFont.lineHeight),
                 font: config.captionFont,
                 color: config.textTertiary)
    }

    func formatDuration(_ sec: Int) -> String {
        let h = sec / 3600
        let m = (sec % 3600) / 60
        let s = sec % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
