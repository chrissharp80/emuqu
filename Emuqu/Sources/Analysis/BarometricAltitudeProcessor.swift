import Foundation

// MARK: - Barometric Altitude Processor
//
// Post-hoc elevation-gain / loss computation from raw iPhone barometer
// samples (CMAltimeter.relativeAltitude). Runs once at session finalize
// time over the full sample buffer collected by WorkoutLocationManager.
//
// ─────────────────────────────────────────────────────────────────
// WHY POST-HOC INSTEAD OF LIVE-ACCUMULATE:
//
// The naive approach — threshold-gate every incoming sample and add
// the delta to a running total — has three problems that this
// processor solves:
//
//  1. **Threshold-at-collect-time is lossy.** Once you drop a
//     sub-threshold delta, you can't get it back for re-processing
//     with a different filter later. Collecting raw samples preserves
//     the signal so the final algorithm can be upgraded without
//     re-recording.
//  2. **Noise bias.** Per-sample deltas at ±0.5 m barometric noise
//     sum asymmetrically around a real trend (random walk bias is
//     √N × noise-per-sample). Smoothing BEFORE differencing removes
//     high-frequency noise without biasing the sustained trend.
//  3. **Discrimination.** A real climb shows up as a sustained
//     positive slope over ~10-30 seconds; sensor noise shows up as
//     high-frequency jitter. The smoother + small threshold matches
//     the physical signal (real climbs) to the filter's passband.
//
// ALGORITHM (based on sports-biomechanics sensor-fusion literature):
//
//   Input:  [(timestamp, relative_altitude_m)] raw barometer samples
//   Output: (gainMeters, lossMeters)
//
//   1. Moving-average smoother with a 15-sample window
//      (≈ 15 seconds at 1 Hz — matches τ ≈ 8 s complementary-filter
//      time constant cited in Barczyk & Nemra 2014, "Sensor Fusion
//      Method for Tracking Vertical Velocity and Height Based on
//      Inertial and Barometric Altimeter Measurements", PMC4179067).
//      The symmetric moving average acts as the low-pass stage that
//      a complementary filter's barometric branch would — same
//      physical intent, simpler to reason about, zero phase lag
//      when applied offline.
//
//   2. Hysteresis on the smoothed series: a climb or descent is committed
//      to gain or loss once the altitude turns back from its extreme by
//      2 m (see `process` for why a per-delta gate fails).
//
// REFERENCES:
//   • Barczyk, Nemra (2014). "A Sensor Fusion Method for Tracking
//     Vertical Velocity and Height Based on Inertial and Barometric
//     Altimeter Measurements." PMC4179067.
//   • Apple CMAltimeter documentation — "hardware barometric
//     altimeter has sub-meter accuracy under steady atmospheric
//     conditions."
//   • Strava's "2 m threshold with barometer" published rule, which
//     the hysteresis threshold matches.
// ─────────────────────────────────────────────────────────────────
enum BarometricAltitudeProcessor {
    /// Processed elevation output.
    struct Result {
        let gainMeters: Double
        let lossMeters: Double
        /// Number of smoothed samples used in the integration pass.
        /// Surfaced for debug logs so regressions show in traces.
        let smoothedSampleCount: Int
    }

