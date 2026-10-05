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
        text.pdfDraw(in: rect, withAttributes: attributes)

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

            metric.0.pdfDraw(at: CGPoint(x: x, y: y), withAttributes: nameAttr)
            metric.1.pdfDraw(at: CGPoint(x: x, y: y + 10), withAttributes: valueAttr)
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

/// Which way the report's language reads, and the page mirroring that follows
/// from it.
///
/// The renderers lay every page out left-to-right at absolute coordinates, so
/// they get none of the mirroring SwiftUI gives the screens. In a
/// right-to-left language `beginPage` mirrors the page's x axis instead:
/// tables, grids, name/value rows, cards, bars and chart axes and legends all
/// land on the opposite side, the way Arabic reads. Text goes through the
/// `pdfDraw` helpers and the route map through `drawingLeftToRight`, which
/// flip their own box back, so glyphs, numbers and geography are never drawn
/// back to front.
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

    /// `text` set apart from the line around it in a right-to-left language,
    /// so an Arabic duration ("10 د 22 ث") inside a line that starts with a
    /// Latin label keeps its own word and number order. Unchanged otherwise.
    static func isolated(_ text: String) -> String {
        isRightToLeft ? "\u{2068}\(text)\u{2069}" : text
    }

    /// Starts a new page, with its x axis mirrored in a right-to-left
    /// language. Every renderer starts its pages here.
    static func beginPage(_ context: UIGraphicsPDFRendererContext) {
        context.beginPage()
        guard isRightToLeft, !isMirrored(context.cgContext) else { return }
        let bounds = context.pdfContextBounds
        context.cgContext.translateBy(x: bounds.minX + bounds.maxX, y: 0)
        context.cgContext.scaleBy(x: -1, y: 1)
    }

    /// Whether the current drawing context is mirrored. UIKit contexts flip
    /// y, so an unmirrored one maps with a negative determinant; a mirrored
    /// page flips x as well, which makes it positive.
    static var isDrawingMirrored: Bool {
        guard let context = UIGraphicsGetCurrentContext() else { return false }
        return isMirrored(context)
    }

    private static func isMirrored(_ context: CGContext) -> Bool {
        let transform = context.ctm
        return transform.a * transform.d - transform.b * transform.c > 0
    }

    /// Runs `draw` with the strip from `minX` for `width` flipped back, so
    /// what it draws sits in the strip's mirrored place but reads
    /// left-to-right: text, the route map, and a number set beside its unit.
    /// On an unmirrored page it just runs `draw`.
    static func drawingLeftToRight(minX: CGFloat, width: CGFloat, _ draw: () -> Void) {
        guard let context = UIGraphicsGetCurrentContext(), isMirrored(context) else { return draw() }
        context.saveGState()
        context.translateBy(x: 2 * minX + width, y: 0)
        context.scaleBy(x: -1, y: 1)
        draw()
        context.restoreGState()
    }

    /// `attributes` with the paragraph alignment pinned to the page: text
    /// that starts at a box's left edge starts at its right on a mirrored
    /// page. Natural alignment is resolved here too, as the left edge (the
    /// right when mirrored), because UIKit would otherwise resolve it from the
    /// language the app launched in rather than the report's language.
    static func anchoredAttributes(_ attributes: [NSAttributedString.Key: Any]?, mirrored: Bool) -> [NSAttributedString.Key: Any] {
        var anchored = attributes ?? [:]
        anchored[.paragraphStyle] = anchoredStyle(attributes?[.paragraphStyle] as? NSParagraphStyle, mirrored: mirrored)
        return anchored
    }

    /// `text` with every paragraph's alignment pinned to the page, as
    /// `anchoredAttributes` does for a plain string.
    static func anchoredText(_ text: NSAttributedString, mirrored: Bool) -> NSAttributedString {
        let anchored = NSMutableAttributedString(attributedString: text)
        let whole = NSRange(location: 0, length: anchored.length)
        text.enumerateAttribute(.paragraphStyle, in: whole) { value, range, _ in
            let style = anchoredStyle(value as? NSParagraphStyle, mirrored: mirrored)
            anchored.addAttribute(.paragraphStyle, value: style, range: range)
        }
        return anchored
    }

    private static func anchoredStyle(_ style: NSParagraphStyle?, mirrored: Bool) -> NSParagraphStyle {
        let anchored = (style?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        anchored.alignment = anchoredAlignment(anchored.alignment, mirrored: mirrored)
        return anchored
    }

    /// The layout's natural side is the left, the right once mirrored;
    /// centred and justified text stay as they are.
    private static func anchoredAlignment(_ alignment: NSTextAlignment, mirrored: Bool) -> NSTextAlignment {
        switch (alignment, mirrored) {
        case (.left, true), (.natural, true): .right
        case (.right, true): .left
        case (.natural, false): .left
        default: alignment
        }
    }
}

// MARK: - Drawing that reads correctly on a mirrored page

extension String {
    /// `draw(at:withAttributes:)`, kept readable on a mirrored page.
    func pdfDraw(at point: CGPoint, withAttributes attributes: [NSAttributedString.Key: Any]? = nil) {
        let text = self as NSString
        guard PDFReadingDirection.isDrawingMirrored else { return text.draw(at: point, withAttributes: attributes) }
        let width = text.size(withAttributes: attributes).width
        PDFReadingDirection.drawingLeftToRight(minX: point.x, width: width) {
            text.draw(at: point, withAttributes: attributes)
        }
    }

    /// `draw(in:withAttributes:)`, kept readable on a mirrored page, with
    /// its alignment pinned to the page by `anchoredAttributes`.
    func pdfDraw(in rect: CGRect, withAttributes attributes: [NSAttributedString.Key: Any]? = nil) {
        let text = self as NSString
        let mirrored = PDFReadingDirection.isDrawingMirrored
        let anchored = PDFReadingDirection.anchoredAttributes(attributes, mirrored: mirrored)
        guard mirrored else { return text.draw(in: rect, withAttributes: anchored) }
        PDFReadingDirection.drawingLeftToRight(minX: rect.minX, width: rect.width) {
            text.draw(in: rect, withAttributes: anchored)
        }
    }
}

extension NSAttributedString {
    /// `draw(in:)`, kept readable on a mirrored page, with its alignment
    /// pinned to the page by `anchoredText`.
    func pdfDraw(in rect: CGRect) {
        let mirrored = PDFReadingDirection.isDrawingMirrored
        let anchored = PDFReadingDirection.anchoredText(self, mirrored: mirrored)
        guard mirrored else { return anchored.draw(in: rect) }
        PDFReadingDirection.drawingLeftToRight(minX: rect.minX, width: rect.width) {
            anchored.draw(in: rect)
        }
    }

    /// `draw(with:options:context:)`, laid out as `pdfDraw(in:)` is.
    func pdfDraw(with rect: CGRect, options: NSStringDrawingOptions, context: NSStringDrawingContext?) {
        let mirrored = PDFReadingDirection.isDrawingMirrored
        let anchored = PDFReadingDirection.anchoredText(self, mirrored: mirrored)
        guard mirrored else { return anchored.draw(with: rect, options: options, context: context) }
        PDFReadingDirection.drawingLeftToRight(minX: rect.minX, width: rect.width) {
            anchored.draw(with: rect, options: options, context: context)
        }
    }
}
