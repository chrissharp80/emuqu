import Foundation
import PDFKit
import UIKit

// MARK: - Chart Visualizations

extension ReportSectionRenderer {
    // MARK: - Visualizations

    /// RR(n) against RR(n+1) with the SD1/SD2 ellipse laid over it — the shape
    /// of the scatter is the reading, not any single point.
    func drawPoincarePlot(
        series: RRSeries,
        flags: [ArtifactFlags],
        result: HRVAnalysisResult,
        yPosition: CGFloat,
        in context: UIGraphicsPDFRendererContext,
        pageRect: CGRect
    ) -> CGFloat {
        let plotSize: CGFloat = 180
        let y = drawSectionHeading(String(localized: "Poincaré Plot", bundle: LanguageManager.appBundle), yPosition: yPosition, pageRect: pageRect)
        let plotRect = CGRect(x: config.margins.left, y: y, width: plotSize, height: plotSize)
        drawPoincareFrame(plotRect)

        let rrPairs = poincarePairs(series: series, flags: flags, result: result)
        guard let scale = PoincareScale(pairs: rrPairs, plotSize: plotSize) else { return y + plotSize + 20 }

        drawPoincareIdentityLine(in: plotRect)
        drawPoincareEllipse(result: result, scale: scale, in: plotRect, context: context)
        drawPoincareDots(rrPairs, scale: scale, in: plotRect)
        drawPoincareLabels(in: plotRect)
        drawPoincareStats(result: result, pointCount: rrPairs.count, x: plotRect.maxX + 20, y: y + 10)
        return y + plotSize + 20
    }

    /// Consecutive RR pairs from inside the analysis window, artifact-adjacent
    /// pairs dropped.
    ///
    /// A zeroed/degenerate analysis window (windowEnd 0 or 1) would make the
    /// range `windowStart ..< (windowEnd - 1)` trap before the empty-guard
    /// (e.g. 0 ..< -1), so it bails early like the tachogram renderer does.
    private func poincarePairs(series: RRSeries, flags: [ArtifactFlags], result: HRVAnalysisResult) -> [(Double, Double)] {
        let windowStart = result.windowStart
        let windowEnd = min(result.windowEnd, series.points.count)
        guard windowEnd > windowStart + 1 else { return [] }
        return (windowStart ..< (windowEnd - 1)).compactMap { i in
            guard Self.isCleanPair(at: i, flags: flags) else { return nil }
            return (Double(series.points[i].rr_ms), Double(series.points[i + 1].rr_ms))
        }
    }

    /// Both beats of the pair must be in range and artifact-free.
    private static func isCleanPair(at i: Int, flags: [ArtifactFlags]) -> Bool {
        guard i < flags.count, (i + 1) < flags.count else { return false }
        return !flags[i].isArtifact && !flags[i + 1].isArtifact
    }

    /// Maps an RR value onto the plot, padded so the cloud does not touch the
    /// frame. Fails when there is nothing to plot.
    struct PoincareScale {
        let plotMin: Double
        let plotMax: Double
        let plotSize: CGFloat
        let meanRR: Double

        init?(pairs: [(Double, Double)], plotSize: CGFloat) {
            let allRR = pairs.flatMap { [$0.0, $0.1] }
            guard !allRR.isEmpty else { return nil }
            let minRR = allRR.min() ?? 600
            let maxRR = allRR.max() ?? 1_200
            let range = max(maxRR - minRR, 100)
            let padding = range * 0.1
            self.plotMin = minRR - padding
            self.plotMax = maxRR + padding
            self.plotSize = plotSize
            self.meanRR = allRR.reduce(0, +) / Double(allRR.count)
        }

        func scaled(_ value: Double) -> CGFloat {
            let normalized = (value - plotMin) / (plotMax - plotMin)
            return CGFloat(normalized) * (plotSize - 20) + 10
        }

        /// One millisecond in plot points — the ellipse axes are given in ms.
        var pixelsPerMs: CGFloat { (plotSize - 20) / CGFloat(plotMax - plotMin) }
    }

