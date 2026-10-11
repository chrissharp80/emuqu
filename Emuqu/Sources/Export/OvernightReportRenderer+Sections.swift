import Foundation
import UIKit

// Overnight stats and the overnight charts, split out of
// `PDFReportGenerator+Sections.swift`. Sleep, training-load and
// vitals sections stay there.

extension OvernightReportRenderer {
    // MARK: - Overnight Stats Section

    func drawOvernightStatsSection(
        _ inputs: PDFReportGenerator.ReportInputs,
        series: RRSeries,
        yPosition: CGFloat,
        pageRect: CGRect
    ) -> CGFloat {
        // Too short a recording to say anything: no heading with nothing under it.
        guard let stats = overnightStatValues(
            series: series, flags: inputs.artifactFlags, session: inputs.session,
            sleepData: inputs.sleepData, healthKitHR: inputs.healthKitHR
        ) else { return yPosition }
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        let y = drawSectionHeading(String(localized: "Overnight Summary", bundle: LanguageManager.appBundle), yPosition: yPosition, pageRect: pageRect)
        let cardHeight: CGFloat = 100
        fillOvernightStatsCard(y: y, width: contentWidth, height: cardHeight)
        drawOvernightStatsRows(stats, y: y, boxWidth: contentWidth / 4)
        return y + cardHeight + 15
    }

    /// The rounded grey panel the two stat rows sit on.
    private func fillOvernightStatsCard(y: CGFloat, width: CGFloat, height: CGFloat) {
        let cardRect = CGRect(x: config.margins.left, y: y, width: width, height: height)
        UIColor(white: 0.97, alpha: 1.0).setFill()
        UIBezierPath(roundedRect: cardRect, cornerRadius: 8).fill()
    }

    /// Eight stats in two rows of four.
    private func drawOvernightStatsRows(_ stats: OvernightStatValues, y: CGFloat, boxWidth: CGFloat) {
        let timeFormatter = LocalizedDateFormat.formatter(template: "jmm")
        drawOvernightStatsRow1(sleepStats: stats.sleepStats, durationFormatted: stats.durationFormatted,
                               hrRange: stats.hrRange, y: y, boxWidth: boxWidth)
        drawOvernightStatsRow2(hrRange: stats.hrRange, peakRMSSD: stats.peakRMSSD,
                               peakHRVTime: stats.peakHRVTime, timeFormatter: timeFormatter,
                               y: y, boxWidth: boxWidth)
    }

    /// Everything the two stat rows need. Nil when the recording is too short
    /// to say anything (fewer than 100 beats). Clock times come from the
    /// series' wall clock, as on the Overnight screen, so a strap gap does not
    /// shift them.
    private func overnightStatValues(
        series: RRSeries,
        flags: [ArtifactFlags],
        session: HRVSession,
        sleepData: PDFReportGenerator.SleepData?,
        healthKitHR: HeartRateStats?
    ) -> OvernightStatValues? {
        let points = series.points
        guard points.count > 100, let first = points.first, let last = points.last else { return nil }
        let band = peakSearchBand(points: points, sleepData: sleepData, sessionStart: session.startDate)
        let peak = calculatePeakRMSSD(points: points, flags: flags, band: band)
        // HealthKit sleep when available, otherwise the recording-length estimate
        let sleepStats = computeOvernightSleepStats(sleepData: sleepData, durationMinutes: Int((last.t_ms - first.t_ms) / 60000))
        return OvernightStatValues(
            hrRange: overnightHRRange(points: points, series: series, healthKitHR: healthKitHR),
            peakRMSSD: peak?.rmssd, peakHRVTime: peak.map { series.wallClockTime(forTMs: $0.timeMs) },
            durationFormatted: formatRecordingDuration(series: series, first: first, last: last), sleepStats: sleepStats
        )
    }

    /// Duration, sleep, deep sleep, HR range.
    private func drawOvernightStatsRow1(
        sleepStats: OvernightSleepStats,
        durationFormatted: String,
        hrRange: OvernightHRRange?,
        y: CGFloat,
        boxWidth: CGFloat
    ) {
        let hrRangeText = hrRange.map { "\(Int($0.min))-\(Int($0.max))" } ?? reportMissingValue
        // Row 1: Duration, Sleep, Deep Sleep, HR Range
        let row1Stats: [(String, String, UIColor)] = [
            (String(localized: "Recording", bundle: LanguageManager.appBundle), durationFormatted, config.primaryColor),
            (sleepStats.sleepLabel, sleepStats.sleepFormatted, UIColor(red: 0.4, green: 0.3, blue: 0.7, alpha: 1)),
            (sleepStats.deepLabel, sleepStats.deepFormatted, UIColor(red: 0.3, green: 0.4, blue: 0.7, alpha: 1)),
            (String(localized: "HR Range", bundle: LanguageManager.appBundle), hrRangeText, config.secondaryColor)
        ]

        for (i, stat) in row1Stats.enumerated() {
            let boxX = config.margins.left + CGFloat(i) * boxWidth
            drawCompactStatBox(
                title: stat.0,
                value: stat.1,
                color: stat.2,
                rect: CGRect(x: boxX + 4, y: y + 8, width: boxWidth - 8, height: 36)
            )
        }
    }

