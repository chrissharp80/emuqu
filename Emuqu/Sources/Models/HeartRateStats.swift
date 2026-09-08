import Foundation

/// Summary statistics for a heart-rate window: the mean, the extremes, and
/// when the low point occurred.
///
/// Replaces the 4-tuple `(mean: Double, min: Double, max: Double, nadirTime:
/// Date)` that was written out longhand in nine places — `HealthKitManager`,
/// `HealthKitServiceProtocol`, `MockHealthKitService`, three `PDFReportGenerator`
/// signatures, `PDFReportGenerator+Sections`, and `MorningResultsView+Actions`.
/// Every one of those declarations had to be kept character-identical for the
/// types to match, so adding a field meant editing nine signatures and the
/// compiler could only tell you about the ones you missed.
///
/// The field names and their meanings are unchanged, so every `.mean` / `.min`
/// / `.max` / `.nadirTime` access at the call sites reads exactly as before.
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
