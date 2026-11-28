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
        let history = fullSampleHistory()
        return WorkoutFinalizer.Recording(
            session: lifecycle.currentSession, startDate: lifecycle.sessionStartDate,
            samples: history?.samples ?? capture.workoutSamples, wristHROffsets: history?.wristHROffsets ?? capture.wristHROffsets,
            liveSnapshot: lifecycle.liveSnapshotAtStop,
            pauseTimeline: lifecycle.pauseTimeline, pausedMotion: lifecycle.pausedMotion,
            elapsedSeconds: lifecycle.elapsedSeconds, activeHRSource: lifecycle.activeHRSource,
            location: startedLocation, pedometerDistanceMeters: pedometer.distanceMeters,
            footPodDistanceMeters: sensors.footPodDistanceMeters(), motionDistanceMeters: motion.distanceMeters,
            distanceCapMeters: capture.distanceAtEarlyStop,
            power: history.map { Self.powerTally(of: $0.samples) } ?? capture.power, routeName: route.planned?.name
        )
    }

    /// The whole workout's per-second rows when memory no longer holds its
    /// oldest ones (`WorkoutCapture.sampleHeadTrimmed`): those are read back
    /// from the crash backup, which wrote every row, and put before the rows
    /// held (`WorkoutSampleHistory.merged`). Nil when memory holds them all.
    /// The power tally is counted again over the merged rows, since a late
    /// stop or pause recounts it from the rows held (`keepRecording`); each
    /// row carries the reading the tally counted that second.
    func fullSampleHistory() -> WorkoutSampleHistory.Rows? {
        guard capture.sampleHeadTrimmed, let id = lifecycle.currentSession?.id,
              let backup = services.workoutTrackBackup.retrieve(id) else { return nil }
        let merged = WorkoutSampleHistory.merged(
            held: .init(samples: capture.workoutSamples, wristHROffsets: capture.wristHROffsets),
            backedUp: .init(samples: backup.samples, wristHROffsets: backup.healthKitHROffsets),
            through: lifecycle.elapsedSeconds
        )
        debugLog("[Recorder.finalize] \(merged.samples.count - capture.workoutSamples.count) early samples read back from the crash backup (memory held \(capture.workoutSamples.count))")
        return merged
    }

    typealias HRArbitration = WorkoutTicker.HRArbitration
}