    private func drawPoincareEllipse(
        result: HRVAnalysisResult,
        scale: PoincareScale,
        in plotRect: CGRect,
        context: UIGraphicsPDFRendererContext
    ) {
        let centerX = plotRect.minX + scale.scaled(scale.meanRR)
        let centerY = plotRect.maxY - scale.scaled(scale.meanRR)
        let sd1Px = CGFloat(result.nonlinear.sd1) * scale.pixelsPerMs
        let sd2Px = CGFloat(result.nonlinear.sd2) * scale.pixelsPerMs
        context.cgContext.saveGState()
        context.cgContext.translateBy(x: centerX, y: centerY)
        context.cgContext.rotate(by: -.pi / 4)

        let ellipsePath = UIBezierPath(ovalIn: CGRect(x: -sd2Px, y: -sd1Px, width: sd2Px * 2, height: sd1Px * 2))
        config.primaryColor.withAlphaComponent(0.2).setFill()
        ellipsePath.fill()
        config.primaryColor.withAlphaComponent(0.5).setStroke()
        ellipsePath.lineWidth = 1
        ellipsePath.stroke()

        context.cgContext.restoreGState()
    }

    private func drawPoincareDots(_ rrPairs: [(Double, Double)], scale: PoincareScale, in plotRect: CGRect) {
        // Draw points (sample if too many)
        let maxPoints = 500
        let step = max(1, rrPairs.count / maxPoints)
        config.primaryColor.withAlphaComponent(0.6).setFill()

        for i in stride(from: 0, to: rrPairs.count, by: step) {
            let (rr1, rr2) = rrPairs[i]
            let x = plotRect.minX + scale.scaled(rr1)
            let y = plotRect.maxY - scale.scaled(rr2)
            let dotRect = CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3)
            UIBezierPath(ovalIn: dotRect).fill()
        }
    }

    private func drawPoincareLabels(in plotRect: CGRect) {
        // Labels
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: config.captionFont,
            .foregroundColor: UIColor.darkGray
        ]
        String(localized: "RR(n) ms", bundle: LanguageManager.appBundle).draw(at: CGPoint(x: plotRect.midX - 20, y: plotRect.maxY + 2), withAttributes: labelAttributes)
    }

    private func drawPoincareStats(result: HRVAnalysisResult, pointCount: Int, x statsX: CGFloat, y: CGFloat) {
        // Stats next to plot
        let stats = [
            ("SD1", String(format: "%.1f ms", locale: .current, result.nonlinear.sd1)),
            ("SD2", String(format: "%.1f ms", locale: .current, result.nonlinear.sd2)),
            ("SD1/SD2", String(format: "%.3f", locale: .current, result.nonlinear.sd1Sd2Ratio)),
            (String(localized: "Points", bundle: LanguageManager.appBundle), "\(pointCount)")
        ]

        var statsY = y
        for (name, value) in stats {
            let nameAttr: [NSAttributedString.Key: Any] = [.font: config.captionFont, .foregroundColor: UIColor.gray]
            let valueAttr: [NSAttributedString.Key: Any] = [.font: config.monoFont, .foregroundColor: UIColor.black]
            name.draw(at: CGPoint(x: statsX, y: statsY), withAttributes: nameAttr)
            value.draw(at: CGPoint(x: statsX + 50, y: statsY), withAttributes: valueAttr)
            statsY += 14
        }
    }

    /// The spectrum with its VLF/LF/HF bands shaded behind the curve.
    func drawPSDGraph(
        series: RRSeries,
        flags: [ArtifactFlags],
        fd: FrequencyDomainMetrics,
        yPosition: CGFloat,
        in _: UIGraphicsPDFRendererContext,
        pageRect: CGRect
    ) -> CGFloat {
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        let graphHeight: CGFloat = 100
        let y = drawSectionHeading(String(localized: "Power Spectral Density", bundle: LanguageManager.appBundle), yPosition: yPosition, pageRect: pageRect)
        let graphRect = CGRect(x: config.margins.left, y: y, width: contentWidth - 100, height: graphHeight)

        UIColor(white: 0.98, alpha: 1.0).setFill()
        UIBezierPath(rect: graphRect).fill()

        let psdData = computeSimplePSD(series: series, flags: flags, windowStart: 0, windowEnd: series.points.count)
        guard !psdData.isEmpty else { return y + graphHeight + 20 }
        drawPSDContents(psdData, fd: fd, in: graphRect, y: y)
        return y + graphHeight + 30
    }

    private func drawPSDContents(_ psdData: [(Double, Double)], fd: FrequencyDomainMetrics, in graphRect: CGRect, y: CGFloat) {
        // Everything below places itself by frequency, so the mapping is shared.
        let freqToX: (Double) -> CGFloat = { freq in
            graphRect.minX + CGFloat(freq / 0.5) * graphRect.width
        }
        drawPSDBands(freqToX: freqToX, in: graphRect)
        drawPSDCurve(psdData, freqToX: freqToX, in: graphRect)
        UIColor.lightGray.setStroke()
        UIBezierPath(rect: graphRect).stroke()
        drawPSDFrequencyAxis(freqToX: freqToX, in: graphRect)
        drawPSDBandLabels(freqToX: freqToX, in: graphRect)
        drawPSDStats(fd, x: graphRect.maxX + 10, y: y + 5)
    }

    /// VLF grey, LF blue, HF green — the bands a reader compares by eye.
    private func drawPSDBands(freqToX: (Double) -> CGFloat, in graphRect: CGRect) {
        drawPSDBand(from: 0.003, to: 0.04, colour: UIColor(white: 0.9, alpha: 0.5), freqToX: freqToX, in: graphRect)
        drawPSDBand(from: 0.04, to: 0.15, colour: config.primaryColor.withAlphaComponent(0.15), freqToX: freqToX, in: graphRect)
        drawPSDBand(from: 0.15, to: 0.4, colour: config.secondaryColor.withAlphaComponent(0.15), freqToX: freqToX, in: graphRect)
    }

    private func drawPSDCurve(_ psdData: [(Double, Double)], freqToX: (Double) -> CGFloat, in graphRect: CGRect) {
        let path = psdCurvePath(psdData, freqToX: freqToX, in: graphRect)
        config.primaryColor.setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }

    private func drawPSDFrequencyAxis(freqToX: (Double) -> CGFloat, in graphRect: CGRect) {
        // X-axis labels
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: config.captionFont,
            .foregroundColor: UIColor.darkGray
        ]

        for freq in [0.0, 0.1, 0.2, 0.3, 0.4, 0.5] {
            let x = freqToX(freq)
            let label = String(format: "%.1f", locale: .current, freq)
            label.draw(at: CGPoint(x: x - 8, y: graphRect.maxY + 2), withAttributes: labelAttributes)
        }
        String(localized: "Frequency (Hz)", bundle: LanguageManager.appBundle).draw(at: CGPoint(x: graphRect.midX - 30, y: graphRect.maxY + 14), withAttributes: labelAttributes)
    }

    private func drawPSDStats(_ fd: FrequencyDomainMetrics, x statsX: CGFloat, y: CGFloat) {
        // Stats
        var statsY = y
        let stats = [
            ("LF", String(format: "%.0f ms²", locale: .current, fd.lf)),
            ("HF", String(format: "%.0f ms²", locale: .current, fd.hf)),
            ("LF/HF", fd.lfHfRatio.map { String(format: "%.2f", locale: .current, $0) } ?? "—"),
            (String(localized: "Total", bundle: LanguageManager.appBundle), String(format: "%.0f ms²", locale: .current, fd.totalPower))
        ]

        for (name, value) in stats {
            let nameAttr: [NSAttributedString.Key: Any] = [.font: config.captionFont, .foregroundColor: UIColor.gray]
            let valueAttr: [NSAttributedString.Key: Any] = [.font: config.monoFont, .foregroundColor: UIColor.black]
            name.draw(at: CGPoint(x: statsX, y: statsY), withAttributes: nameAttr)
            value.draw(at: CGPoint(x: statsX + 35, y: statsY), withAttributes: valueAttr)
            statsY += 12
        }
    }

    /// Beat-to-beat RR across the analysis window, artifacts dotted.
    func drawTachogram(
        series: RRSeries,
        flags: [ArtifactFlags],
        result: HRVAnalysisResult,
        yPosition: CGFloat,
        in _: UIGraphicsPDFRendererContext,
        pageRect: CGRect
    ) -> CGFloat {
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        let graphHeight: CGFloat = 80
        let y = drawSectionHeading(String(localized: "RR Tachogram", bundle: LanguageManager.appBundle), yPosition: yPosition, pageRect: pageRect)
        let graphRect = CGRect(x: config.margins.left, y: y, width: contentWidth, height: graphHeight)

        UIColor(white: 0.98, alpha: 1.0).setFill()
        UIBezierPath(rect: graphRect).fill()

        let rrValues = tachogramValues(series: series, flags: flags, result: result)
        // Need >=2 points for the x-scale below; `count - 1`
        // would divide by zero with a single point -> inf/NaN path coords.
        guard rrValues.count >= 2 else { return y + graphHeight + 15 }

        let minRR = rrValues.map(\.1).min() ?? 600
        let maxRR = rrValues.map(\.1).max() ?? 1_200
        drawTachogramTrace(rrValues, minRR: minRR, range: max(maxRR - minRR, 50), in: graphRect)
        UIColor.lightGray.setStroke()
        UIBezierPath(rect: graphRect).stroke()
        drawTachogramAxisLabels(minRR: minRR, maxRR: maxRR, in: graphRect)
        return y + graphHeight + 15
    }

    private func drawTachogramTrace(_ rrValues: [(Int, Double, Bool)], minRR: Double, range: Double, in graphRect: CGRect) {
        // The window shading sits under the trace, not behind the whole chart.
        config.primaryColor.withAlphaComponent(0.05).setFill()
        UIBezierPath(rect: graphRect).fill()

        let path = tachogramPath(rrValues, minRR: minRR, range: range, in: graphRect)
        config.primaryColor.setStroke()
        path.lineWidth = 0.8
        path.stroke()
    }

    /// Builds the trace and dots each artifact as it passes it, so the two
    /// cannot disagree about where a beat sat.
    private func tachogramPath(_ rrValues: [(Int, Double, Bool)], minRR: Double, range: Double, in graphRect: CGRect) -> UIBezierPath {
        let path = UIBezierPath()
        let xScale = graphRect.width / CGFloat(rrValues.count - 1)
        for (offset, element) in rrValues.enumerated() {
            let (i, rr, isArtifact) = element
            let x = graphRect.minX + CGFloat(i) * xScale
            let normalized = (rr - minRR) / range
            let yPos = graphRect.maxY - CGFloat(normalized) * graphRect.height * 0.85 - 5
            if offset == 0 {
                path.move(to: CGPoint(x: x, y: yPos))
            } else {
                path.addLine(to: CGPoint(x: x, y: yPos))
            }
            if isArtifact { markTachogramArtifact(x: x, y: yPos) }
        }
        return path
    }

    private func markTachogramArtifact(x: CGFloat, y: CGFloat) {
        config.accentColor.setFill()
        UIBezierPath(ovalIn: CGRect(x: x - 2, y: y - 2, width: 4, height: 4)).fill()
    }

    private func drawTachogramAxisLabels(minRR: Double, maxRR: Double, in graphRect: CGRect) {
        // Y-axis labels
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: config.captionFont,
            .foregroundColor: UIColor.gray
        ]
        String(format: "%.0f", locale: .current, maxRR).draw(at: CGPoint(x: graphRect.maxX + 3, y: graphRect.minY), withAttributes: labelAttributes)
        String(format: "%.0f", locale: .current, minRR).draw(at: CGPoint(x: graphRect.maxX + 3, y: graphRect.maxY - 10), withAttributes: labelAttributes)
        "ms".draw(at: CGPoint(x: graphRect.maxX + 3, y: graphRect.midY - 5), withAttributes: labelAttributes)
    }
}

