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

    /// Why a strap workout has no strap heart rate, when the user should be
    /// told. The workout continues either way — this explains the missing HR
    /// rather than leaving the user wondering. Set and cleared each tick by
    /// `HRArbitration`; cleared on stop and on the next start.
    var strapNotice: WorkoutStrapNotice?
}

/// Why a strap workout is not receiving strap heart rate.
enum WorkoutStrapNotice: Equatable, Sendable {
    /// No link to the strap.
    case strapNotConnected
    /// Linked, but the strap has stopped sending heart rate.
    case strapSilent
}
