import Foundation
import PDFKit
import UIKit

/// The body sections of the PDF report and the charts inside them: the
/// Poincaré plot, the PSD graph, the tachogram, the metric grids and the
/// score-breakdown blocks.
///
/// Split out of `PDFReportGenerator`: 1,353 lines needing six members
/// of the generator — the config, the settings
/// provider, and four drawing primitives that live in `+Helpers` and belong to
/// the generator's own vocabulary.
///
/// Holds its owner strongly and is built on demand by the generator — a
/// value with no state of its own, so nothing here can outlive what it
/// points at.
struct ReportSectionRenderer {
    let generator: PDFReportGenerator

    var config: PDFReportGenerator.Config { generator.config }
    var settingsProvider: () -> UserSettings { generator.settingsProvider }

    func drawSectionHeading(_ text: String, yPosition: CGFloat, pageRect: CGRect) -> CGFloat {
        generator.drawSectionHeading(text, yPosition: yPosition, pageRect: pageRect)
    }

    func drawCompactMetricsGrid(
        _ metrics: [(String, String)], yPosition: CGFloat, pageRect: CGRect
    ) -> CGFloat {
        generator.drawCompactMetricsGrid(metrics, yPosition: yPosition, pageRect: pageRect)
    }

    func computeSimplePSD(
        series: RRSeries, flags: [ArtifactFlags], windowStart: Int, windowEnd: Int
    ) -> [(Double, Double)] {
        generator.computeSimplePSD(
            series: series, flags: flags, windowStart: windowStart, windowEnd: windowEnd
        )
    }

    func diagnosticColorForScore(_ score: Double) -> UIColor {
        generator.diagnosticColorForScore(score)
    }
}
