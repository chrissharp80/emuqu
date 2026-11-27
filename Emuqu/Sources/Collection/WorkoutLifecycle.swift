import Combine
import Foundation

/// Published lifecycle state for an active workout session.
///
/// Covers the recording phase state-machine, the active/finished session
/// handles, elapsed time, user-selected target HR zone, the active HR
/// source, and the run's bookkeeping (start date, the snapshot taken at
/// stop, the strap stream and backup this workout owns, the log scope). `WorkoutRecorder` has no `@Published` properties of its own;
/// every observable field lives on a focused sub-observable
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

    /// How `finishedSession`'s save came out, shown on the summary: `.saved`
    /// once a retry saves it. Nil while no workout has finished.
    var saveOutcome: WorkoutSaveOutcome?

    /// Finished workouts whose archive write failed, oldest first, each kept
    /// until a retry saves it (`WorkoutSessionLifecycle.retryUnsavedWorkouts`).
    /// Their raw backups are left out of lost-session recovery while they are
    /// here (`SessionRecoveryCoordinator.liveRecordingIds`).
    var unsavedSessions: [HRVSession] = []

    /// Heart-rate-recovery samples of saved workouts whose write to the
    /// archived copy failed, each kept until a retry stores it
    /// (`WorkoutSessionLifecycle.retryUnsavedWorkouts`). The summary already
    /// shows them, so they are not dropped.
    var unsavedHRR: [UUID: [HRRSample]] = [:]

    /// Whether the workout with `id` is waiting for its save to be retried.
    func isUnsaved(_ id: UUID) -> Bool {
        unsavedSessions.contains { $0.id == id }
    }

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

    // MARK: Run bookkeeping

    /// When the workout in progress started; nil while idle.
    var sessionStartDate: Date?

    /// The live broker's last snapshot, taken at stop before the broker is
    /// cleared, for finalize to store as the session's `aiContext`.
    var liveSnapshotAtStop: AssistantContext.LiveWorkoutSnapshot?

    /// When the strap's own recording actually started for this workout.
    var deviceBackupArmedAt: Date?

    /// `StrapStreamSession.streamingStartTime` of the stream the recorder's last
    /// strap workout started. RRCollector's overnight and quick sessions
    /// buffer on the same manager, so a stream still live while no workout
    /// records is the recorder's to stop only when its start matches.
    @ObservationIgnored var ownedStrapStreamStart: Date?

    /// Open correlation scope for the workout in progress, `nil` when idle.
    /// Plumbing lives in `WorkoutLifecycle+Correlation.swift`.
    var logCorrelation: LogCorrelation.Token?
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

    /// One pause as the crash backup holds it: written when the pause
    /// begins (`resumedAt` nil) and again when it ends, so a workout lost
    /// while paused still knows the pause it was in.
    struct Event: Codable, Equatable, Sendable {
        let atElapsed: Int
        let pausedAt: Date
        let resumedAt: Date?
    }

    private(set) var spans: [Span] = []
    private var openPause: OpenPause?
    /// Every pause and resume, in order, for the crash backup
    /// (`WorkoutTrackBackup.appendPauses`).
    private(set) var events: [Event] = []

    mutating func pause(atElapsed elapsed: Int, now: Date) {
        openPause = OpenPause(atElapsed: elapsed, startedAt: now)
        events.append(Event(atElapsed: elapsed, pausedAt: now, resumedAt: nil))
    }

    /// Moves the open pause's start back to `date`, active second
    /// `atElapsed`: a pause applied after it was asked for (a Watch Pause
    /// that arrived late) began at the tap. Its backup row moves with it.
    mutating func movePauseStart(to date: Date, atElapsed elapsed: Int) {
        guard openPause != nil, events.last?.resumedAt == nil else { return }
        events.removeLast()
        pause(atElapsed: elapsed, now: date)
    }

    mutating func resume(now: Date) {
        guard let open = openPause else { return }
        spans.append(Span(atElapsed: open.atElapsed, seconds: max(0, now.timeIntervalSince(open.startedAt))))
        openPause = nil
        events.append(Event(atElapsed: open.atElapsed, pausedAt: open.startedAt, resumedAt: now))
    }

    /// The timeline a crash backup's `events` describe, ended at `end` (the
    /// recovered end of the workout): each pause once, its last row winning,
    /// and one still open at the crash closed at `end`, as a stop while
    /// paused closes it. A pause that began at or after `end` is left out.
    static func restored(from events: [Event], endingAt end: Date) -> PauseTimeline {
        var latest: [Date: Event] = [:]
        for event in events where latest[event.pausedAt]?.resumedAt == nil { latest[event.pausedAt] = event }
        var timeline = PauseTimeline()
        for event in latest.values.sorted(by: { $0.pausedAt < $1.pausedAt }) where event.pausedAt < end {
            timeline.pause(atElapsed: event.atElapsed, now: event.pausedAt)
            timeline.resume(now: min(event.resumedAt ?? end, end))
        }
        return timeline
    }

    /// The wall-clock stretch of each pause, open or closed; one still open
    /// runs to `now`.
    func pauseWindows(now: Date) -> [ClosedRange<Date>] {
        var windows: [Date: ClosedRange<Date>] = [:]
        for event in events {
            let end = max(event.pausedAt, event.resumedAt ?? now)
            windows[event.pausedAt] = event.pausedAt ... end
        }
        return windows.values.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// Ends the timeline at `stopDate`. A pause still open closes there, or
    /// is dropped when it began after it; a closed pause that began after it
    /// is dropped and one running across it is shortened to it. A stop dated
    /// now changes only the open pause, as `resume(now:)` does; a stop dated
    /// earlier (a Watch End that arrived late) leaves no pause past the end.
    mutating func end(at stopDate: Date, sessionStart: Date) {
        var pausedBefore: TimeInterval = 0
        var kept: [Span] = []
        for span in spans {
            let began = sessionStart.addingTimeInterval(TimeInterval(span.atElapsed) + pausedBefore)
            guard began < stopDate else { break }
            kept.append(Span(atElapsed: span.atElapsed, seconds: min(span.seconds, stopDate.timeIntervalSince(began))))
            pausedBefore += span.seconds
        }
        spans = kept
        if let open = openPause, open.startedAt < stopDate { resume(now: stopDate) }
        openPause = nil
    }

    /// The workout's active seconds at `now`: the wall-clock time since
    /// `sessionStart` less every pause, the one still running included, so
    /// the count stands still while paused. Never below zero.
    func activeSeconds(sessionStart: Date, now: Date) -> Int {
        let paused = spans.reduce(0) { $0 + $1.seconds } + (openPause.map { max(0, now.timeIntervalSince($0.startedAt)) } ?? 0)
        let active = now.timeIntervalSince(sessionStart) - paused
        guard active.isFinite, active > 0 else { return 0 }
        return Int(active.rounded(.down))
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
