import SwiftUI

/// The α1 report card of the post-workout summary: the α1 chart with its
/// ectopic-shadow marks, the plain-English summary, the band totals and the
/// α1-banded route map.
///
/// Split out of `FitnessPostSummaryView`, like `ThresholdCards`. 756 lines
/// that need one thing from the view — the session — which is what makes
/// this a seam worth cutting.
///
/// Deliberately NOT a `View`, for the same reason as [ThresholdCards]: it
/// returns the same view trees the extension returned, so SwiftUI view
/// identity, animation and `@State` behaviour are unchanged.
@MainActor
struct Alpha1ReportCards {
    let session: HRVSession
}