    /// Nadir HR and peak HRV, each with the clock time it happened. A value
    /// that could not be measured prints as missing, never as a placeholder.
    private func drawOvernightStatsRow2(
        hrRange: OvernightHRRange?,
        peakRMSSD: Double?,
        peakHRVTime: Date?,
        timeFormatter: DateFormatter,
        y: CGFloat,
        boxWidth: CGFloat
    ) {
        let clock = { (date: Date?) in date.map { timeFormatter.string(from: $0) } ?? reportMissingValue }
        let peakText = peakRMSSD.map { String(format: "%.0f ms", locale: LanguageManager.appLocale, $0) } ?? reportMissingValue
        // Row 2: Nadir HR, Peak HRV with times
        let row2Stats: [(String, String, UIColor)] = [
            (String(localized: "Nadir HR", bundle: LanguageManager.appBundle), hrRange.map { "\(Int($0.min)) bpm" } ?? reportMissingValue, UIColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1)),
            (String(localized: "@ Time", bundle: LanguageManager.appBundle), clock(hrRange?.nadirTime), UIColor.darkGray),
            (String(localized: "Peak HRV", bundle: LanguageManager.appBundle), peakText, config.primaryColor),
            (String(localized: "@ Time", bundle: LanguageManager.appBundle), clock(peakHRVTime), UIColor.darkGray)
        ]

