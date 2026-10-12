import Foundation

// Finalize lives in `WorkoutFinalizer`, keeping ~600 lines off
// `WorkoutRecorder`, the largest type in the codebase.
//
// These forwarders keep every existing call site working.

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
