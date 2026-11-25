import Foundation

/// How fresh the live heart rate and speed are: when the strap last sent a
/// beat, whether the rate on display is the Watch's wrist HR, and the live
/// pace. The ticker writes it each second; start clears it.
@Observable
@MainActor
final class WorkoutLiveSignals {
    /// True while the heart rate on display is the Apple Watch's wrist HR
    /// (read from its HealthKit workout session) rather than the strap's.
    /// Set by the tick's HR arbitration; a strap reading clears it.
    @ObservationIgnored var hrFromWrist = false
    /// Wall-clock of the most recent strap-derived HR reading. When more
    /// than ~10 s stale, we fall back to the Watch's wrist HR.
    var lastStrapHRAt: Date?
    /// Live speed, fed once per tick by the ticker. Every live consumer of
    /// pace or speed reads it through `currentPaceSecPerKm` / `currentSpeedMS`
    /// (see `LivePaceEstimator` for how it is measured).
    var livePace = LivePaceEstimator()

    /// The pace shown and spoken now; nil while paused, stopped or not yet measured.
    var currentPaceSecPerKm: Double? { livePace.paceSecPerKm }
    /// The speed behind `currentPaceSecPerKm`, in m/s.
    var currentSpeedMS: Double? { livePace.speedMS }

    /// Seconds since the strap's last beat. Only meaningful when the strap is
    /// the selected source — on watch/none there is no strap silence to report.
    func strapSilentSeconds(source: WorkoutRecorder.HRSource) -> Double? {
        guard source == .strap, let last = lastStrapHRAt else { return nil }
        return Date().timeIntervalSince(last)
    }
}