        for (i, stat) in row2Stats.enumerated() {
            let boxX = config.margins.left + CGFloat(i) * boxWidth
            drawCompactStatBox(
                title: stat.0,
                value: stat.1,
                color: stat.2,
                rect: CGRect(x: boxX + 4, y: y + 52, width: boxWidth - 8, height: 36)
            )
        }
    }

    /// Apple Watch HR is ground truth when present; otherwise derive it from RR.
    /// Nil when neither gives a heart rate, so nothing is printed as measured.
    private func overnightHRRange(
        points: [RRPoint],
        series: RRSeries,
        healthKitHR: HeartRateStats?
    ) -> OvernightHRRange? {
        if let hkStats = healthKitHR {
            debugLog("[PDF] Using HealthKit HR: nadir=\(hkStats.min), max=\(hkStats.max)")
            return OvernightHRRange(min: hkStats.min, max: hkStats.max, nadirTime: hkStats.nadirTime)
        }
        guard let hrStats = calculateRollingWindowHRStats(points: points) else {
            debugLog("[PDF] No heart rate in the recording; HR boxes print as missing", level: .warning)
            return nil
        }
        // The nadir's offset is from the first beat; read its clock time off the wall clock.
        let firstTMs = points.first?.t_ms ?? 0
        let nadirTime = hrStats.nadirOffset.map {
            series.wallClockTime(forTMs: firstTMs + Int64(($0 * 1000).rounded()))
        }
        debugLog("[PDF] Using calculated HR: nadir=\(hrStats.nadir), max=\(hrStats.max)")
        return OvernightHRRange(min: hrStats.nadir, max: hrStats.max, nadirTime: nadirTime)
    }

    // MARK: - Overnight HR Chart

    /// The overnight HR trace: a downsampled curve over a shaded band marking
    /// the window the analysis actually ran on.
    func drawOvernightHRChart(
        series: RRSeries,
        result: HRVAnalysisResult,
        yPosition: CGFloat,
        in _: UIGraphicsPDFRendererContext,
        pageRect: CGRect
    ) -> CGFloat {
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        let y = drawSectionHeading(String(localized: "Overnight Heart Rate", bundle: LanguageManager.appBundle), yPosition: yPosition, pageRect: pageRect)
        let graphHeight: CGFloat = 100
        let xAxisHeight: CGFloat = 18
        let graphRect = CGRect(x: config.margins.left, y: y, width: contentWidth, height: graphHeight)
        let emptyHeight = y + graphHeight + xAxisHeight + 15

        UIColor(white: 0.98, alpha: 1.0).setFill()
        UIBezierPath(rect: graphRect).fill()

        guard drawOvernightHRBody(series: series, result: result, in: graphRect) else { return emptyHeight }
        drawOvernightWindowLegend(in: graphRect, xAxisHeight: xAxisHeight)
        return y + graphHeight + xAxisHeight + 20
    }

    /// Everything inside the chart frame. False means there was not enough of a
    /// night to plot, and the caller should reserve the space and move on.
    private func drawOvernightHRBody(series: RRSeries, result: HRVAnalysisResult, in graphRect: CGRect) -> Bool {
        let points = series.points
        guard points.count > 10 else { return false }
        let hrData = overnightHRSamples(points: points)
        guard !hrData.isEmpty else { return false }

        let minHR = hrData.map(\.1).min() ?? 50
        let maxHR = hrData.map(\.1).max() ?? 100
        let range = max(maxHR - minHR, 10)

        drawOvernightHRGrid(in: graphRect, minHR: minHR, maxHR: maxHR, range: range)
        drawOvernightAnalysisWindow(result: result, pointCount: points.count, in: graphRect)
        drawOvernightHRCurve(hrData, pointCount: points.count, in: graphRect, minHR: minHR, range: range)
        // Border
        UIColor.lightGray.setStroke()
        UIBezierPath(rect: graphRect).stroke()
        drawOvernightHRAxisLabels(in: graphRect, minHR: minHR, maxHR: maxHR)
        return drawOvernightTimeAxis(series: series, in: graphRect)
    }

    /// The shaded band showing which stretch of the night the analysis used.
    private func drawOvernightAnalysisWindow(result: HRVAnalysisResult, pointCount: Int, in graphRect: CGRect) {
        let graphHeight = graphRect.height
        // Mark analysis window
        let windowStartPct = CGFloat(result.windowStart) / CGFloat(pointCount)
        let windowEndPct = CGFloat(result.windowEnd) / CGFloat(pointCount)
        let windowRect = CGRect(
            x: graphRect.minX + windowStartPct * graphRect.width,
            y: graphRect.minY,
            width: (windowEndPct - windowStartPct) * graphRect.width,
            height: graphHeight
        )
        config.primaryColor.withAlphaComponent(0.1).setFill()
        UIBezierPath(rect: windowRect).fill()
    }

    private func drawOvernightHRCurve(
        _ hrData: [(Int, Double)],
        pointCount: Int,
        in graphRect: CGRect,
        minHR: Double,
        range: Double
    ) {
        let path = overnightHRPath(hrData, pointCount: pointCount, in: graphRect, minHR: minHR, range: range)
        config.accentColor.setStroke()
        path.lineWidth = 1.0
        path.stroke()
    }

    /// Shared styling for every label hung off this chart.
    private var overnightChartLabelAttributes: [NSAttributedString.Key: Any] {
        [.font: config.captionFont, .foregroundColor: UIColor.gray]
    }

    private func drawOvernightHRAxisLabels(in graphRect: CGRect, minHR: Double, maxHR: Double) {
        let labelAttributes = overnightChartLabelAttributes
        String(format: "%.0f", locale: LanguageManager.appLocale, maxHR).pdfDraw(at: CGPoint(x: graphRect.maxX + 3, y: graphRect.minY), withAttributes: labelAttributes)
        String(format: "%.0f", locale: LanguageManager.appLocale, minHR).pdfDraw(at: CGPoint(x: graphRect.maxX + 3, y: graphRect.maxY - 10), withAttributes: labelAttributes)
        String(localized: "bpm", bundle: LanguageManager.appBundle).pdfDraw(at: CGPoint(x: graphRect.maxX + 3, y: graphRect.midY - 5), withAttributes: labelAttributes)
    }

    /// Five evenly-spaced clock times under the chart. The curve places beat
    /// k at k / count of the width, so each label reads the beat drawn above
    /// it, on the series' wall clock. Returns false for an empty series.
    private func drawOvernightTimeAxis(series: RRSeries, in graphRect: CGRect) -> Bool {
        let points = series.points
        let xAxisY = graphRect.maxY + 3
        guard !points.isEmpty else { return false }
        let timeFormatter = LocalizedDateFormat.formatter(template: "jmm")
        for i in 0 ..< 5 {
            let fraction = CGFloat(i) / 4
            let index = min(points.count - 1, Int(fraction * CGFloat(points.count)))
            let actualTime = series.wallClockTime(forTMs: points[index].t_ms)
            drawOvernightTimeLabel(timeFormatter.string(from: actualTime),
                                   fraction: fraction, index: i, of: 5,
                                   in: graphRect, y: xAxisY)
        }
        return true
    }

    /// First label flushes left, last flushes right, the rest centre on their
    /// tick — otherwise the outer two hang off the chart.
    private func drawOvernightTimeLabel(
        _ timeStr: String,
        fraction: CGFloat,
        index: Int,
        of labelCount: Int,
        in graphRect: CGRect,
        y xAxisY: CGFloat
    ) {
        let labelAttributes = overnightChartLabelAttributes
        let labelSize = timeStr.size(withAttributes: labelAttributes)
        let labelX: CGFloat
        if index == 0 {
            labelX = graphRect.minX
        } else if index == labelCount - 1 {
            labelX = graphRect.maxX - labelSize.width
        } else {
            labelX = graphRect.minX + fraction * graphRect.width - labelSize.width / 2
        }
        timeStr.pdfDraw(at: CGPoint(x: labelX, y: xAxisY), withAttributes: labelAttributes)
    }

    private func drawOvernightWindowLegend(in graphRect: CGRect, xAxisHeight: CGFloat) {
        let labelAttributes = overnightChartLabelAttributes
        // Legend for analysis window (moved down to account for x-axis labels)
        let legendY = graphRect.maxY + xAxisHeight + 2
        config.primaryColor.withAlphaComponent(0.3).setFill()
        UIBezierPath(rect: CGRect(x: config.margins.left, y: legendY, width: 12, height: 8)).fill()
        String(localized: "Analysis Window", bundle: LanguageManager.appBundle).pdfDraw(at: CGPoint(x: config.margins.left + 16, y: legendY - 2), withAttributes: labelAttributes)
    }

    // MARK: - Tags & Notes Section

    func drawTagsAndNotesSection(
        session: HRVSession,
        yPosition: CGFloat,
        in _: UIGraphicsPDFRendererContext,
        pageRect: CGRect
    ) -> CGFloat {
        var y = drawSectionHeading(String(localized: "Tags & Notes", bundle: LanguageManager.appBundle), yPosition: yPosition, pageRect: pageRect)
        y = drawSessionTags(session: session, y: y, pageRect: pageRect)
        y = drawSessionNotes(session: session, y: y, pageRect: pageRect)
        return y
    }

    /// Tag pills, wrapped across as many rows as they need.
    private func drawSessionTags(session: HRVSession, y: CGFloat, pageRect: CGRect) -> CGFloat {
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        var y = y
        // Tags
        if !session.tags.isEmpty {
            var tagX = config.margins.left
            let tagHeight: CGFloat = 18
            let tagSpacing: CGFloat = 6
            for tag in session.tags {
                (tagX, y) = drawTagPill(tag: tag, x: tagX, y: y, tagHeight: tagHeight, tagSpacing: tagSpacing, contentWidth: contentWidth)
            }
            y += tagHeight + 8
        }
        return y
    }

    /// One pill; wraps to the next row when it would overflow. Returns the pen
    /// position for the next pill.
    private func drawTagPill(tag: ReadingTag, x: CGFloat, y: CGFloat, tagHeight: CGFloat, tagSpacing: CGFloat, contentWidth: CGFloat) -> (CGFloat, CGFloat) {
        var tagX = x
        var y = y
        let tagText = tag.name
        let tagAttributes: [NSAttributedString.Key: Any] = [
            .font: config.captionFont,
            .foregroundColor: UIColor.darkGray
        ]
        let tagSize = tagText.size(withAttributes: tagAttributes)
        let tagWidth = tagSize.width + 16
        if tagX + tagWidth > config.margins.left + contentWidth {
            tagX = config.margins.left
            y += tagHeight + 4
        }
        strokeTagPill(tagText, attributes: tagAttributes, x: tagX, y: y, width: tagWidth, height: tagHeight)
        return (tagX + tagWidth + tagSpacing, y)
    }

    /// The whole note, as tall as it wraps to, down to the page's bottom
    /// limit at most (the caller makes room first; see `sessionNotesHeight`).
    private func drawSessionNotes(session: HRVSession, y: CGFloat, pageRect: CGRect) -> CGFloat {
        guard let notes = session.notes, !notes.isEmpty else { return y }
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        let bottomLimit = pageRect.height - config.margins.bottom - 20
        let height = min(sessionNotesHeight(session: session, pageRect: pageRect), max(0, bottomLimit - y))
        sessionNotesAttributed(notes).pdfDraw(in: CGRect(x: config.margins.left, y: y, width: contentWidth, height: height))
        return y + height + 10
    }

    /// Height the session's notes wrap to at the content width; 0 without notes.
    func sessionNotesHeight(session: HRVSession, pageRect: CGRect) -> CGFloat {
        guard let notes = session.notes, !notes.isEmpty else { return 0 }
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        return ceil(sessionNotesAttributed(notes).boundingRect(
            with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height)
    }

    private func sessionNotesAttributed(_ notes: String) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: notes, attributes: [
            .font: config.bodyFont,
            .foregroundColor: UIColor.darkGray,
            .paragraphStyle: paragraphStyle
        ])
    }

    /// Colour for a 0-100 score: the canonical `ScoreVerdict` ladder
    /// (90/75/60/45/30) and its palette, so the PDF colours a score the way
    /// the app does.
    func diagnosticColorForScore(_ score: Double) -> UIColor {
        UIColor(ScoreVerdict(score: score).color)
    }

    /// Overnight HR nadir, max and the nadir's offset in seconds from the
    /// first beat. Uses the per-beat HR the strap recorded (30-200 bpm only)
    /// when any point carries one; otherwise, or when none of those is in
    /// range, derives HR from RR over rolling ~10-second windows. Nil when
    /// neither yields a heart rate.
    func calculateRollingWindowHRStats(points: [RRPoint]) -> (nadir: Double, max: Double, nadirOffset: TimeInterval?)? {
        guard !points.isEmpty else { return nil }
        if points.contains(where: { $0.hr != nil }), let stored = storedHRStats(points: points) {
            return stored
        }
        return rollingWindowHRStats(points: points)
    }

    // MARK: - Overnight Stats Helpers

    /// Everything the two overnight stat rows display. A struct rather than a
    /// seven-member tuple — the fields are read by name at every use site.
    struct OvernightStatValues {
        /// Nil when no heart rate could be measured or derived.
        let hrRange: OvernightHRRange?
        /// Nil when no window held enough clean beats to measure RMSSD.
        let peakRMSSD: Double?
        let peakHRVTime: Date?
        let durationFormatted: String
        let sleepStats: OvernightSleepStats
    }

    /// The night's lowest and highest heart rate and when the lowest happened
    /// (nil when that moment is unknown).
    struct OvernightHRRange {
        let min: Double
        let max: Double
        let nadirTime: Date?
    }

    /// Result of computing overnight sleep stats for display
    struct OvernightSleepStats {
        let sleepMinutes: Int
        /// Nil when no sleep source measured deep sleep.
        let deepSleepMinutes: Int?
        let sleepFormatted: String
        let deepFormatted: String
        let sleepLabel: String
        let deepLabel: String
    }

    /// Compute sleep stats from HealthKit data or estimate from recording duration
    func computeOvernightSleepStats(sleepData: PDFReportGenerator.SleepData?, durationMinutes: Int) -> OvernightSleepStats {
        if let stats = sleepStatsFromHealthKitTotal(sleepData) { return stats }
        if let stats = sleepStatsFromHealthKitBoundaries(sleepData) { return stats }
        return estimatedSleepStats(durationMinutes: durationMinutes)
    }

    /// Most accurate: HealthKit reported an actual asleep total.
    private func sleepStatsFromHealthKitTotal(_ sleepData: PDFReportGenerator.SleepData?) -> OvernightSleepStats? {
        if let hkSleep = sleepData, hkSleep.totalSleepMinutes > 0 {
            let sleepMinutes = hkSleep.totalSleepMinutes
            let deepSleepMinutes = hkSleep.deepSleepMinutes
            return OvernightSleepStats(
                sleepMinutes: sleepMinutes,
                deepSleepMinutes: deepSleepMinutes,
                sleepFormatted: formatMinutes(sleepMinutes),
                deepFormatted: hkSleep.deepSleepFormatted ?? reportMissingValue,
                sleepLabel: String(localized: "Time Asleep", bundle: LanguageManager.appBundle),
                deepLabel: String(localized: "Deep Sleep", bundle: LanguageManager.appBundle)
            )
        }
        return nil
    }

    /// Less accurate: only sleep boundaries, so this includes awake periods.
    private func sleepStatsFromHealthKitBoundaries(_ sleepData: PDFReportGenerator.SleepData?) -> OvernightSleepStats? {
        if let hkSleep = sleepData,
           let sleepStart = hkSleep.sleepStart,
           let sleepEnd = hkSleep.sleepEnd {
            let sleepMinutes = Int(sleepEnd.timeIntervalSince(sleepStart) / 60)
            let deepSleepMinutes = hkSleep.deepSleepMinutes
            return OvernightSleepStats(
                sleepMinutes: sleepMinutes,
                deepSleepMinutes: deepSleepMinutes,
                sleepFormatted: formatMinutes(sleepMinutes),
                deepFormatted: hkSleep.deepSleepFormatted ?? reportMissingValue,
                // A span, awake time included, so it is not called time asleep.
                sleepLabel: String(localized: "In Bed", bundle: LanguageManager.appBundle),
                deepLabel: String(localized: "Deep Sleep", bundle: LanguageManager.appBundle)
            )
        }
        return nil
    }

    /// No HealthKit at all: time asleep is the recording-length estimate the
    /// Overnight screen shows (`RecordingSleepEstimate`), labelled "Est." so
    /// the reader knows. Deep sleep is printed as missing, never as a share
    /// of the estimate.
    private func estimatedSleepStats(durationMinutes: Int) -> OvernightSleepStats {
        let estimate = RecordingSleepEstimate(recordingMinutes: durationMinutes)
        return OvernightSleepStats(
            sleepMinutes: estimate.asleepMinutes,
            deepSleepMinutes: nil,
            sleepFormatted: formatMinutes(estimate.asleepMinutes),
            deepFormatted: reportMissingValue,
            sleepLabel: String(localized: "Est. Sleep", bundle: LanguageManager.appBundle),
            deepLabel: String(localized: "Deep Sleep", bundle: LanguageManager.appBundle)
        )
    }

    /// Format minutes as "Xh Ym" or "Ym", in the app's language.
    func formatMinutes(_ totalMinutes: Int) -> String {
        reportHoursMinutes(totalMinutes)
    }

    /// Result of peak RMSSD calculation
    struct PeakRMSSDResult {
        let rmssd: Double
        /// t_ms of the beat the peak window is centred on.
        let timeMs: Int64
    }

    /// The 30-70% slice of the HealthKit sleep envelope, or of the whole
    /// recording when there are no sleep boundaries, in the series' t_ms —
    /// the band the Overnight screen searches (`OvernightChartsView.searchBand`).
    /// An envelope that ends before it starts gives an empty band.
    func peakSearchBand(points: [RRPoint], sleepData: PDFReportGenerator.SleepData?, sessionStart: Date) -> (start: Int64, end: Int64) {
        let durationMs = (points.last?.t_ms ?? 0) - (points.first?.t_ms ?? 0)
        var boundaryStart: Int64 = 0
        var boundaryEnd = durationMs
        if let sleepStart = sleepData?.sleepStart, let sleepEnd = sleepData?.sleepEnd {
            boundaryStart = max(0, MillisecondOffset.between(sleepStart, and: sessionStart, fallback: 0))
            boundaryEnd = min(durationMs, MillisecondOffset.between(sleepEnd, and: sessionStart, fallback: 0))
        }
        let span = Double(boundaryEnd - boundaryStart)
        return (boundaryStart + Int64(span * 0.30), boundaryStart + Int64(span * 0.70))
    }

    /// Peak rolling RMSSD inside `band`, falling back to the whole recording.
    /// Nil when no window anywhere held enough clean beats to measure.
    func calculatePeakRMSSD(points: [RRPoint], flags: [ArtifactFlags], band: (start: Int64, end: Int64)) -> PeakRMSSDResult? {
        guard !points.isEmpty else { return nil }
        var peakRMSSD = 0.0
        var peakHRVIndex = 0
        // First pass: the sleep band, where a sleeper is most likely settled.
        scanPeak(points: points, flags: flags, bandStart: band.start, bandEnd: band.end,
                 peakRMSSD: &peakRMSSD, peakIndex: &peakHRVIndex)
        if peakRMSSD == 0.0 {
            // Fallback: scan the entire recording.
            scanPeak(points: points, flags: flags, bandStart: nil, bandEnd: nil,
                     peakRMSSD: &peakRMSSD, peakIndex: &peakHRVIndex)
        }
        guard peakRMSSD > 0 else { return nil }
        return PeakRMSSDResult(rmssd: peakRMSSD, timeMs: points[min(peakHRVIndex, points.count - 1)].t_ms)
    }

    /// Window and step are fixed at ~5 min / 30 beats to match OvernightChartsView.
    private func scanPeak(
        points: [RRPoint],
        flags: [ArtifactFlags],
        bandStart: Int64?,
        bandEnd: Int64?,
        peakRMSSD: inout Double,
        peakIndex: inout Int
    ) {
        scanForPeakRMSSD(
            points: points, flags: flags,
            window: PeakScanWindow(size: 300, step: 30, bandStart: bandStart, bandEnd: bandEnd),
            peakRMSSD: &peakRMSSD, peakIndex: &peakIndex
        )
    }

    /// Sliding-window geometry for the peak scan, plus the optional time band
    /// it is restricted to.
    struct PeakScanWindow {
        let size: Int
        let step: Int
        let bandStart: Int64?
        let bandEnd: Int64?
    }

    /// Scan points for peak RMSSD, optionally restricted to a time band
    func scanForPeakRMSSD(
        points: [RRPoint],
        flags: [ArtifactFlags],
        window: PeakScanWindow,
        peakRMSSD: inout Double,
        peakIndex: inout Int
    ) {
        var i = 0
        while i <= points.count - 1 {
            if inScanBand(points[i].t_ms, window: window),
               let rmssd = windowRMSSD(points: points, flags: flags, from: max(0, i - window.size / 2),
                                       to: min(points.count, i + window.size / 2)),
               rmssd > peakRMSSD {
                peakRMSSD = rmssd
                peakIndex = i
            }
            i = advanceScanIndex(i, pointCount: points.count, stepSize: window.step)
        }
    }

    /// Advance scan index, snapping to the last element if the next step would overshoot
    func advanceScanIndex(_ i: Int, pointCount: Int, stepSize: Int) -> Int {
        if i < pointCount - 1, i + stepSize > pointCount - 1 {
            return pointCount - 1
        }
        return i + stepSize
    }

    /// RMSSD for a window; see `TimeDomainAnalyzer.peakScanRMSSD`, which the
    /// in-app overnight chart uses too.
    func windowRMSSD(points: [RRPoint], flags: [ArtifactFlags], from windowStart: Int, to windowEnd: Int) -> Double? {
        TimeDomainAnalyzer.peakScanRMSSD(points: points, flags: flags, range: windowStart ..< max(windowStart, windowEnd))
    }
}

