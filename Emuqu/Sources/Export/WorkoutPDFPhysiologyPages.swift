import CoreGraphics
import Foundation
import UIKit

/// The physiology pages of a workout report: the autonomic/HRV panel and the
/// cardiopulmonary panel.
///
/// Split from `WorkoutPDFRenderer`. Moving all three drawing
/// extensions into one renderer took `WorkoutPDFReport` under 1,500 lines but
/// left the renderer itself at 1,562 — trading one oversized type for another.
/// The physiology panels are the most self-contained of the three, so they came
/// back out; the layout primitives they share with the other pages stayed on the
/// renderer, in `WorkoutPDFRenderer+Layout.swift`.
///
/// Holds its owner strongly and is built on demand by the renderer — a
/// value with no state of its own, so nothing here can outlive what it
/// points at.
struct WorkoutPDFPhysiologyPages {
    let renderer: WorkoutPDFRenderer

    /// The report's data and page config, reached through the renderer.
    var report: WorkoutPDFReport { renderer.report }

}