// MARK: - File-scope helpers
//
// Kept out of the type. Each touches no instance state —
// including the computed properties — and
// calls nothing that stayed behind, so none was a method in anything but
// placement. `private` at file scope is fileprivate, so every call site in
// this file resolves exactly as before.
//
// This is what `check_aggregate_type_size.sh` measures: a type is the sum of
// its parts across every file, so code that does not need the type inflates
// that number without making the type do more.

private func drawPoincareFrame(_ plotRect: CGRect) {
    // Background
    UIColor(white: 0.98, alpha: 1.0).setFill()
    UIBezierPath(rect: plotRect).fill()

    // Border
    UIColor.lightGray.setStroke()
    UIBezierPath(rect: plotRect).stroke()
}

private func drawPoincareIdentityLine(in plotRect: CGRect) {
    // Draw identity line
    let linePath = UIBezierPath()
    linePath.move(to: CGPoint(x: plotRect.minX + 10, y: plotRect.maxY - 10))
    linePath.addLine(to: CGPoint(x: plotRect.maxX - 10, y: plotRect.minY + 10))
    UIColor.lightGray.setStroke()
    linePath.lineWidth = 0.5
    linePath.stroke()
}

private func drawPSDBand(
    from lower: Double,
    to upper: Double,
    colour: UIColor,
    freqToX: (Double) -> CGFloat,
    in graphRect: CGRect
) {
    let bandRect = CGRect(
        x: freqToX(lower),
        y: graphRect.minY,
        width: freqToX(upper) - freqToX(lower),
        height: graphRect.height
    )
    colour.setFill()
    UIBezierPath(rect: bandRect).fill()
}

