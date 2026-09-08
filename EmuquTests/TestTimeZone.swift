import Foundation

/// Fixed time zones for tests.
///
/// Fifteen suites pinned `NSTimeZone.default` with a force-unwrapped
/// `TimeZone(identifier:)` lookup. The force-unwrap is provably safe — "UTC"
/// is always in the tz database — but a force-unwrap inside a test target is
/// worse than it looks: it traps, and a trap takes down the whole test
/// *process*, so one bad fixture turns into a run that reports nothing rather
/// than one red case.
///
/// `TimeZone.gmt` is the obvious escape, but it carries the identifier "GMT",
/// and suites that assert on formatted date strings can see that difference.
/// So this keeps "UTC" exactly and only removes the trap.
enum TestTimeZone {
    /// UTC, falling back to GMT (same zero offset) if the tz database ever
    /// fails to produce it.
    static let utc: TimeZone = TimeZone(identifier: "UTC") ?? .gmt

    /// US Eastern — used by the suites that assert on wall-clock behaviour
    /// across a DST boundary, where UTC would hide the thing under test.
    static let newYork: TimeZone = TimeZone(identifier: "America/New_York") ?? .gmt
}
