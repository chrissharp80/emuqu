import CoreGraphics
import Foundation
import UIKit

/// The physiology pages of a workout report: the autonomic/HRV panel and the
/// cardiopulmonary panel.
///
/// The layout primitives these share with the other pages are on the
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