// MARK: - File-scope helpers
//
// Kept outside the type. Each touches no instance state — including the
// computed properties — and calls nothing inside it, so none is a method
// in anything but placement. `private` at file scope is fileprivate, so
// every call site in this file resolves.
//
// This is what `check_aggregate_type_size.sh` measures: a type is the sum of
// its parts across every file, so code that does not need the type inflates
// that number without making the type do more.

/// "7h 42m" / "42m" for the recording span, first to last beat on the
/// series' wall clock, so a strap disconnect gap counts as recorded time.
private func formatRecordingDuration(series: RRSeries, first: RRPoint, last: RRPoint) -> String {
    let seconds = series.wallClockTime(forTMs: last.t_ms).timeIntervalSince(series.wallClockTime(forTMs: first.t_ms))
    return reportHoursMinutes(Int(max(0, seconds) / 60))
}

/// About 500 beats spread evenly over the night (every count/500-th beat,
/// at least every beat), artifacts dropped, converted to bpm.
private func overnightHRSamples(points: [RRPoint]) -> [(Int, Double)] {
    // Compute HR values with downsampling for display
    // Filter out artifact values (RR < 300ms or > 2000ms)
    let sampleStep = max(1, points.count / 500)
    var hrData: [(Int, Double)] = []
    for i in stride(from: 0, to: points.count, by: sampleStep) {
        let rr = points[i].rr_ms
        guard rr >= 300, rr <= 2000 else { continue }
        let hr = 60000.0 / Double(rr)
        hrData.append((i, hr))
    }
    return hrData
}

