import Foundation

/// Converting a date interval into whole milliseconds, safely.
///
/// Holds the one copy of a conversion needed in two places —
/// `ImportSleepWindow` for HealthKit sleep boundaries, and
/// `RRCollector` for overnight segment merging. Both take two dates that came
/// off disk, and a bare `Int64(interval * 1000)` there:
///
///   * TRAPS on a non-finite or out-of-range value. The dates come from a
///     backup file or a HealthKit query, so "cannot happen" is not available.
///   * TRUNCATES rather than rounds. Date arithmetic drifts in binary floating
///     point, so a genuine 1.234 s gap arrives as 1233.9999 ms and loses a
///     millisecond off every conversion.
enum MillisecondOffset {
    /// Beyond a century either way this is not a session boundary, it is
    /// corrupt input. Clamping would invent a plausible-looking value; nil
    /// lets the caller say it does not know.
    static let representableLimitMs: Double = 100 * 365.25 * 24 * 60 * 60 * 1000

    /// Whole milliseconds between two dates, or nil when the interval cannot
    /// be represented.
    static func between(_ later: Date, and earlier: Date) -> Int64? {
        milliseconds(from: later.timeIntervalSince(earlier))
    }

    /// Whole milliseconds between two dates, falling back to `fallback` when
    /// the interval cannot be represented.
    ///
    /// For the call sites that need a plain `Int64` — a struct field, an
    /// arithmetic expression — where propagating an optional would mean
    /// reshaping the surrounding code for a case that only arises from a
    /// corrupt stored date. The fallback is explicit at the call site so the
    /// choice is visible rather than hidden inside this helper.
    static func between(_ later: Date, and earlier: Date, fallback: Int64) -> Int64 {
        between(later, and: earlier) ?? fallback
    }

    /// Whole milliseconds for a seconds interval, or nil when it cannot be
    /// represented. Rounds; see the type note for why.
    static func milliseconds(from seconds: TimeInterval) -> Int64? {
        let ms = seconds * 1000
        // Every comparison against NaN is false, so this rejects NaN and
        // infinity without a separate `isFinite` check.
        guard ms >= -representableLimitMs, ms <= representableLimitMs else { return nil }
        return Int64(ms.rounded())
    }
}
