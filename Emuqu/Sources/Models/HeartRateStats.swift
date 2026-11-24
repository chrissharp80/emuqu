import Foundation

/// Summary statistics for a heart-rate window: the mean, the extremes, and
/// when the low point occurred.
///
/// A named type rather than a tuple, so the HealthKit service, its mock and
/// the PDF report share one declaration and can gain a field in one place.
///
/// `nadirTime` is the timestamp of the minimum, not of the mean: the overnight
/// analysis cares *when* the low point landed, because a nadir early in the
/// night reads differently from one just before waking.
struct HeartRateStats: Equatable, Sendable {
    /// Mean heart rate over the window, in bpm.
    let mean: Double

    /// Lowest heart rate observed in the window, in bpm.
    let min: Double

    /// Highest heart rate observed in the window, in bpm.
    let max: Double

    /// Timestamp of the ``min`` sample.
    let nadirTime: Date
}
