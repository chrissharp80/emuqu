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
}

// MARK: - Report value formatting

/// What a report prints for a value it does not have. A dash reads the same
/// in every language.
let reportMissingValue = "—"

/// "7.2 br/min" in the app's language.
func reportBreathsPerMinute(_ rate: Double) -> String {
    String(format: String(localized: "%.1f br/min", bundle: LanguageManager.appBundle), locale: LanguageManager.appLocale, rate)
}

/// "1h 23m" or "45m" in the app's language, or the missing-value dash.
func reportHoursMinutes(_ minutes: Int?) -> String {
    guard let minutes else { return reportMissingValue }
    return LocalizedDuration.hoursMinutes(minutes: minutes)
}

// MARK: - Reading direction

/// Which way the report's language reads. The PDF renderers draw at absolute
/// coordinates, so they get none of the mirroring SwiftUI gives the screens;
/// bullets and paragraph alignment come from here instead.
enum PDFReadingDirection {
    static var isRightToLeft: Bool {
        LanguageManager.appLocale.language.characterDirection == .rightToLeft
    }

    /// The step and interpretation bullet, pointing the way the text runs.
    static var bullet: String { isRightToLeft ? "←" : "→" }

    /// A paragraph style aligned to where the language starts a line: the
    /// right margin in Arabic, the left otherwise.
    static func paragraphStyle() -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .natural
        style.baseWritingDirection = isRightToLeft ? .rightToLeft : .leftToRight
        return style
    }

    /// The x of something `itemWidth` wide set at the reading-start side of a
    /// row running from `minX` for `width`.
    static func startX(minX: CGFloat, width: CGFloat, itemWidth: CGFloat) -> CGFloat {
        isRightToLeft ? minX + width - itemWidth : minX
    }
}
