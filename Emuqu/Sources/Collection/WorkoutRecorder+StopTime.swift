import Foundation

// When a workout ends. A stop from the iPhone ends it now; a Watch End is
// dated by the tap, which can reach the phone long after it when the Watch
// queued it out of range (`WatchSessionManager.queuedStopLifetime`). The
// workout ends at the tap, and what the phone recorded after it is left out.

extension WorkoutRecorder {
    /// The time the workout ends: the requested time held between the
    /// workout's start and `now`, or `now` when none was requested. The
    /// Watch's clock is not the phone's, so a tap stamped a moment ahead of
    /// the phone ends now, and one stamped before the start ends at the start.
    nonisolated static func stopDate(requested: Date?, startedAt: Date?, now: Date) -> Date {
        guard let requested else { return now }
        return min(max(requested, startedAt ?? requested), now)
    }

    /// Closes the pause timeline at `stopDate` and, for a stop dated earlier
    /// than `now`, cuts the recording there (`endRecording(at:)`). Returns
    /// whether it was cut.
    func settleStopTime(_ stopDate: Date, now: Date) -> Bool {
        guard stopDate < now, let start = lifecycle.sessionStartDate else {
            lifecycle.pauseTimeline.resume(now: stopDate)
            return false
        }
        lifecycle.pauseTimeline.end(at: stopDate, sessionStart: start)
        endRecording(at: stopDate, sessionStart: start)
        return true
    }

    /// Leaves out of the workout everything recorded after `stopDate`: the
    /// active seconds stop there, the per-second samples, wrist-HR rows and
    /// power readings past it are dropped (`keepRecording(throughElapsed:)`),
    /// the GPS track ends there, and the distance counters that hold no
    /// history are capped at the distance shown at the last sample kept
    /// (`WorkoutCapture.distanceAtEarlyStop`). The RR beats are cut in
    /// `gatherFinalRRPoints`.
    private func endRecording(at stopDate: Date, sessionStart: Date) {
        keepRecording(throughElapsed: lifecycle.pauseTimeline.activeSeconds(sessionStart: sessionStart, now: stopDate))
        let kept = capture.workoutSamples
        capture.distanceAtEarlyStop = kept.last { $0.distanceMeters != nil }?.distanceMeters ?? 0
        startedLocation?.endTrack(at: stopDate)
        debugLog("[Recorder.stop] ended at the requested time, \(Int(Date().timeIntervalSince(stopDate))) s before it arrived: kept \(kept.count) samples, \(lifecycle.elapsedSeconds) s active")
    }

    /// The power readings of `samples`: each per-second sample carries the
    /// reading the tally counted that second (the tally and the samples both
    /// skip paused seconds).
    nonisolated static func powerTally(of samples: [WorkoutSample]) -> WorkoutPowerTally {
        var tally = WorkoutPowerTally()
        for watts in samples.compactMap(\.powerWatts) { tally.add(watts) }
        return tally
    }
}
