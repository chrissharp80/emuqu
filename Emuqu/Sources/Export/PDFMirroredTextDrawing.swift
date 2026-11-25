import Foundation
import PDFKit
import UIKit

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
