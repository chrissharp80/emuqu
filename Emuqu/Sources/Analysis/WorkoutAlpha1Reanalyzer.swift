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
// Readings are timed on the beat (wall-clock) timeline, samples on active
// seconds, which stop while the workout is paused. The two agree only for a
// workout that was never paused, and the pause timeline is not stored, so a
// workout whose samples end well short of its wall-clock length (it was
// paused) is not re-analysed rather than have every later reading written
// onto the wrong sample.
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
        /// The recompute cadence the reading was produced at: how long after
        /// `offsetSec` it stays current for `applyReadings`.
        let cadenceSec: Int
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
    /// (`WorkoutAnalyzer.gapCorrectedOffsetsMs`), wall-clock seconds from the
    /// start, so readings after a Bluetooth dropout land on the samples they
    /// describe. Samples are stamped in ACTIVE seconds, which equal wall-clock
    /// seconds only while the workout was never paused; a paused workout
    /// (`wasPaused`) returns no readings, since without the pause timeline
    /// every reading after the first pause would land on the wrong sample.
    static func reanalyze(
        session: HRVSession,
        windowSec: TimeInterval = 120,
        cadenceSec: TimeInterval = 20,
        minBeatsForFit: Int = 64
    ) -> [Reading] {
        guard let rrPoints = session.rrSeries?.points, rrPoints.count >= minBeatsForFit,
              !wasPaused(session, toleranceSec: cadenceSec) else { return [] }
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
            if let reading = fit(Array(timeline[range]), atOffsetSec: t, cadenceSec: Int(cadenceSec), minBeatsForFit: minBeatsForFit) {
                readings.append(reading)
            }
            t += cadenceSec
        }
        return readings
    }

    /// Whether the workout's samples end more than `toleranceSec` short of its
    /// wall-clock length: active time stopped while paused, so the shortfall
    /// is the time spent paused. A shortfall within one cadence step moves a
    /// reading by less than the step it already stands for. False without
    /// samples or an end date (nothing to misplace, or nothing to compare).
    private static func wasPaused(_ session: HRVSession, toleranceSec: TimeInterval) -> Bool {
        guard let duration = session.duration,
              let lastOffset = session.workoutMetadata?.samples?.map(\.offsetSec).max() else { return false }
        let pausedSec = duration - TimeInterval(lastOffset)
        guard pausedSec > toleranceSec else { return false }
        debugLog("[Alpha1Reanalyze] samples end \(Int(pausedSec)) s short of the workout — paused; not re-analysing")
        return true
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
        _ windowPoints: [RRPoint], atOffsetSec t: Double, cadenceSec: Int, minBeatsForFit: Int
    ) -> Reading? {
        guard windowPoints.count >= minBeatsForFit else { return nil }
        let cleaned = LiveDFAAnalyzer.cleanRRForDFA(windowPoints.map { Double($0.rr_ms) })
        guard cleaned.correctedFraction <= LiveDFAAnalyzer.maxCorrectedFraction,
              let result = DFAAnalyzer.compute(cleaned.values) else {
            return nil
        }
        return Reading(offsetSec: Int(t), alpha1: result.alpha1, fitQualityR2: result.alpha1R2, cadenceSec: cadenceSec)
    }

    /// Overwrite `alpha1` on every WorkoutSample in the provided series
    /// with the latest re-analyzed reading at or before it, but only while
    /// that reading is current — less than one cadence step (the reading's
    /// own `cadenceSec`) old. Samples in the warm-up period, or inside a
    /// stretch whose windows were rejected (too noisy, too few beats), get
    /// their α1 cleared (nil) rather than inherit a value from minutes
    /// earlier. Samples may come in any order: each is looked up by binary
    /// search in the readings sorted by offset.
    static func applyReadings(_ readings: [Reading], to samples: [WorkoutSample]) -> [WorkoutSample] {
        guard !readings.isEmpty else { return samples }
        let sorted = readings.sorted { $0.offsetSec < $1.offsetSec }
        return samples.map { s in
            guard let reading = latestReading(atOrBefore: s.offsetSec, in: sorted),
                  s.offsetSec - reading.offsetSec < reading.cadenceSec else { return s.withAlpha1(nil) }
            return s.withAlpha1(reading.alpha1)
        }
    }

    /// The last reading with `offsetSec` at or before `offset` in readings
    /// sorted by offset, or nil when every reading is later.
    private static func latestReading(atOrBefore offset: Int, in sorted: [Reading]) -> Reading? {
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid].offsetSec <= offset { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? sorted[low - 1] : nil
    }
}
