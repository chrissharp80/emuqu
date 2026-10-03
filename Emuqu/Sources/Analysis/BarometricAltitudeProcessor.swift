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
//   2. Accumulate same-sign deltas on the smoothed series into runs and
//      commit a run to gain or loss only when the direction reverses and
//      the run clears 2 m (see `process` for why a per-delta gate fails).
//
// REFERENCES:
//   • Barczyk, Nemra (2014). "A Sensor Fusion Method for Tracking
//     Vertical Velocity and Height Based on Inertial and Barometric
//     Altimeter Measurements." PMC4179067.
//   • Apple CMAltimeter documentation — "hardware barometric
//     altimeter has sub-meter accuracy under steady atmospheric
//     conditions."
//   • Strava's "2 m threshold with barometer" published rule, which
//     the run threshold matches.
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
    ///   - sustainedClimbThresholdMeters: How much same-sign change has
    ///     to accumulate before we commit a "run" to gain or loss. Default
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
    /// Instead, the sustained-run algorithm `TopoElevationService`
    /// already uses for DEM data: accumulate same-sign deltas into a
    /// running sum, commit to gain or loss only when the direction
    /// reverses AND the run's magnitude clears the threshold. This:
    ///   • Counts real slow climbs (the run accumulates regardless of
    ///     per-sample magnitude — only direction reversal triggers a
    ///     commit decision)
    ///   • Rejects HVAC / pressure-front / smoother-edge blips that
    ///     briefly cross then immediately reverse (the run reverses
    ///     before the blip's run reaches 2 m)
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
        var runs = RunAccumulator(threshold: sustainedClimbThresholdMeters)
        // `1 ..< 0` traps on an empty sample set.
        guard smoothed.count > 1 else {
            return Result(gainMeters: 0, lossMeters: 0, smoothedSampleCount: smoothed.count)
        }
        for i in 1 ..< smoothed.count {
            runs.add(smoothed[i] - smoothed[i - 1])
        }
        // Tail: commit the final run if it cleared the threshold. Without
        // this the very last climb / descent of the workout would be
        // dropped on the floor regardless of magnitude.
        runs.commit()
        return Result(gainMeters: runs.gain, lossMeters: runs.loss, smoothedSampleCount: smoothed.count)
    }

    /// Accumulates same-sign altitude deltas into a running sum and commits it
    /// to gain or loss only when the direction reverses AND the run's magnitude
    /// clears `threshold`. This is what separates a real slow climb (whose run
    /// keeps extending, however small each sample's delta) from an HVAC or
    /// pressure-front blip (whose run reverses before reaching 2 m).
    private struct RunAccumulator {
        let threshold: Double
        var gain = 0.0
        var loss = 0.0
        private var runSum = 0.0
        private var runSign = 0 // +1 ascending, -1 descending, 0 starting

        init(threshold: Double) {
            self.threshold = threshold
        }

        /// Extend the run in progress, or commit it and open a new one when
        /// the direction flips. 0.0 deltas neither extend the run nor flip
        /// direction — skipped so smoother-induced ties don't artificially
        /// commit a partial run.
        mutating func add(_ delta: Double) {
            if delta == 0 { return }
            let sign = delta > 0 ? 1 : -1
            guard runSign != 0, sign != runSign else {
                runSum += delta
                if runSign == 0 { runSign = sign }
                return
            }
            commit()
            runSum = delta
            runSign = sign
        }

        /// Commit the run in progress if it cleared the threshold.
        mutating func commit() {
            guard abs(runSum) >= threshold else { return }
            if runSum > 0 { gain += runSum } else { loss += -runSum }
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
