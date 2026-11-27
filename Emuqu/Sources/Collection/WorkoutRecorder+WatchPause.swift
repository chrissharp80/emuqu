import Foundation

// A Watch Pause is dated by the tap, which can reach the phone after it: a
// live send that failed is queued and delivered when the phone next wakes
// (`WatchSessionManager.queuedRequestLifetime`). The workout pauses at the
// tap, so the seconds the user stood still before it arrived are not counted
// as moving. A Watch Resume is applied when it arrives: while the phone held
// the workout paused it recorded no distance and took no samples, so counting
// that time as active would add time without the ground covered in it.

extension WorkoutRecorder {
    /// Pauses by hand, as the Watch asked, from `tappedAt` when that is
    /// earlier than `now` (`pauseDate(requested:since:now:)`): the pause
    /// begins at the tap and what was sampled after it is left out
    /// (`keepRecording(throughElapsed:)`). No-op unless recording and not
    /// already paused.
    func pauseFromWatch(tappedAt: Date?, now: Date = Date()) {
        guard case .recording = lifecycle.phase, !lifecycle.isPaused else { return }
        let resumedAt = lifecycle.pauseTimeline.events.last?.resumedAt
        pauseControl.pause(isAuto: false)
        guard let start = lifecycle.sessionStartDate else { return }
        let pausedAt = Self.pauseDate(requested: tappedAt, since: resumedAt ?? start, now: now)
        guard pausedAt < now else { return }
        let activeAtTap = min(lifecycle.elapsedSeconds, lifecycle.pauseTimeline.activeSeconds(sessionStart: start, now: pausedAt))
        lifecycle.pauseTimeline.movePauseStart(to: pausedAt, atElapsed: activeAtTap)
        keepRecording(throughElapsed: activeAtTap)
        debugLog("[WorkoutRecorder] Watch pause dated \(Int(now.timeIntervalSince(pausedAt))) s before it arrived: \(activeAtTap) s active")
    }

    /// When a Watch Pause begins: the tap held between the workout's last
    /// start or resume (`since`) and `now`, so it never reaches back into an
    /// earlier pause, or `now` when the Watch stamped no tap. The Watch's
    /// clock is not the phone's; a tap stamped ahead of the phone pauses now.
    nonisolated static func pauseDate(requested: Date?, since: Date, now: Date) -> Date {
        guard let requested else { return now }
        return min(max(requested, since), now)
    }

    /// Leaves out of the workout what was sampled after active second
    /// `elapsed`: the active count stops there, and the per-second samples,
    /// wrist-HR rows and power readings past it are dropped.
    func keepRecording(throughElapsed elapsed: Int) {
        lifecycle.elapsedSeconds = min(lifecycle.elapsedSeconds, elapsed)
        let kept = capture.workoutSamples.filter { $0.offsetSec <= lifecycle.elapsedSeconds }
        capture.workoutSamples = kept
        capture.wristHROffsets = capture.wristHROffsets.filter { $0 <= lifecycle.elapsedSeconds }
        capture.power = Self.powerTally(of: kept)
    }
}
