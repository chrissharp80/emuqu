import Foundation

// The recorder's work, by job. Each is a value built on each access around
// this recorder; callers name the job they ask for.

extension WorkoutRecorder {
    /// The once-per-second loop over the live signals.
    var ticker: WorkoutTicker {
        WorkoutTicker(recorder: self)
    }

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
            session: lifecycle.currentSession, startDate: sessionStartDate,
            samples: workoutSamples, wristHROffsets: wristHROffsets, liveSnapshot: liveSnapshotAtStop,
            pauseTimeline: lifecycle.pauseTimeline, pausedMotion: lifecycle.pausedMotion,
            elapsedSeconds: lifecycle.elapsedSeconds, activeHRSource: lifecycle.activeHRSource,
            location: startedLocation, pedometerDistanceMeters: pedometer.distanceMeters,
            footPodDistanceMeters: footPodDistanceMeters(), motionDistanceMeters: motion.distanceMeters,
            power: power, routeName: route.planned?.name
        )
    }

    /// The live context the coach is given.
    var aiContext: WorkoutAIContextBuilder {
        WorkoutAIContextBuilder(recorder: self)
    }

    typealias HRArbitration = WorkoutTicker.HRArbitration

    static func sportFTP(for sport: Sport, settings: UserSettings) -> Int? {
        WorkoutAIContextBuilder.sportFTP(for: sport, settings: settings)
    }
}
