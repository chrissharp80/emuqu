import Foundation
import PDFKit
import UIKit

/// Draws the clinical deep-dive pages of the PDF report: HRV, sleep, training
/// and vitals analysis.
///
/// Needs exactly two members of `PDFReportGenerator`: the report config and
/// the page-break helper. Nothing about the deep-dive pages reaches into the
/// generator's drawing state.
///
/// Holds its owner strongly and is built on demand by the generator — a
/// value with no state of its own, so nothing here can outlive what it
/// points at.
struct DeepDiveReportRenderer {
    let generator: PDFReportGenerator

    var config: PDFReportGenerator.Config { generator.config }

    func ensureSpace(
        needed: CGFloat, y: CGFloat, pageNumber: inout Int,
        context: UIGraphicsPDFRendererContext, pageRect: CGRect
    ) -> CGFloat {
        generator.ensureSpace(
            needed: needed, y: y, pageNumber: &pageNumber,
            context: context, pageRect: pageRect
        )
    }
}