    /// Compute gain / loss from a buffer of raw barometric samples.
    /// - Parameters:
    ///   - samples: Time-ordered `(timestamp, relative_altitude_m)` pairs.
    ///   - smootherWindow: Moving-average window size. Default 15
    ///     samples ≈ 15 s at the CMAltimeter's 1 Hz rate, matching
    ///     the ~8 s complementary-filter time constant recommended
    ///     in the Barczyk & Nemra paper.
    ///   - sustainedClimbThresholdMeters: How far the altitude has to move
    ///     away from the last extreme before a climb or descent counts. Default
    ///     2.0 m — chosen to be ~15× the σ ≈ 0.13 m std-dev of the
    ///     smoothed barometric noise floor (the 15-sample MA reduces the
    ///     raw ±0.5 m σ by √15). Any sustained climb of even a single
    ///     meter is real signal; we use 2 m as the reject-cliff so HVAC
    ///     bursts and pressure-front blips that only briefly cross 1 m
    ///     don't accumulate.
    ///
    /// **Algorithm.** A per-delta gate — summing the smoothed signal's
    /// per-adjacent-pair deltas with a 1 m absolute-value gate — has two
    /// compounding failure modes:
    ///   1. **Slow climb undercount.** A real ascent of 200 m over 30 min
    ///      produces per-sample smoothed deltas of ~0.1 m. All <1 m, all
    ///      rejected. Result: 0 m gain on a real climb.
    ///   2. **Environmental noise overcount.** HVAC kicking on, a passing
    ///      truck, weather-front pressure changes, and edge artifacts of
    ///      the moving-average smoother all produce occasional smoothed
    ///      deltas above 1 m even when no real climb happened. Each one
    ///      adds 1-3 m of fake gain.
    ///
    /// Field reports of that gate: ~2.3× overcount on a real 117 m walk
    /// (385 ft real → 274 m / 900 ft reported). Same root cause across users.
    ///
    /// Instead, a hysteresis pass over the smoothed altitude: track the
    /// highest (or lowest) point of the current climb (or descent) and commit
    /// the climb only once the altitude has come back down from that extreme
    /// by the threshold. This:
    ///   • Counts real slow climbs, however small each sample's delta, and
    ///     however often noise makes a single smoothed delta negative: a
    ///     wobble smaller than the threshold never ends the climb
    ///   • Rejects HVAC / pressure-front / smoother-edge blips that
    ///     briefly cross then immediately reverse (they never move the
    ///     altitude the threshold away from the last extreme)
    ///   • Matches barometric ground truth on test sessions
    static func process(
        samples: [(timestamp: Date, altitudeMeters: Double)],
        smootherWindow: Int = 15,
        sustainedClimbThresholdMeters: Double = 2.0
    ) -> Result {
        guard samples.count >= smootherWindow else {
            return Result(gainMeters: 0, lossMeters: 0, smoothedSampleCount: 0)
        }
        let smoothed = movingAverage(samples.map(\.altitudeMeters), window: smootherWindow)
        guard let first = smoothed.first else {
            return Result(gainMeters: 0, lossMeters: 0, smoothedSampleCount: 0)
        }
        var runs = HysteresisAccumulator(threshold: sustainedClimbThresholdMeters, start: first)
        for level in smoothed.dropFirst() {
            runs.add(level)
        }
        // Tail: commit the final climb or descent. Without this the very last
        // one of the workout would be dropped on the floor.
        runs.finish()
        return Result(gainMeters: runs.gain, lossMeters: runs.loss, smoothedSampleCount: smoothed.count)
    }

    /// Hysteresis over altitude levels. Until a direction is established it
    /// tracks the lowest and highest level seen; once the altitude sits
    /// `threshold` above the low (or below the high) it is climbing (or
    /// descending) from there. A climb ends, and its full rise from the
    /// anchor to the peak is committed, only when the altitude falls
    /// `threshold` below the peak; descents mirror that.
    private struct HysteresisAccumulator {
        let threshold: Double
        var gain = 0.0
        var loss = 0.0
        private var direction = 0 // +1 climbing, -1 descending, 0 not yet known
        private var anchor: Double
        private var low: Double
        private var high: Double

        init(threshold: Double, start: Double) {
            self.threshold = threshold
            anchor = start
            low = start
            high = start
        }

        mutating func add(_ level: Double) {
            low = min(low, level)
            high = max(high, level)
            switch direction {
            case 1 where high - level >= threshold: turn(to: -1, at: level)
            case -1 where level - low >= threshold: turn(to: 1, at: level)
            case 0 where level - low >= threshold: start(1, from: low)
            case 0 where high - level >= threshold: start(-1, from: high)
            default: break
            }
        }

        /// Commit the climb or descent in progress.
        mutating func finish() {
            if direction == 1 { gain += high - anchor }
            if direction == -1 { loss += anchor - low }
        }

        private mutating func start(_ newDirection: Int, from extreme: Double) {
            direction = newDirection
            anchor = extreme
        }

        /// Commit the run that just ended at its extreme and start the
        /// opposite one from there.
        private mutating func turn(to newDirection: Int, at level: Double) {
            finish()
            anchor = newDirection == -1 ? high : low
            direction = newDirection
            low = min(level, anchor)
            high = max(level, anchor)
        }
    }

    /// Symmetric moving-average smoother. Preserves endpoint values
    /// (rather than zero-padding) so the first and last few samples
    /// don't collapse toward zero; just clamps the window to what's
    /// available at the boundary.
    private static func movingAverage(_ values: [Double], window: Int) -> [Double] {
        guard values.count >= window, window > 1 else { return values }
        let half = window / 2
        var out = [Double](repeating: 0, count: values.count)
        for i in 0 ..< values.count {
            let lo = max(0, i - half)
            let hi = min(values.count - 1, i + half)
            var sum = 0.0
            for j in lo ... hi { sum += values[j] }
            out[i] = sum / Double(hi - lo + 1)
        }
        return out
    }
}
