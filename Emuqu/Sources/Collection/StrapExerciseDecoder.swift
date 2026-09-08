import Foundation

/// Turning an H10 exercise recording into a beat series.
///
/// The strap stores a night as a flat list of RR intervals in milliseconds with
/// no timestamps; the timeline is reconstructed by accumulating them.
///
/// ## No quality filter here, unlike the optical path
///
/// `StrapPPIFilter` drops intervals outside 300–2000 ms because optical sensing
/// degrades with motion and contact. This path does not, and that asymmetry is
/// deliberate: the H10 is ECG-derived and its intervals are trustworthy enough
/// that filtering here would discard real ectopic beats — which the analysis
/// pipeline's artifact detection is built to recognise and correct in context,
/// with the whole series in view. Dropping them at the transport would hide them
/// from the layer whose job it is to judge them.
///
/// Kept outside `PolarManager` and its `#if canImport(PolarBleSdk)` so tests
/// can reach it without the SDK — this conversion produces every beat of an
/// overnight H10 recording and must not go untested.
enum StrapExerciseDecoder {
    /// The identifier the H10 files a recording under.
    ///
    /// A fixed-width local timestamp, so recordings sort chronologically by
    /// name on the device. `DateFormatter` with an explicit format is
    /// locale-sensitive by default — a user on a non-Gregorian calendar would
    /// otherwise get an id the strap cannot round-trip — so the locale is
    /// pinned to POSIX.
    static func exerciseId(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: date)
    }

    /// Beats from the strap's raw interval list.
    ///
    /// Each beat is stamped at the accumulated duration of the beats before it,
    /// so `t_ms` starts at zero and the series is monotonic by construction.
    static func rrPoints(fromIntervalsMs intervals: [Int]) -> [RRPoint] {
        var points: [RRPoint] = []
        points.reserveCapacity(intervals.count)
        var cumulativeMs: Int64 = 0
        for interval in intervals {
            points.append(RRPoint(t_ms: cumulativeMs, rr_ms: interval))
            cumulativeMs += Int64(interval)
        }
        return points
    }
}
