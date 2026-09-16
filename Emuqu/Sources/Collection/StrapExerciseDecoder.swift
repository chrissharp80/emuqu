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
    static func exerciseId(at date: Date = Date(), timeZone: TimeZone = .current) -> String {
        exerciseIdFormatter(timeZone: timeZone).string(from: date)
    }

    /// When a recording started, read back from the id it is filed under.
    ///
    /// The SDK gives an H10 exercise no recording time of its own: its entry
    /// `date` is the moment the list was read. The id is this app's start
    /// stamp, so it is the only record of when the recording began. Nil for an
    /// id this app did not write.
    static func recordingStart(fromExerciseId id: String, timeZone: TimeZone = .current) -> Date? {
        guard id.count == 14, id.allSatisfy({ ("0" ... "9").contains($0) }) else { return nil }
        return exerciseIdFormatter(timeZone: timeZone).date(from: id)
    }

    /// The most recent recording that started no earlier than `notBefore`.
    ///
    /// A strap can hold a recording from an earlier session — the night before,
    /// or a workout whose file was never cleared. Taking whichever the strap
    /// lists first scores that old file as tonight's. Ids this app did not
    /// write have no start time and are only chosen when nothing is required.
    static func newestRecording<Entry>(
        _ entries: [Entry],
        exerciseId: (Entry) -> String,
        notBefore: Date?,
        timeZone: TimeZone = .current
    ) -> Entry? {
        let dated = entries.compactMap { entry in
            recordingStart(fromExerciseId: exerciseId(entry), timeZone: timeZone).map { (entry, $0) }
        }
        guard let notBefore else {
            return dated.max { $0.1 < $1.1 }?.0 ?? entries.first
        }
        return dated.filter { $0.1 >= notBefore }.max { $0.1 < $1.1 }?.0
    }

    private static func exerciseIdFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter
    }

    /// Total duration of a beat series, in seconds.
    static func durationSeconds(of points: [RRPoint]) -> TimeInterval {
        TimeInterval(points.reduce(Int64(0)) { $0 + Int64($1.rr_ms) }) / 1000
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
