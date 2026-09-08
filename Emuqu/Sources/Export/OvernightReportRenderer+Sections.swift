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
        let stats = overnightStatValues(
            series: series, flags: inputs.artifactFlags, session: inputs.session,
            sleepData: inputs.sleepData, healthKitHR: inputs.healthKitHR
        )
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        let y = drawSectionHeading(String(localized: "Overnight Summary", bundle: LanguageManager.appBundle), yPosition: yPosition, pageRect: pageRect)
        guard let stats else { return y }
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
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        drawOvernightStatsRow1(sleepStats: stats.sleepStats, durationFormatted: stats.durationFormatted,
                               minHR: stats.minHR, maxHR: stats.maxHR, y: y, boxWidth: boxWidth)
        drawOvernightStatsRow2(minHR: stats.minHR, nadirTime: stats.nadirTime, peakRMSSD: stats.peakRMSSD,
                               peakHRVTime: stats.peakHRVTime, timeFormatter: timeFormatter,
                               y: y, boxWidth: boxWidth)
    }

    /// Everything the two stat rows need. Nil when the recording is too short
    /// to say anything (fewer than 100 beats).
    private func overnightStatValues(
        series: RRSeries,
        flags: [ArtifactFlags],
        session: HRVSession,
        sleepData: PDFReportGenerator.SleepData?,
        healthKitHR: HeartRateStats?
    ) -> OvernightStatValues? {
        // Calculate overnight stats from RR data
        let points = series.points
        guard points.count > 100 else { return nil }
        let (minHR, maxHR, nadirTime) = overnightHRRange(points: points, session: session, healthKitHR: healthKitHR)
        let startTimeMs = points.first?.t_ms ?? 0
        // Calculate peak HRV using rolling RMSSD within 30-70% of recording
        let peakResult = calculatePeakRMSSD(points: points, flags: flags, startTimeMs: startTimeMs)
        let peakRMSSD = peakResult.rmssd
        let peakHRVTime = session.startDate.addingTimeInterval(Double(peakResult.offsetMs) / 1000.0)
        let durationFormatted = formatRecordingDuration(points: points, startTimeMs: startTimeMs)
        let durationMinutes = Int(((points.last?.t_ms ?? 0) - startTimeMs) / 60000)
        // Use actual HealthKit sleep data when available, otherwise estimate
        let sleepStats = computeOvernightSleepStats(sleepData: sleepData, durationMinutes: durationMinutes)
        return OvernightStatValues(
            minHR: minHR, maxHR: maxHR, nadirTime: nadirTime,
            peakRMSSD: peakRMSSD, peakHRVTime: peakHRVTime,
            durationFormatted: durationFormatted, sleepStats: sleepStats
        )
    }

    /// Duration, sleep, deep sleep, HR range.
    private func drawOvernightStatsRow1(
        sleepStats: OvernightSleepStats,
        durationFormatted: String,
        minHR: Double,
        maxHR: Double,
        y: CGFloat,
        boxWidth: CGFloat
    ) {
        // Row 1: Duration, Sleep, Deep Sleep, HR Range
        let row1Stats: [(String, String, UIColor)] = [
            (String(localized: "Recording", bundle: LanguageManager.appBundle), durationFormatted, config.primaryColor),
            (sleepStats.sleepLabel, sleepStats.sleepFormatted, UIColor(red: 0.4, green: 0.3, blue: 0.7, alpha: 1)),
            (sleepStats.deepLabel, sleepStats.deepFormatted, UIColor(red: 0.3, green: 0.4, blue: 0.7, alpha: 1)),
            (String(localized: "HR Range", bundle: LanguageManager.appBundle), "\(Int(minHR))-\(Int(maxHR))", config.secondaryColor)
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

    /// Nadir HR and peak HRV, each with the clock time it happened.
    private func drawOvernightStatsRow2(
        minHR: Double,
        nadirTime: Date,
        peakRMSSD: Double,
        peakHRVTime: Date,
        timeFormatter: DateFormatter,
        y: CGFloat,
        boxWidth: CGFloat
    ) {
        // Row 2: Nadir HR, Peak HRV with times
        let row2Stats: [(String, String, UIColor)] = [
            (String(localized: "Nadir HR", bundle: LanguageManager.appBundle), "\(Int(minHR)) bpm", UIColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1)),
            (String(localized: "@ Time", bundle: LanguageManager.appBundle), timeFormatter.string(from: nadirTime), UIColor.darkGray),
            (String(localized: "Peak HRV", bundle: LanguageManager.appBundle), String(format: "%.0f ms", locale: .current, peakRMSSD), config.primaryColor),
            (String(localized: "@ Time", bundle: LanguageManager.appBundle), timeFormatter.string(from: peakHRVTime), UIColor.darkGray)
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
    private func overnightHRRange(
        points: [RRPoint],
        session: HRVSession,
        healthKitHR: HeartRateStats?
    ) -> (min: Double, max: Double, nadirTime: Date) {
        let minHR: Double
        let maxHR: Double
        let nadirTime: Date

        if let hkStats = healthKitHR {
            // Use HealthKit HR (Apple Watch samples - ground truth)
            minHR = hkStats.min
            maxHR = hkStats.max
            nadirTime = hkStats.nadirTime
            debugLog("[PDF] Using HealthKit HR: nadir=\(minHR), max=\(maxHR)")
        } else {
            // Fall back to calculated HR from RR intervals
            let hrStats = calculateRollingWindowHRStats(points: points)
            minHR = hrStats.nadir
            maxHR = hrStats.max
            nadirTime = hrStats.nadirTime ?? session.startDate
            debugLog("[PDF] Using calculated HR: nadir=\(minHR), max=\(maxHR)")
        }

        return (minHR, maxHR, nadirTime)
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
        String(format: "%.0f", locale: .current, maxHR).draw(at: CGPoint(x: graphRect.maxX + 3, y: graphRect.minY), withAttributes: labelAttributes)
        String(format: "%.0f", locale: .current, minHR).draw(at: CGPoint(x: graphRect.maxX + 3, y: graphRect.maxY - 10), withAttributes: labelAttributes)
        "bpm".draw(at: CGPoint(x: graphRect.maxX + 3, y: graphRect.midY - 5), withAttributes: labelAttributes)
    }

    /// Five evenly-spaced clock times under the chart. Returns false when the
    /// series has no endpoints to interpolate between.
    private func drawOvernightTimeAxis(series: RRSeries, in graphRect: CGRect) -> Bool {
        let points = series.points
        // X-axis time labels showing actual clock times
        let xAxisY = graphRect.maxY + 3
        guard let firstPoint = points.first, let lastPoint = points.last else { return false }
        let startTimeMs = firstPoint.t_ms
        let endTimeMs = lastPoint.t_ms
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        for i in 0 ..< 5 {
            let fraction = CGFloat(i) / 4
            let relativeMs = startTimeMs + Int64(Double(endTimeMs - startTimeMs) * Double(fraction))
            let actualTime = series.startDate.addingTimeInterval(Double(relativeMs) / 1000.0)
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
        timeStr.draw(at: CGPoint(x: labelX, y: xAxisY), withAttributes: labelAttributes)
    }

    private func drawOvernightWindowLegend(in graphRect: CGRect, xAxisHeight: CGFloat) {
        let labelAttributes = overnightChartLabelAttributes
        // Legend for analysis window (moved down to account for x-axis labels)
        let legendY = graphRect.maxY + xAxisHeight + 2
        config.primaryColor.withAlphaComponent(0.3).setFill()
        UIBezierPath(rect: CGRect(x: config.margins.left, y: legendY, width: 12, height: 8)).fill()
        String(localized: "Analysis Window", bundle: LanguageManager.appBundle).draw(at: CGPoint(x: config.margins.left + 16, y: legendY - 2), withAttributes: labelAttributes)
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

    private func drawSessionNotes(session: HRVSession, y: CGFloat, pageRect: CGRect) -> CGFloat {
        guard let notes = session.notes, !notes.isEmpty else { return y }
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        let attributedNotes = sessionNotesAttributed(notes)
        attributedNotes.draw(in: CGRect(x: config.margins.left, y: y, width: contentWidth, height: 60))
        let boundingRect = attributedNotes.boundingRect(
            with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return y + min(boundingRect.height + 10, 70)
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

    /// Convert session data to SleepInput for the generator
    func computeSleepInputFromSession(_ session: HRVSession) -> AnalysisSleepInput {
        guard let series = session.rrSeries, let firstPoint = series.points.first else { return .empty }
        let points = series.points
        let recordingDurationMs = (points.last?.t_ms ?? 0) - firstPoint.t_ms
        let recordingDurationMinutes = Int(recordingDurationMs / 60000)
        let (sleepMinutes, deepSleepMinutes, awakeMinutes) = estimatedSleepSplit(recordingDurationMinutes)
        let sleepEfficiency = recordingDurationMinutes > 0 ? Double(sleepMinutes) / Double(recordingDurationMinutes) * 100 : 0
        return AnalysisSleepInput(
            totalSleepMinutes: sleepMinutes,
            inBedMinutes: recordingDurationMinutes,
            deepSleepMinutes: deepSleepMinutes,
            remSleepMinutes: nil,
            awakeMinutes: awakeMinutes,
            sleepEfficiency: sleepEfficiency
        )
    }

    /// Get color for diagnostic score
    func diagnosticColorForScore(_ score: Double) -> UIColor {
        if score >= 80 { return config.secondaryColor }
        if score >= 60 { return config.primaryColor }
        if score >= 40 { return UIColor.orange }
        return config.accentColor
    }

    /// Calculate HR statistics using rolling 10-second windows
    /// Returns proper nadir, max, and nadir timestamp
    func calculateRollingWindowHRStats(points: [RRPoint]) -> (nadir: Double, max: Double, nadirTime: Date?) {
        guard !points.isEmpty else {
            return (nadir: 50, max: 100, nadirTime: nil)
        }
        // Prefer HR the strap already recorded; only derive it when absent.
        if points.contains(where: { $0.hr != nil }) {
            return storedHRStats(points: points)
        }
        return rollingWindowHRStats(points: points)
    }

    // MARK: - Overnight Stats Helpers

    /// Everything the two overnight stat rows display. A struct rather than a
    /// seven-member tuple — the fields are read by name at every use site.
    struct OvernightStatValues {
        let minHR: Double
        let maxHR: Double
        let nadirTime: Date
        let peakRMSSD: Double
        let peakHRVTime: Date
        let durationFormatted: String
        let sleepStats: OvernightSleepStats
    }

    /// Result of computing overnight sleep stats for display
    struct OvernightSleepStats {
        let sleepMinutes: Int
        let deepSleepMinutes: Int
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
        // Case 1: HealthKit total sleep available
        if let hkSleep = sleepData, hkSleep.totalSleepMinutes > 0 {
            let sleepMinutes = hkSleep.totalSleepMinutes
            let deepSleepMinutes = hkSleep.deepSleepMinutes ?? 0
            return OvernightSleepStats(
                sleepMinutes: sleepMinutes,
                deepSleepMinutes: deepSleepMinutes,
                sleepFormatted: formatMinutes(sleepMinutes),
                deepFormatted: hkSleep.deepSleepFormatted ?? "N/A",
                sleepLabel: String(localized: "Time Asleep", bundle: LanguageManager.appBundle),
                deepLabel: String(localized: "Deep Sleep", bundle: LanguageManager.appBundle)
            )
        }
        return nil
    }

    /// Less accurate: only sleep boundaries, so this includes awake periods.
    private func sleepStatsFromHealthKitBoundaries(_ sleepData: PDFReportGenerator.SleepData?) -> OvernightSleepStats? {
        // Case 2: HealthKit boundaries available (less accurate — includes awake periods)
        if let hkSleep = sleepData,
           let sleepStart = hkSleep.sleepStart,
           let sleepEnd = hkSleep.sleepEnd {
            let sleepMinutes = Int(sleepEnd.timeIntervalSince(sleepStart) / 60)
            let deepSleepMinutes = hkSleep.deepSleepMinutes ?? 0
            return OvernightSleepStats(
                sleepMinutes: sleepMinutes,
                deepSleepMinutes: deepSleepMinutes,
                sleepFormatted: formatMinutes(sleepMinutes),
                deepFormatted: hkSleep.deepSleepFormatted ?? "N/A",
                sleepLabel: String(localized: "Time Asleep", bundle: LanguageManager.appBundle),
                deepLabel: String(localized: "Deep Sleep", bundle: LanguageManager.appBundle)
            )
        }
        return nil
    }

    /// No HealthKit at all — labelled "Est." so the reader knows.
    private func estimatedSleepStats(durationMinutes: Int) -> OvernightSleepStats {
        // Case 3: Estimate from recording duration
        let sleepFraction: Double = durationMinutes > 180 ? 0.90 : 0.85
        let deepFraction: Double = durationMinutes > 180 ? 0.20 : 0.15
        let sleepMinutes = Int(Double(durationMinutes) * sleepFraction)
        let deepSleepMinutes = Int(Double(sleepMinutes) * deepFraction)
        return OvernightSleepStats(
            sleepMinutes: sleepMinutes,
            deepSleepMinutes: deepSleepMinutes,
            sleepFormatted: formatMinutes(sleepMinutes),
            deepFormatted: formatMinutes(deepSleepMinutes),
            sleepLabel: String(localized: "Est. Sleep", bundle: LanguageManager.appBundle),
            deepLabel: String(localized: "Est. Deep", bundle: LanguageManager.appBundle)
        )
    }

    /// Format minutes as "Xh Ym" or "Ym"
    func formatMinutes(_ totalMinutes: Int) -> String {
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    /// Result of peak RMSSD calculation
    struct PeakRMSSDResult {
        let rmssd: Double
        let offsetMs: Int64
    }

    /// Calculate peak rolling RMSSD, preferring the 30-70% recording band, with global fallback
    func calculatePeakRMSSD(points: [RRPoint], flags: [ArtifactFlags], startTimeMs: Int64) -> PeakRMSSDResult {
        // Empty input would trap at `points[min(_, points.count - 1)]`
        // (index -1). Currently unreachable but latent — guard it.
        guard !points.isEmpty else { return PeakRMSSDResult(rmssd: 0.0, offsetMs: 0) }
        let endTimeMs = points.last?.t_ms ?? startTimeMs
        let durationMs = endTimeMs - startTimeMs
        var peakRMSSD = 0.0
        var peakHRVIndex = 0
        // First pass: the 30-70% band, where a sleeper is most likely settled.
        scanPeak(points: points, flags: flags,
                 bandStart: startTimeMs + Int64(Double(durationMs) * 0.30),
                 bandEnd: startTimeMs + Int64(Double(durationMs) * 0.70),
                 peakRMSSD: &peakRMSSD, peakIndex: &peakHRVIndex)
        if peakRMSSD == 0.0 {
            // Fallback: scan the entire recording.
            scanPeak(points: points, flags: flags, bandStart: nil, bandEnd: nil,
                     peakRMSSD: &peakRMSSD, peakIndex: &peakHRVIndex)
        }
        let peakTimeMs = points[min(peakHRVIndex, points.count - 1)].t_ms
        return PeakRMSSDResult(rmssd: peakRMSSD, offsetMs: peakTimeMs - startTimeMs)
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

    /// Compute RMSSD for a window with artifact filtering and RR validation
    func windowRMSSD(points: [RRPoint], flags: [ArtifactFlags], from windowStart: Int, to windowEnd: Int) -> Double? {
        var cleanRRs: [Double] = []
        for j in windowStart ..< windowEnd {
            let isArtifact = j < flags.count ? flags[j].isArtifact : false
            guard !isArtifact, HRVConstants.RRInterval.isValid(points[j].rr_ms) else { continue }
            cleanRRs.append(Double(points[j].rr_ms))
        }
        guard cleanRRs.count >= 30, let rmssd = TimeDomainAnalyzer.rmssd(fromCleanRRs: cleanRRs),
              rmssd > 0, rmssd < 300
        else { return nil }
        return rmssd
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

/// "7h 42m" / "42m" for the recording span.
private func formatRecordingDuration(points: [RRPoint], startTimeMs: Int64) -> String {
    // Recording duration
    let durationMs = (points.last?.t_ms ?? 0) - startTimeMs
    let durationMinutes = Int(durationMs / 60000)
    let durationHours = durationMinutes / 60
    let durationMins = durationMinutes % 60
    let durationFormatted = durationHours > 0 ? "\(durationHours)h \(durationMins)m" : "\(durationMins)m"
    return durationFormatted
}

/// Every tenth beat or so, artifacts dropped, converted to bpm.
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

private func drawOvernightHRGrid(in graphRect: CGRect, minHR: Double, maxHR: Double, range: Double) {
    let graphHeight = graphRect.height
    // Draw grid lines
    UIColor(white: 0.9, alpha: 1.0).setStroke()
    for hrLine in stride(from: Int(minHR / 10) * 10, through: Int(maxHR), by: 10) {
        let normalized = (Double(hrLine) - minHR) / range
        let lineY = graphRect.maxY - CGFloat(normalized) * graphHeight
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
    let graphHeight = graphRect.height
    let path = UIBezierPath()
    var first = true
    let xScale = graphRect.width / CGFloat(pointCount)

    for (idx, hr) in hrData {
        let x = graphRect.minX + CGFloat(idx) * xScale
        let normalized = (hr - minHR) / range
        let yPos = graphRect.maxY - CGFloat(normalized) * graphHeight * 0.9 - 5

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
    text.draw(at: CGPoint(x: x + 8, y: y + 3), withAttributes: attributes)
}

/// No HealthKit sleep to lean on, so estimate from how long the recording
/// ran: a long night is assumed to be more consolidated than a short one.
private func estimatedSleepSplit(_ recordingDurationMinutes: Int) -> (sleep: Int, deep: Int, awake: Int) {
    var sleepMinutes = 0
    var deepSleepMinutes = 0
    var awakeMinutes = 0
    if recordingDurationMinutes > 180 {
        sleepMinutes = Int(Double(recordingDurationMinutes) * 0.90)
        deepSleepMinutes = Int(Double(sleepMinutes) * 0.20)
        awakeMinutes = recordingDurationMinutes - sleepMinutes
    } else {
        sleepMinutes = Int(Double(recordingDurationMinutes) * 0.85)
        deepSleepMinutes = Int(Double(sleepMinutes) * 0.15)
        awakeMinutes = recordingDurationMinutes - sleepMinutes
    }
    return (sleepMinutes, deepSleepMinutes, awakeMinutes)
}

/// HR as recorded during streaming.
private func storedHRStats(points: [RRPoint]) -> (nadir: Double, max: Double, nadirTime: Date?) {
    let hrValues = points.compactMap { point -> Double? in
        guard let hr = point.hr, hr >= 30, hr <= 200 else { return nil }
        return Double(hr)
    }
    guard !hrValues.isEmpty else { return (nadir: 50, max: 100, nadirTime: nil) }
    let nadir = hrValues.min() ?? 50
    let peak = hrValues.max() ?? 100
    let index = points.firstIndex { Double($0.hr ?? 0) == nadir }
    return (nadir: nadir, max: peak, nadirTime: nadirTime(at: index, in: points))
}

/// Offset of the nadir from the recording start. The absolute date is
/// meaningless here — the caller re-bases it onto the session start.
private func nadirTime(at index: Int?, in points: [RRPoint]) -> Date? {
    guard let index else { return nil }
    let offsetMs = points[index].t_ms - (points.first?.t_ms ?? 0)
    return Date().addingTimeInterval(Double(offsetMs) / 1000.0)
}

/// No stored HR — derive it from RR over rolling 10-second windows.
private func rollingWindowHRStats(points: [RRPoint]) -> (nadir: Double, max: Double, nadirTime: Date?) {
    let hrSamples = rollingHRSamples(points: points)
    guard !hrSamples.isEmpty else { return (nadir: 50, max: 100, nadirTime: nil) }
    let nadir = hrSamples.map(\.hr).min() ?? 50
    let peak = hrSamples.map(\.hr).max() ?? 100
    let index = hrSamples.first { $0.hr == nadir }?.index
    return (nadir: nadir, max: peak, nadirTime: nadirTime(at: index, in: points))
}

/// One HR sample per 10-second window, stepped with 50% overlap.
private func rollingHRSamples(points: [RRPoint]) -> [(hr: Double, index: Int)] {
    var hrSamples: [(hr: Double, index: Int)] = []
    var i = 0
    while i < points.count {
        let (sample, next) = rollingHRWindow(points: points, from: i)
        if let sample { hrSamples.append((hr: sample, index: i)) }
        // Advance by ~5 seconds (50% overlap)
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