/// The vertical position of `hr` in the chart. The grid and the trace share
/// it, so a grid line sits at the bpm the trace reads there.
private func overnightHRY(_ hr: Double, in graphRect: CGRect, minHR: Double, range: Double) -> CGFloat {
    let normalized = (hr - minHR) / range
    return graphRect.maxY - CGFloat(normalized) * graphRect.height * 0.9 - 5
}

/// Grid lines every 10 bpm, starting at the first multiple of ten at or
/// above the lowest reading so none falls below the chart.
private func drawOvernightHRGrid(in graphRect: CGRect, minHR: Double, maxHR: Double, range: Double) {
    UIColor(white: 0.9, alpha: 1.0).setStroke()
    for hrLine in stride(from: Int((minHR / 10).rounded(.up)) * 10, through: Int(maxHR), by: 10) {
        let lineY = overnightHRY(Double(hrLine), in: graphRect, minHR: minHR, range: range)
        let linePath = UIBezierPath()
        linePath.move(to: CGPoint(x: graphRect.minX, y: lineY))
        linePath.addLine(to: CGPoint(x: graphRect.maxX, y: lineY))
        linePath.lineWidth = 0.5
        linePath.stroke()
    }
}

private func overnightHRPath(
    _ hrData: [(Int, Double)],
    pointCount: Int,
    in graphRect: CGRect,
    minHR: Double,
    range: Double
) -> UIBezierPath {
    let path = UIBezierPath()
    var first = true
    let xScale = graphRect.width / CGFloat(pointCount)

    for (idx, hr) in hrData {
        let x = graphRect.minX + CGFloat(idx) * xScale
        let yPos = overnightHRY(hr, in: graphRect, minHR: minHR, range: range)

        if first {
            path.move(to: CGPoint(x: x, y: yPos))
            first = false
        } else {
            path.addLine(to: CGPoint(x: x, y: yPos))
        }
    }
    return path
}

