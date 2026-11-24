import SwiftUI

/// The α1 report card of the post-workout summary: the α1 chart with its
/// ectopic-shadow marks, the plain-English summary, the band totals and the
/// α1-banded route map.
///
/// Deliberately not a `View`: it returns view trees into
/// `FitnessPostSummaryView`'s body, so SwiftUI view identity, animation and
/// `@State` stay those of the host view.
@MainActor
struct Alpha1ReportCards {
    let session: HRVSession
    /// Where computed α1 stats are kept between renders.
    let statsCache: Alpha1StatsCache
}
