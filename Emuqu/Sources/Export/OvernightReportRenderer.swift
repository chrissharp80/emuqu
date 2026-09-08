import Foundation
import PDFKit
import UIKit

/// Draws the overnight-session pages of the PDF report: the overnight heart
/// rate chart, the stats section, and the tags-and-notes block.
///
/// Split out of `PDFReportGenerator`, like `DeepDiveReportRenderer`.
/// This code needs only three members of the
/// generator — the report config and two drawing primitives — and the four
/// types it works with (`OvernightStatValues`, `OvernightSleepStats`,
/// `PeakRMSSDResult`, `PeakScanWindow`) have no reader anywhere else in the
/// codebase, so they live with the code that owns them.
///
/// Holds its owner strongly and is built on demand by the generator — a
/// value with no state of its own, so nothing here can outlive what it
/// points at.
struct OvernightReportRenderer {
    let generator: PDFReportGenerator

    var config: PDFReportGenerator.Config { generator.config }

    func drawSectionHeading(_ text: String, yPosition: CGFloat, pageRect: CGRect) -> CGFloat {
        generator.drawSectionHeading(text, yPosition: yPosition, pageRect: pageRect)
    }

    func drawCompactStatBox(title: String, value: String, color: UIColor, rect: CGRect) {
        generator.drawCompactStatBox(title: title, value: value, color: color, rect: rect)
    }
}