private func strokeTagPill(_ text: String, attributes: [NSAttributedString.Key: Any], x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
    UIColor(white: 0.9, alpha: 1.0).setFill()
    UIBezierPath(roundedRect: CGRect(x: x, y: y, width: width, height: height), cornerRadius: 9).fill()
    text.pdfDraw(at: CGPoint(x: x + 8, y: y + 3), withAttributes: attributes)
}

/// HR as recorded during streaming.
/// Nil when no stored value is in 30-200 bpm.
private func storedHRStats(points: [RRPoint]) -> (nadir: Double, max: Double, nadirOffset: TimeInterval?)? {
    let hrValues = points.compactMap { point -> Double? in
        guard let hr = point.hr, hr >= 30, hr <= 200 else { return nil }
        return Double(hr)
    }
    guard let nadir = hrValues.min(), let peak = hrValues.max() else { return nil }
    let index = points.firstIndex { Double($0.hr ?? 0) == nadir }
    return (nadir: nadir, max: peak, nadirOffset: nadirOffset(at: index, in: points))
}

/// Seconds from the recording's first beat to the nadir; the caller adds it
/// to the recording start.
private func nadirOffset(at index: Int?, in points: [RRPoint]) -> TimeInterval? {
    guard let index else { return nil }
    let offsetMs = points[index].t_ms - (points.first?.t_ms ?? 0)
    return Double(offsetMs) / 1000.0
}

