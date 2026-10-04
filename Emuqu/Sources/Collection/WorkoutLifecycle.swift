import Combine
import Foundation

/// Published lifecycle state for an active workout session.
///
/// Final slice extracted from `WorkoutRecorder` — covers the recording
/// phase state-machine, the active/finished session handles, elapsed
/// time, user-selected target HR zone, and the active HR source. After
/// this extraction `WorkoutRecorder` has no `@Published` properties of
/// its own; every observable field lives on a focused sub-observable
/// (`WorkoutMotion`, `WorkoutHR`, `WorkoutLifecycle`).
///
/// Views that display workout phase / session / timer can subscribe to
/// this object instead of the full recorder.
@Observable
@MainActor
final class WorkoutLifecycle {
    /// Recording-lifecycle phase. Observed by the record view to decide
    /// which panel to show (ready / recording / finalizing / summary).
    var phase: WorkoutRecorder.Phase = .idle

    /// The live session being built. Updated in place as RR and GPS
    /// samples arrive.
    var currentSession: HRVSession?

    /// The most-recently finished session. Present once the phase
    /// transitions to `.finished`; cleared on `acknowledgeFinished()`.
    var finishedSession: HRVSession?

    /// Elapsed seconds since the user tapped Start.
    var elapsedSeconds: Int = 0

    /// User-selected target HR zone for this workout. Drives the voice
    /// coach's "drifted out of zone" alert. Nil = no target set.
    var targetZone: Int?

    /// Which HR source is live for THIS workout. Drives whether the tick
    /// loop uses Polar RR or Watch HR as the canonical current-HR value.
    var activeHRSource: WorkoutRecorder.HRSource = .strap

    /// True while a workout is PAUSED — either manually by the user or
    /// automatically because the app decided the runner stopped moving.
    /// The ticker stops incrementing `elapsedSeconds`, stops appending
    /// samples, and stops publishing to the live broker's time-series
    /// fields; HR / strap telemetry keeps flowing so the summary still
    /// captures a "paused" segment rather than a gap.
    var isPaused: Bool = false

    /// True when the current pause was auto-triggered (no movement for
    /// the configured window). Distinguishes "I pressed pause" from the
    /// app pausing on the user's behalf — the UI surfaces it as
    /// "Auto-paused" so the user knows why the clock stopped, and the
    /// auto-resume path only fires when this flag is set (manual pause
    /// doesn't auto-resume on its own — user intent wins).
    var autoPaused: Bool = false

    /// Distance the pedometer and foot pod counted while paused, which the
    /// workout's distance leaves out.
    var pausedMotion = PausedMotionLedger()

    /// When each pause happened, so a sample's `offsetSec` (which stops
    /// while paused) maps back to the wall-clock moment it was taken.
    var pauseTimeline = PauseTimeline()

    /// Why a strap workout has no strap heart rate, when the user should be
    /// told. The workout continues either way — this explains the missing HR
    /// rather than leaving the user wondering. Set and cleared each tick by
    /// `HRArbitration`; cleared on stop and on the next start.
    var strapNotice: WorkoutStrapNotice?
}

/// Wall-clock length of each pause, keyed by the elapsed second it began at.
/// `elapsedSeconds` stops while paused, so after a 10-minute stop a sample's
/// offset from the start is 10 minutes behind the clock; matching it to
/// wrist heart rate by offset alone took the reading from 10 minutes earlier.
struct PauseTimeline: Equatable, Sendable {
    struct Span: Equatable, Sendable {
        let atElapsed: Int
        let seconds: TimeInterval
    }

    private struct OpenPause: Equatable, Sendable {
        let atElapsed: Int
        let startedAt: Date
    }

    private(set) var spans: [Span] = []
    private var openPause: OpenPause?

    mutating func pause(atElapsed elapsed: Int, now: Date) {
        openPause = OpenPause(atElapsed: elapsed, startedAt: now)
    }

    mutating func resume(now: Date) {
        guard let open = openPause else { return }
        spans.append(Span(atElapsed: open.atElapsed, seconds: max(0, now.timeIntervalSince(open.startedAt))))
        openPause = nil
    }

    /// The wall-clock time of the sample at `offsetSec`: the start plus the
    /// active seconds plus every pause that ended before it. A sample taken
    /// at the elapsed second a pause began was captured before that pause.
    func wallClock(forOffset offsetSec: Int, sessionStart: Date) -> Date {
        let pausedBefore = spans.filter { $0.atElapsed < offsetSec }.reduce(0) { $0 + $1.seconds }
        return sessionStart.addingTimeInterval(TimeInterval(offsetSec) + pausedBefore)
    }
}

/// Cumulative motion counters keep running through a pause. This records
/// where each stood when the pause began and how much they moved before the
/// workout resumed, so the walk back to the car is not added to the run.
struct PausedMotionLedger: Equatable, Sendable {
    private var pedometerAtPause: Double?
    private var footPodAtPause: Double?
    private var pedometerExcluded: Double = 0
    private var footPodExcluded: Double = 0

    mutating func pause(pedometer: Double, footPod: Double) {
        pedometerAtPause = pedometer
        footPodAtPause = footPod
    }

    mutating func resume(pedometer: Double, footPod: Double) {
        pedometerExcluded += Self.moved(since: pedometerAtPause, now: pedometer)
        footPodExcluded += Self.moved(since: footPodAtPause, now: footPod)
        pedometerAtPause = nil
        footPodAtPause = nil
    }

    /// The pedometer distance with every paused stretch, including one still
    /// open, taken out.
    func pedometerDistance(_ raw: Double) -> Double {
        max(0, raw - pedometerExcluded - Self.moved(since: pedometerAtPause, now: raw))
    }

    func footPodDistance(_ raw: Double) -> Double {
        max(0, raw - footPodExcluded - Self.moved(since: footPodAtPause, now: raw))
    }

    private static func moved(since start: Double?, now: Double) -> Double {
        start.map { max(0, now - $0) } ?? 0
    }
}

/// Why a strap workout is not receiving strap heart rate.
enum WorkoutStrapNotice: Equatable, Sendable {
    /// No link to the strap.
    case strapNotConnected
    /// Linked, but the strap has stopped sending heart rate.
    case strapSilent
}
