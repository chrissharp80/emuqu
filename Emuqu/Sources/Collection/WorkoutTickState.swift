import Foundation

/// How much of each live stream has already been written to the
/// crash-recovery backup.
///
/// One value rather than three cursors on `WorkoutRecorder`, because they
/// are only ever read and written together, one line apart: compare all
/// three, then assign all three. Kept as separate stored properties, a
/// future edit that advances two of them and forgets the third would
/// silently wedge one stream's backup — the counts would never match again
/// and that stream would snapshot on every tick, or never. As one value the
/// compare and the advance cannot come apart.
///
/// Comparison is `!=`, not `>`, on purpose: a second workout in the same app
/// session starts its streams back at zero, and a "has it grown" test would
/// then skip every snapshot until the new workout out-grew the old one.
struct TrackBackupWatermark: Equatable {
    private var trackCount = 0
    private var baroCount = 0
    private var samplesCount = 0

    /// True when at least one stream's count differs from what was last
    /// backed up — and, when it does, the watermark advances to the counts
    /// passed in, so the caller can snapshot without a second bookkeeping
    /// step to forget.
    mutating func advanceIfChanged(trackCount: Int, baroCount: Int, samplesCount: Int) -> Bool {
        guard trackCount != self.trackCount
            || baroCount != self.baroCount
            || samplesCount != self.samplesCount
        else { return false }
        self.trackCount = trackCount
        self.baroCount = baroCount
        self.samplesCount = samplesCount
        return true
    }
}

/// The stationary/moving run-lengths behind auto-pause and auto-resume.
///
/// Kept off `WorkoutRecorder`: two counters and the two
/// thresholds they are compared against are one mechanism, and holding them
/// apart on a 4,700-line class is how one counter ends up shared between
/// pause and resume. Separate counters are deliberate — the
/// thresholds differ (15 s to pause, 3 s to resume), and decrementing one
/// shared counter from "−15 stationary" back to zero makes resume feel draggy.
struct AutoPauseDetector: Equatable {
    /// Seconds of continuous low movement before auto-pause fires.
    /// Conservative — long enough that a traffic light or tying a shoe
    /// doesn't pause you, short enough that standing for a drink actually
    /// pauses the clock.
    static let stationarySecondsBeforeAutoPause = 15

    /// Seconds of movement before auto-resume fires. Short, so the clock
    /// picks up right when the runner takes off; a false positive here just
    /// restarts too early and the next tick's still-stationary reading
    /// pauses again.
    static let movingSecondsBeforeAutoResume = 3

    private(set) var stationarySeconds = 0
    private(set) var movingSeconds = 0

    /// Clear both run-lengths. Called when the workout starts, and on any
    /// manual pause or resume, so a fresh state never inherits a partial
    /// run-length from the previous one.
    mutating func reset() {
        stationarySeconds = 0
        movingSeconds = 0
    }

    /// Feed one tick while the workout is running. Returns true on the tick
    /// where auto-pause should fire.
    mutating func accrueStationary(isStopped: Bool) -> Bool {
        guard isStopped else {
            stationarySeconds = 0
            return false
        }
        stationarySeconds += 1
        movingSeconds = 0
        return stationarySeconds >= Self.stationarySecondsBeforeAutoPause
    }

    /// Feed one tick while the workout is auto-paused. Returns true on the
    /// tick where auto-resume should fire.
    mutating func accrueMoving(isMoving: Bool) -> Bool {
        guard isMoving else {
            movingSeconds = 0
            return false
        }
        movingSeconds += 1
        stationarySeconds = 0
        return movingSeconds >= Self.movingSecondsBeforeAutoResume
    }
}
