import Foundation

/// Merging a workout's RR intervals from the two places they can arrive.
///
/// ## Why this exists
///
/// A workout can bounce between an iPhone-paired strap and a Watch-routed one —
/// the user walks away from the phone, the Watch takes over the BLE link, they
/// come back. Both paths buffer RR intervals, and finalize has to turn them into
/// one coherent series before any analysis runs.
///
/// Merge it wrong and every HRV number for that workout is computed on a
/// corrupted series: out-of-order intervals turn into enormous successive
/// differences, which is exactly what RMSSD squares.
///
/// Its own type rather than part of `WorkoutRecorder+Stop.swift`, where it
/// was reachable only by finishing a real workout and so untested.
enum WorkoutRRMerge {
    /// The RR series for a finishing workout.
    ///
    /// - Parameters:
    ///   - source: the HR source the workout actually ran on. `.watch` and
    ///     `.none` never started a strap stream, so that buffer is not theirs to
    ///     read — it may still hold points from a previous session.
    ///   - streaming: the strap stream's buffer.
    ///   - watchRouted: RR that arrived via the Watch direct-strap fallback.
    ///
    /// Watch-routed points are merged whatever the source, because that path can
    /// deliver strap data the phone never saw.
    ///
    /// The sort is applied only when there is something to interleave. With no
    /// Watch-routed points the streaming buffer is returned as-is, which
    /// preserves the existing behaviour: it is already ordered by construction,
    /// and re-sorting a long series on every finalize is work for nothing.
    static func merged(
        source: WorkoutRecorder.HRSource,
        streaming: [RRPoint],
        watchRouted: [RRPoint]
    ) -> [RRPoint] {
        var points: [RRPoint] = source == .strap ? streaming : []
        guard !watchRouted.isEmpty else { return points }
        points.append(contentsOf: watchRouted)
        points.sort { $0.t_ms < $1.t_ms }
        return points
    }
}
