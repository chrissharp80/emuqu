import Foundation

// MARK: - Workout α1 Re-analyzer
//
// Post-hoc regeneration of per-sample α1 values on an archived workout
// session. Exists to repair sessions recorded before the artifact-
// filtering fix in `LiveDFAAnalyzer.cleanRRForDFA()` shipped: those
// sessions carry α1 values that are artefact-contaminated (Brownian-
// range 1.5-2.0 throughout exercise, instead of dropping toward
// LT1/LT2 as HR climbed).
//
// Method:
//   1. Iterate a 2-minute rolling window over the session's RRSeries
//      (same window as the live analyzer — `LiveDFAAnalyzer.windowSec`).
//   2. At each 20-second recompute cadence (matching live), apply the
//      same Kubios-style ectopic-beat filter and linear-interpolation
//      correction the live path now uses.
//   3. Feed the cleaned window into `DFAAnalyzer.compute()` to obtain
//      α1 + R². Emit (offsetSec, alpha1) pairs.
//   4. Replace `WorkoutSample.alpha1` on the session's samples with the
//      regenerated value from the nearest in-time recompute.
//
// This runs off-thread and takes ~100 ms for a 60-minute session
// (~200 recompute windows × ~250 beats each), so it can safely run
// on a background task and the result is re-archived when done.
//
// Scientific notes:
//   • We preserve the beat count by using linear interpolation across
//     artefact runs rather than deletion — otherwise DFA's box-size
//     accounting shifts and α1 biases downward. Kubios recommends
//     interpolation for HRV-grade analysis; deletion is only used when
//     the series is so noisy that interpolation risks fabricating
//     structure.
//   • The window size (120 s), cadence (20 s) and artifact-rejection
//     threshold (`LiveDFAAnalyzer.maxCorrectedFraction`) all match live.
//     Running the exact same math offline vs. live means a user
//     re-analysing an old session gets numbers directly comparable to
//     any new session. Two details make that claim hold: this type
//     requires a genuine 120 s window (the sweep starts at t = windowSec)
//     and the LIVE analyzer gates on elapsed time as well as beat count
//     (64 beats alone at HR 160 is ~24 s); and both sides gate artifact
//     load on the corrected fraction, not a beat-count comparison that
//     cannot fire.
enum WorkoutAlpha1Reanalyzer {
    struct Reading {
        let offsetSec: Int
        let alpha1: Double
        let fitQualityR2: Double
    }

    /// Re-run α1 on the raw RR series stored with the session. Returns
    /// an array of `(offsetSec, alpha1)` pairs at the same 20-second
    /// cadence the live analyzer uses. Empty if the session lacks a
    /// strap-grade RR series (e.g. watch-only workout).
    ///
    /// Two-pointer sweep instead of a per-window filter.
    /// Windows OVERLAP here (advance by cadenceSec, span
    /// windowSec), but both bounds still advance monotonically each tick,
    /// so the forward-only cursors give identical membership in O(n) total
    /// rather than O(windows × n).
    ///
    /// Windows are cut on the gap-corrected timeline
    /// (`WorkoutAnalyzer.gapCorrectedOffsetsMs`), the same wall-clock seconds
    /// the workout samples are stamped in, so readings after a Bluetooth
    /// dropout land on the samples they describe.
    static func reanalyze(
        session: HRVSession,
        windowSec: TimeInterval = 120,
        cadenceSec: TimeInterval = 20,
        minBeatsForFit: Int = 64
    ) -> [Reading] {
        guard let rrPoints = session.rrSeries?.points, rrPoints.count >= minBeatsForFit else { return [] }
        let timeline = wallClockTimeline(rrPoints)
        let sessionDuration = session.duration ?? Double(timeline.last?.t_ms ?? 0) / 1000.0
        guard sessionDuration > windowSec else { return [] }
        var readings: [Reading] = []
        var sweep = RRWindowSweep(timeline)
        // Run the analyzer at each cadence tick: sample α1 at t=windowSec,
        // t=windowSec+cadenceSec, t=windowSec+2·cadenceSec, ...
        var t: Double = windowSec
        while t <= sessionDuration {
            // Slice RR points whose t_ms falls within this window.
            let range = sweep.range(start: Int64((t - windowSec) * 1000), end: Int64(t * 1000))
            if let reading = fit(Array(timeline[range]), atOffsetSec: t, minBeatsForFit: minBeatsForFit) {
                readings.append(reading)
            }
            t += cadenceSec
        }
        return readings
    }

    /// The beats re-stamped onto the gap-corrected (wall-clock) timeline.
    private static func wallClockTimeline(_ rrPoints: [RRPoint]) -> [RRPoint] {
        zip(rrPoints, WorkoutAnalyzer.gapCorrectedOffsetsMs(rrPoints)).map { point, offsetMs in
            RRPoint(t_ms: offsetMs, rr_ms: point.rr_ms, wallClockMs: point.wallClockMs, hr: point.hr)
        }
    }

    /// α1 for one window's worth of RR points, or nil when the window cannot
    /// support a fit — too few beats, or too much of it artifact-corrected.
    ///
    /// The artifact guard must not be `cleaned.count >=
    /// minBeatsForFit`: the line above already proves that, because cleaning
    /// interpolates in place and cannot shorten the series. As a tautology it
    /// lets a window that is 40 % invented produce a Reading indistinguishable
    /// from a clean one, which `applyReadings` then writes over the archived
    /// session. The guard is on the corrected FRACTION, at the same
    /// threshold the live analyzer uses — which is the point, since this type
    /// exists to reproduce the live path offline.
    private static func fit(
        _ windowPoints: [RRPoint], atOffsetSec t: Double, minBeatsForFit: Int
    ) -> Reading? {
        guard windowPoints.count >= minBeatsForFit else { return nil }
        let cleaned = LiveDFAAnalyzer.cleanRRForDFA(windowPoints.map { Double($0.rr_ms) })
        guard cleaned.correctedFraction <= LiveDFAAnalyzer.maxCorrectedFraction,
              let result = DFAAnalyzer.compute(cleaned.values) else {
            return nil
        }
        return Reading(offsetSec: Int(t), alpha1: result.alpha1, fitQualityR2: result.alpha1R2)
    }

    /// Overwrite `alpha1` on every WorkoutSample in the provided series
    /// with the latest re-analyzed reading at or before it, but only while
    /// that reading is current — less than one cadence step old. Samples in
    /// the warm-up period, or inside a stretch whose windows were rejected
    /// (too noisy, too few beats), get their α1 cleared (nil) rather than
    /// inherit a value from minutes earlier.
    static func applyReadings(
        _ readings: [Reading],
        to samples: [WorkoutSample],
        cadenceSec: Int = 20
    ) -> [WorkoutSample] {
        guard !readings.isEmpty else { return samples }
        let sorted = readings.sorted { $0.offsetSec < $1.offsetSec }
        var next = 0
        return samples.map { s in
            // Samples are in time order, so the cursor only moves forward.
            while next < sorted.count, sorted[next].offsetSec <= s.offsetSec { next += 1 }
            guard next > 0, s.offsetSec - sorted[next - 1].offsetSec < cadenceSec else { return s.withAlpha1(nil) }
            return s.withAlpha1(sorted[next - 1].alpha1)
        }
    }
}
