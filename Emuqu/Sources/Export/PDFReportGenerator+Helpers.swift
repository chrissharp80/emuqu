import Foundation
import PDFKit
import UIKit

// MARK: - Drawing Helpers

extension PDFReportGenerator {
    // MARK: - Drawing Helpers

    func drawSectionHeading(_ text: String, yPosition: CGFloat, pageRect: CGRect) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: config.headingFont,
            .foregroundColor: config.primaryColor
        ]

        let rect = CGRect(x: config.margins.left, y: yPosition, width: pageRect.width - config.margins.left - config.margins.right, height: 18)
        text.draw(in: rect, withAttributes: attributes)

        return yPosition + 20
    }

    func drawCompactMetricsGrid(_ metrics: [(String, String)], yPosition: CGFloat, pageRect: CGRect) -> CGFloat {
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        let columns = 4
        let colWidth = contentWidth / CGFloat(columns)
        let rowHeight: CGFloat = 28
        var y = yPosition
        for (i, metric) in metrics.enumerated() {
            let col = i % columns
            let row = i / columns
            if col == 0, row > 0 { y += rowHeight }
            drawCompactMetricCell(metric, col: col, row: row, colWidth: colWidth,
                                  rowHeight: rowHeight, contentWidth: contentWidth, y: y)
        }
        let totalRows = (metrics.count + columns - 1) / columns
        return y + CGFloat(totalRows > 0 ? 1 : 0) * rowHeight
    }

    private func drawCompactMetricCell(
        _ metric: (String, String),
        col: Int,
        row: Int,
        colWidth: CGFloat,
        rowHeight: CGFloat,
        contentWidth: CGFloat,
        y: CGFloat
    ) {
        let nameAttr: [NSAttributedString.Key: Any] = [
            .font: config.captionFont,
            .foregroundColor: UIColor.gray
        ]
        let valueAttr: [NSAttributedString.Key: Any] = [
            .font: config.monoFont,
            .foregroundColor: UIColor.black
        ]
            let x = config.margins.left + CGFloat(col) * colWidth

            // Background for alternating rows
            if row % 2 == 0, col == 0 {
                let rowRect = CGRect(x: config.margins.left, y: y - 2, width: contentWidth, height: rowHeight)
                UIColor(white: 0.97, alpha: 1.0).setFill()
                UIBezierPath(rect: rowRect).fill()
            }

            metric.0.draw(at: CGPoint(x: x, y: y), withAttributes: nameAttr)
            metric.1.draw(at: CGPoint(x: x, y: y + 10), withAttributes: valueAttr)
    }

    // MARK: - PSD Computation Helper

    /// A coarse periodogram, for the chart only — the reported LF/HF numbers
    /// come from the analysis pipeline, not from here.
    func computeSimplePSD(series: RRSeries, flags: [ArtifactFlags], windowStart: Int, windowEnd: Int) -> [(Double, Double)] {
        let cleanRR = cleanRRForPSD(series: series, flags: flags, windowStart: windowStart, windowEnd: windowEnd)
        guard cleanRR.count >= 64 else { return [] }
        let sampleCount = min(cleanRR.count, 512)
        let resampled = meanRemovedResample(cleanRR, sampleCount: sampleCount)
        return periodogram(resampled, sampleCount: sampleCount)
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

private func cleanRRForPSD(series: RRSeries, flags: [ArtifactFlags], windowStart: Int, windowEnd: Int) -> [Double] {
    var cleanRR: [Double] = []
    for i in windowStart ..< min(windowEnd, series.points.count) where i >= flags.count || !flags[i].isArtifact {
        cleanRR.append(Double(series.points[i].rr_ms))
    }
    return cleanRR
}

/// Nearest-neighbour onto a uniform grid, then mean-centred so the DC bin
/// does not swamp everything else.
private func meanRemovedResample(_ cleanRR: [Double], sampleCount: Int) -> [Double] {
    var resampled = [Double](repeating: 0, count: sampleCount)
    for i in 0 ..< sampleCount {
        resampled[i] = cleanRR[i * cleanRR.count / sampleCount]
    }
    let mean = resampled.reduce(0, +) / Double(sampleCount)
    return resampled.map { $0 - mean }
}

private func periodogram(_ resampled: [Double], sampleCount: Int) -> [(Double, Double)] {
    let resampleFrequency = 4.0
    var psd: [(Double, Double)] = []
    for k in 1 ..< 64 {
        let freq = Double(k) * resampleFrequency / Double(sampleCount) / 2
        if freq > 0.5 { break }
        psd.append((freq, binPower(resampled, bin: k, sampleCount: sampleCount)))
    }
    return psd
}

private func binPower(_ resampled: [Double], bin k: Int, sampleCount: Int) -> Double {
    var realSum = 0.0
    var imagSum = 0.0
    for i in 0 ..< sampleCount {
        let angle = 2.0 * .pi * Double(k) * Double(i) / Double(sampleCount)
        realSum += resampled[i] * cos(angle)
        imagSum += resampled[i] * sin(angle)
    }
    return (realSum * realSum + imagSum * imagSum) / Double(sampleCount * sampleCount)
}