/// No stored HR — derive it from RR over rolling 10-second windows. Nil
/// when no window held enough clean beats.
private func rollingWindowHRStats(points: [RRPoint]) -> (nadir: Double, max: Double, nadirOffset: TimeInterval?)? {
    let hrSamples = rollingHRSamples(points: points)
    guard let nadir = hrSamples.map(\.hr).min(), let peak = hrSamples.map(\.hr).max() else { return nil }
    let index = hrSamples.first { $0.hr == nadir }?.index
    return (nadir: nadir, max: peak, nadirOffset: nadirOffset(at: index, in: points))
}

/// One HR sample per ~10-second window, a new window every 5 beats.
private func rollingHRSamples(points: [RRPoint]) -> [(hr: Double, index: Int)] {
    var hrSamples: [(hr: Double, index: Int)] = []
    var i = 0
    while i < points.count {
        let (sample, next) = rollingHRWindow(points: points, from: i)
        if let sample { hrSamples.append((hr: sample, index: i)) }
        // Advance by 5 beats, or to where the window ended if that is sooner
        i = next > i + 5 ? i + 5 : next
    }
    return hrSamples
}

/// HR over one ~10-second window starting at `start`, plus the index the
/// window ended on. Nil when the window held too few clean beats to mean
/// anything, or the derived rate fell outside 30-200 bpm.
private func rollingHRWindow(points: [RRPoint], from start: Int) -> (Double?, Int) {
    let windowDurationMs: Int64 = 10000 // 10 seconds
    // Collect beats for next 10-second window
    var windowBeats: [Int] = []
    var windowDurationActual: Int64 = 0
    var j = start

    while j < points.count, windowDurationActual < windowDurationMs {
        let rr = points[j].rr_ms
        if rr >= 300, rr <= 2000 { // Sanity filter
            windowBeats.append(rr)
            windowDurationActual += Int64(rr)
        }
        j += 1
    }

    guard windowBeats.count >= 5, windowDurationActual > 0 else { return (nil, j) }
    // HR = (number of beats / duration in ms) * 60000
    let windowHR = (Double(windowBeats.count) / Double(windowDurationActual)) * 60000.0
    guard windowHR >= 30, windowHR <= 200 else { return (nil, j) }
    return (windowHR, j)
}

/// A window with no band scans everything; a banded one only its own hours.
private func inScanBand(_ midTimeMs: Int64, window: OvernightReportRenderer.PeakScanWindow) -> Bool {
    guard let start = window.bandStart, let end = window.bandEnd else { return true }
    return midTimeMs >= start && midTimeMs <= end
}
