import Foundation

// The finalizer, built at Stop from what the recorder holds then. The
// recorder's other parts are owned and built once (`WorkoutRecorder.swift`).

extension WorkoutRecorder {
    /// Assembling the finished session and archiving it, from what this
    /// recorder holds now.
    var finalizer: WorkoutFinalizer {
        WorkoutFinalizer(
            recording: finalizerRecording(), settings: settingsProvider(),
            core: core, services: services, sessionLifecycle: session
        )
    }

    private func finalizerRecording() -> WorkoutFinalizer.Recording {
        WorkoutFinalizer.Recording(
            session: lifecycle.currentSession, startDate: lifecycle.sessionStartDate,
            samples: capture.workoutSamples, wristHROffsets: capture.wristHROffsets, liveSnapshot: lifecycle.liveSnapshotAtStop,
            pauseTimeline: lifecycle.pauseTimeline, pausedMotion: lifecycle.pausedMotion,
            elapsedSeconds: lifecycle.elapsedSeconds, activeHRSource: lifecycle.activeHRSource,
            location: startedLocation, pedometerDistanceMeters: pedometer.distanceMeters,
            footPodDistanceMeters: sensors.footPodDistanceMeters(), motionDistanceMeters: motion.distanceMeters,
            power: capture.power, routeName: route.planned?.name
        )
    }

    typealias HRArbitration = WorkoutTicker.HRArbitration
}
