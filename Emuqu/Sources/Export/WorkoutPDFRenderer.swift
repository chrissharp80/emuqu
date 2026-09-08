import CoreGraphics
import CoreLocation
import Foundation
import MapKit
import PDFKit
import UIKit

/// Everything that puts ink on the page for a workout PDF: the page layouts,
/// the charts, the physiology panels, and the formatting helpers they share.
///
/// ## Why this is not on `WorkoutPDFReport`
///
/// As three extensions on `WorkoutPDFReport` this was ~1,600 lines of a
/// ~1,900-line type; what remains there is the
/// class itself — the session, the track, the config, and the public entry
/// point that produces a document.
///
/// Putting the drawing in its own FILE satisfies the 1500-line
/// file budget, but the aggregate type-size gate counts a type across all its
/// files, so a separate type is what keeps the lines off `WorkoutPDFReport`.
///
/// All three live together on purpose: the page layouts, the charts and the
/// physiology panels call each other's formatting helpers constantly
/// (`drawText`, `formatDuration`, `downsample`). Splitting them one at a time
/// would mean a forwarder for each of those crossings; together, they
/// resolve internally and only nine names need to stay reachable from outside.
///
/// Holds its owner strongly and is built on demand by the report — a
/// value with no state of its own, so nothing here can outlive what it
/// points at.
struct WorkoutPDFRenderer {
    let report: WorkoutPDFReport

    /// The physiology panels.
    var physiology: WorkoutPDFPhysiologyPages {
        WorkoutPDFPhysiologyPages(renderer: self)
    }

}
