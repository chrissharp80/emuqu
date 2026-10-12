import CoreGraphics
import Foundation
import UIKit

// The layout primitives every page draws with: section headings, dividers,
// two-column rows and the footer. They need the page `Config`, so they are
// not free functions, but they belong to no single page.

extension WorkoutPDFRenderer {
    func drawSectionHeading(_ text: String, at y: inout CGFloat) {
        drawText(text,
                 at: CGPoint(x: report.config.margin, y: y),
                 font: UIFont.systemFont(ofSize: 9, weight: .bold),
                 color: report.config.primary)
        y += 14
    }

    func drawDivider(at y: CGFloat, width: CGFloat, strong: Bool = false) {
        PDFPagePrimitives.drawDivider(
            from: CGPoint(x: report.config.margin, y: y), width: width, strong: strong,
            primary: report.config.primary, divider: report.config.divider
        )
    }

    /// Label on the left, value in a right-hand column of `contentW`. Each
    /// stays in its own column and ends in an ellipsis rather than running
    /// into the other or past the margin.
    func drawTwoColumnRows(_ rows: [(String, String)], startY: inout CGFloat, contentW: CGFloat) {
        let rowH: CGFloat = 14
        let valueWidth = min(260, contentW * 0.45)
        let valueX = report.config.margin + contentW - valueWidth
        for row in rows {
            PDFPagePrimitives.drawTruncated(
                row.0, in: CGRect(x: report.config.margin, y: startY, width: valueX - report.config.margin - 8, height: rowH),
                font: report.config.bodyFont, color: report.config.textSecondary
            )
            PDFPagePrimitives.drawTruncated(
                row.1, in: CGRect(x: valueX, y: startY, width: valueWidth, height: rowH),
                font: report.config.monoFont, color: report.config.textPrimary
            )
            startY += rowH
        }
    }

    /// Page footer: the shared rule, generated/session line and wellness
    /// disclaimer. The disclaimer is on EVERY page: the clinical register of
    /// this report travels well beyond the app, and a reader could print a
    /// single page.
    func drawFooter() {
        let generated = Date().formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(LanguageManager.appLocale))
        let config = report.config
        PDFPagePrimitives.drawFooter(
            String(localized: "Generated \(generated) · Session \(report.session.id.uuidString.prefix(8)) · Emuqu", bundle: LanguageManager.appBundle),
            page: PDFPagePrimitives.PageStyle(
                pageSize: config.pageSize, margin: config.margin, captionFont: config.captionFont,
                primary: config.primary, divider: config.divider, textTertiary: config.textTertiary
            )
        )
    }
}

/// The drawing primitives the workout report and the daily report share, so
/// their text, rules, footers and durations are drawn by one copy.
enum PDFPagePrimitives {
    /// What a footer needs from a report's page config.
    struct PageStyle {
        let pageSize: CGSize
        let margin: CGFloat
        let captionFont: UIFont
        let primary: UIColor
        let divider: UIColor
        let textTertiary: UIColor
    }

    static func drawText(_ text: String, at origin: CGPoint, font: UIFont, color: UIColor) {
        text.pdfDraw(at: origin, withAttributes: [.font: font, .foregroundColor: color])
    }

    /// One line in `rect`, ending in an ellipsis when it does not fit.
    static func drawTruncated(_ text: String, in rect: CGRect, font: UIFont, color: UIColor) {
        let paragraph = PDFReadingDirection.paragraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        text.pdfDraw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    /// Draws `text` word-wrapped at its full measured height (never clipped)
    /// and returns the y just below it.
    @discardableResult
    static func drawWrappedText(_ text: String, at origin: CGPoint, width: CGFloat, font: UIFont, color: UIColor, lineHeight: CGFloat) -> CGFloat {
        let height = wrappedTextHeight(text, width: width, font: font, lineHeight: lineHeight)
        wrappedText(text, font: font, color: color, lineHeight: lineHeight)
            .pdfDraw(in: CGRect(origin: origin, size: CGSize(width: width, height: height)))
        return origin.y + height
    }

    /// The height `drawWrappedText` uses for `text` at `width`.
    static func wrappedTextHeight(_ text: String, width: CGFloat, font: UIFont, lineHeight: CGFloat) -> CGFloat {
        ceil(wrappedText(text, font: font, color: .black, lineHeight: lineHeight)
            .boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            .height)
    }

    private static func wrappedText(_ text: String, font: UIFont, color: UIColor, lineHeight: CGFloat) -> NSAttributedString {
        let paragraph = PDFReadingDirection.paragraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = max(0, lineHeight - font.lineHeight)
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    /// A horizontal rule: strong is the primary colour at half alpha, 1.2 pt;
    /// otherwise the divider colour, 0.5 pt.
    static func drawDivider(from start: CGPoint, width: CGFloat, strong: Bool, primary: UIColor, divider: UIColor) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setStrokeColor((strong ? primary.withAlphaComponent(0.5) : divider).cgColor)
        ctx.setLineWidth(strong ? 1.2 : 0.5)
        ctx.move(to: start)
        ctx.addLine(to: CGPoint(x: start.x + width, y: start.y))
        ctx.strokePath()
    }

    /// Rule at page height - margin + 6, `line` under it, and the wellness
    /// disclaimer under that, on every page of both reports.
    static func drawFooter(_ line: String, page: PageStyle) {
        let y = page.pageSize.height - page.margin + 6
        drawDivider(from: CGPoint(x: page.margin, y: y), width: page.pageSize.width - 2 * page.margin,
                    strong: false, primary: page.primary, divider: page.divider)
        drawText(line, at: CGPoint(x: page.margin, y: y + 4), font: page.captionFont, color: page.textTertiary)
        drawText(String(localized: "For wellness and fitness use only. Not a medical device; not medical advice, diagnosis, or treatment.", bundle: LanguageManager.appBundle),
                 at: CGPoint(x: page.margin, y: y + 4 + page.captionFont.lineHeight),
                 font: page.captionFont, color: page.textTertiary)
    }

    /// "1:02:03" or "2:03".
    static func formatDuration(_ sec: Int) -> String {
        let h = sec / 3600, m = (sec % 3600) / 60, s = sec % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Elapsed time on the PDF pages in the app's language ("12 min 5 s" and its
/// translations), rather than a hard-coded "12m 5s".
enum PDFDurationText {
    static func minutesSeconds(_ seconds: Int) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = LanguageManager.appLocale
        formatter.calendar = calendar
        formatter.allowedUnits = seconds >= 60 ? [.minute, .second] : [.second]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter.string(from: TimeInterval(max(0, seconds))) ?? "\(max(0, seconds) / 60):\(String(format: "%02d", max(0, seconds) % 60))"
    }
}
