import Foundation
import PDFKit
import UIKit

// The generator's three page renderers. Each is a stateless value wrapping
// the generator, so they share its report config and page-break state:
// `ReportSectionRenderer` draws the body sections and owns the shared
// primitives (`ensureSpace`, `drawCompactStatBox`), `OvernightReportRenderer`
// draws the overnight pages and `DeepDiveReportRenderer` the deep-dive ones.

extension PDFReportGenerator {
    /// The body-section renderer. Every report draws body sections, so this is
    /// built on the first page rather than lazily deferred any further.
    var sections: ReportSectionRenderer {
        ReportSectionRenderer(generator: self)
    }

    /// The overnight page renderer: a stateless value wrapping `self`, built
    /// afresh on each access (not cached). Every report reaches it,
    /// if only through `diagnosticColorForScore`.
    var overnight: OvernightReportRenderer {
        OvernightReportRenderer(generator: self)
    }

    /// The deep-dive page renderer: a stateless value wrapping `self`, built
    /// afresh on each access (not cached). Only the deep-dive pages reach
    /// it, so a `.summary` report never builds one.
    var deepDive: DeepDiveReportRenderer {
        DeepDiveReportRenderer(generator: self)
    }
}
