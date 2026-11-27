import Foundation

// A Watch Pause or Resume is dated by the tap, which can reach the phone
// after it: a live send that failed is queued and delivered when the phone
// next wakes (`WatchSessionManager.queuedRequestLifetime`). The workout
// pauses at the tap, so the seconds the user stood still before it arrived
// are not counted as moving, and resumes at the tap, so the time moved before
// it arrived is. The ground covered in that time counts with it: the GPS
// fixes the phone kept while paused (`WorkoutLocationManager.moveResume`) and
// the motion counters as they stood at the tap (`PausedMotionLedger`). No
// per-second samples were taken while paused, so those seconds have none,
// as after any gap in the ticks.
//
// A control that arrives late is applied only when it was tapped after the
// last pause or resume the phone made (`controlIsCurrent`): a Pause tapped
// before the user resumed on the phone, or a Resume tapped before the pause
// now open, was already answered by that change. The tap is stamped by the
// Watch's clock, so a tap up to `watchClockTolerance` before the change
// still counts as after it.

extension WorkoutRecorder {
    /// Pauses by hand, as the Watch asked, from `tappedAt` when that is
    /// earlier than `now` (`pauseDate(requested:since:now:)`): the pause
    /// begins at the tap and what was sampled after it is left out
    /// (`keepRecording(throughElapsed:)`). No-op unless recording and not
    /// already paused, and for a Pause tapped before the last resume.
    func pauseFromWatch(tappedAt: Date?, now: Date = Date()) {
        guard case .recording = lifecycle.phase, !lifecycle.isPaused else { return }
        let resumedAt = lifecycle.pauseTimeline.events.last?.resumedAt
        guard Self.controlIsCurrent(tappedAt: tappedAt, lastChange: resumedAt) else {
            return debugLog("[WorkoutRecorder] Watch pause tapped before the workout last resumed: ignored")
        }
        pauseControl.pause(isAuto: false)
        guard let start = lifecycle.sessionStartDate else { return }
        let pausedAt = Self.pauseDate(requested: tappedAt, since: resumedAt ?? start, now: now)
        guard pausedAt < now else { return }
        let activeAtTap = min(lifecycle.elapsedSeconds, lifecycle.pauseTimeline.activeSeconds(sessionStart: start, now: pausedAt))
        lifecycle.pauseTimeline.movePauseStart(to: pausedAt, atElapsed: activeAtTap)
        keepRecording(throughElapsed: activeAtTap)
        debugLog("[WorkoutRecorder] Watch pause dated \(Int(now.timeIntervalSince(pausedAt))) s before it arrived: \(activeAtTap) s active")
    }

    /// Resumes by hand, as the Watch asked, from `tappedAt` when that is
    /// earlier than `now` (`resumeDate(requested:pausedAt:now:)`). No-op
    /// unless recording and paused, and for a Resume tapped before the pause
    /// began.
    func resumeFromWatch(tappedAt: Date?, now: Date = Date()) {
        guard case .recording = lifecycle.phase, lifecycle.isPaused,
              let pausedAt = lifecycle.pauseTimeline.openPauseStart else { return }
        guard Self.controlIsCurrent(tappedAt: tappedAt, lastChange: pausedAt) else {
            return debugLog("[WorkoutRecorder] Watch resume tapped before the open pause began: ignored")
        }
        let resumedAt = Self.resumeDate(requested: tappedAt, pausedAt: pausedAt, now: now)
        guard resumedAt < now else { return pauseControl.resume() }
        pauseControl.resume(at: resumedAt)
        startedLocation?.moveResume(to: resumedAt)
        debugLog("[WorkoutRecorder] Watch resume dated \(Int(now.timeIntervalSince(resumedAt))) s before it arrived")
    }

    /// Whether a Watch control tapped at `tappedAt` still acts on the state
    /// the phone is in: tapped at or after `lastChange`, the last pause or
    /// resume it would undo, less `watchClockTolerance`. One with no tap
    /// time, or with no change before it, applies.
    nonisolated static func controlIsCurrent(tappedAt: Date?, lastChange: Date?) -> Bool {
        guard let tappedAt, let lastChange else { return true }
        return tappedAt >= lastChange.addingTimeInterval(-watchClockTolerance)
    }

    /// How far the Watch's clock may run behind the phone's for a tap
    /// stamped just before a change (an auto-resume, say) to still count as
    /// made after it. A paired Watch takes its time from the phone, so they
    /// differ by well under a second; a control sent longer before the
    /// change than this was answered by it.
    nonisolated static let watchClockTolerance: TimeInterval = 2

    /// When a Watch Resume ends the pause: the tap held between the pause's
    /// start and `now`, or `now` when the Watch stamped no tap. A tap stamped
    /// ahead of the phone's clock resumes now; one before the pause, at its
    /// start.
    nonisolated static func resumeDate(requested: Date?, pausedAt: Date, now: Date) -> Date {
        guard let requested else { return now }
        return min(max(requested, pausedAt), now)
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
