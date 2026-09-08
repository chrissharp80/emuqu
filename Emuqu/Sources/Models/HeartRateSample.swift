import Foundation

/// One heart-rate reading with its provenance.
///
/// Replaces the 4-tuple `(date: Date, hr: Double, source: String, interval:
/// TimeInterval?)` spelled out in four places across `HealthKitManager` and the
/// assistant's fact resolver. Field names and meanings are unchanged, so every
/// `.date` / `.hr` / `.source` / `.interval` access reads as before.
///
/// `source` matters: the same minute can carry readings from the Watch, the
/// phone, and this app's own writes, and several call sites filter on it to
/// avoid double-counting samples Emuqu itself produced.
///
/// `interval` is `nil` for a discrete sample and set for one that represents a
/// span, which is how HealthKit models the Watch's aggregated windows.
struct HeartRateSample: Equatable, Sendable {
    /// Timestamp of the reading.
    let date: Date

    /// Heart rate in bpm.
    let hr: Double

    /// Originating device or app, as HealthKit reports it.
    let source: String

    /// Duration this reading covers, or `nil` for a point sample.
    let interval: TimeInterval?
}