private func psdCurvePath(_ psdData: [(Double, Double)], freqToX: (Double) -> CGFloat, in graphRect: CGRect) -> UIBezierPath {
    let graphHeight = graphRect.height
    let maxPower = psdData.map(\.1).max() ?? 1
    let path = UIBezierPath()
    var first = true

    for (freq, power) in psdData {
        let x = freqToX(freq)
        let normalizedPower = power / maxPower
        let y = graphRect.maxY - CGFloat(normalizedPower) * graphHeight * 0.9

        if first {
            path.move(to: CGPoint(x: x, y: y))
            first = false
        } else {
            path.addLine(to: CGPoint(x: x, y: y))
        }
    }
    return path
}

private func drawPSDBandLabels(freqToX: (Double) -> CGFloat, in graphRect: CGRect) {
    // Band labels
    let bandLabels: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 7, weight: .medium),
        .foregroundColor: UIColor.gray
    ]
    "VLF".draw(at: CGPoint(x: freqToX(0.02) - 6, y: graphRect.minY + 2), withAttributes: bandLabels)
    "LF".draw(at: CGPoint(x: freqToX(0.095) - 4, y: graphRect.minY + 2), withAttributes: bandLabels)
    "HF".draw(at: CGPoint(x: freqToX(0.275) - 4, y: graphRect.minY + 2), withAttributes: bandLabels)
}

/// (offset within the window, RR in ms, was it flagged as an artifact)
private func tachogramValues(series: RRSeries, flags: [ArtifactFlags], result: HRVAnalysisResult) -> [(Int, Double, Bool)] {
    let windowStart = result.windowStart
    let windowEnd = min(result.windowEnd, series.points.count)
    guard windowEnd > windowStart else { return [] }

    // Get RR values
    var rrValues: [(Int, Double, Bool)] = []
    for i in windowStart ..< windowEnd {
        let isArtifact = i < flags.count ? flags[i].isArtifact : false
        rrValues.append((i - windowStart, Double(series.points[i].rr_ms), isArtifact))
    }

    return rrValues
}
