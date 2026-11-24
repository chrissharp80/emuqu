import Foundation

// Finalize lives in `WorkoutFinalizer`; these forwarders give
// `WorkoutRecorder` callers the same entry points.

extension WorkoutRecorder {
    /// The finalize subsystem. Lazy — built when a workout ends.
    var finalizer: WorkoutFinalizer {
        WorkoutFinalizer(recorder: self)
    }

    func finalizeSession(
        rrPoints: [RRPoint],
        stopDate: Date,
        hrrSamples: [HRRSample]
    ) async -> HRVSession {
        await finalizer.finalizeSession(
            rrPoints: rrPoints, stopDate: stopDate, hrrSamples: hrrSamples
        )
    }
}
