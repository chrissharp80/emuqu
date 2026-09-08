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
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setStrokeColor((strong ? report.config.primary.withAlphaComponent(0.5) : report.config.divider).cgColor)
        ctx.setLineWidth(strong ? 1.2 : 0.5)
        ctx.move(to: CGPoint(x: report.config.margin, y: y))
        ctx.addLine(to: CGPoint(x: report.config.margin + width, y: y))
        ctx.strokePath()
    }

    func drawTwoColumnRows(_ rows: [(String, String)], startY: inout CGFloat, contentW: CGFloat) {
        let rowH: CGFloat = 14
        for row in rows {
            drawText(row.0,
                     at: CGPoint(x: report.config.margin, y: startY),
                     font: report.config.bodyFont,
                     color: report.config.textSecondary)
            let valueWidth: CGFloat = 260
            drawText(row.1,
                     at: CGPoint(x: report.config.pageSize.width - report.config.margin - valueWidth, y: startY),
                     font: report.config.monoFont,
                     color: report.config.textPrimary)
            startY += rowH
        }
    }

    func drawFooter() {
        let y = report.config.pageSize.height - report.config.margin + 6
        let contentW = report.config.pageSize.width - 2 * report.config.margin
        drawDivider(at: y, width: contentW)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        drawText(String(localized: "Generated \(iso.string(from: Date())) · Session \(report.session.id.uuidString.prefix(8)) · Emuqu", bundle: LanguageManager.appBundle),
                 at: CGPoint(x: report.config.margin, y: y + 4),
                 font: report.config.captionFont,
                 color: report.config.textTertiary)
        // Wellness disclaimer on EVERY page. The clinical
        // REGISTER of this report — physician-facing phrasing, normative
        // context — travels well beyond the app, and a reader could print a
        // single page, so the disclaimer can't live on one page only.
        drawText(String(localized: "For wellness and fitness use only. Not a medical device; not medical advice, diagnosis, or treatment.", bundle: LanguageManager.appBundle),
                 at: CGPoint(x: report.config.margin, y: y + 4 + report.config.captionFont.lineHeight),
                 font: report.config.captionFont,
                 color: report.config.textTertiary)
    }
}
