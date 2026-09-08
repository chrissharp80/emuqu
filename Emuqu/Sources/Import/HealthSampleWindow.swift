import Foundation

/// One HealthKit measurement and the span of time it was measured over.
///
/// Apple Health reports almost nothing as an instant. A step count, a minute of
/// exercise, an average walking speed, a physical-effort reading — each is a
/// value attached to a window, and the window is half the meaning: 85 steps is
/// a different fact over thirty seconds than over ten minutes.
///
/// A named type rather than a bare `(start:end:count:)` tuple because the
/// reconstruction passes five different quantities through the same shape —
/// steps, exercise minutes, metres per second, METs, flights climbed — and a
/// field called `count` is a lie for three of them. `value` is honest about
/// carrying whatever unit its caller asked HealthKit for.
struct HealthSampleWindow: Sendable, Equatable {
    let start: Date
    let end: Date
    /// In whatever unit the query asked for. The caller owns the unit; this
    /// type deliberately does not, because pairing every window with an
    /// `HKUnit` would make it un-testable without HealthKit.
    let value: Double

    var duration: TimeInterval { end.timeIntervalSince(start) }

    init(start: Date, end: Date, value: Double) {
        self.start = start
        self.end = end
        self.value = value
    }
}
