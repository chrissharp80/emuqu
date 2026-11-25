import Foundation

/// The once-per-second loop that drives a live workout: reading the sensors,
/// arbitrating between heart-rate sources, accruing the auto-pause counters,
/// updating the live metrics the UI shows, and taking the incremental backups
/// that make a crash recoverable.
///
/// Owned by the recorder and built once. It owns the tick timer and the
/// strap-HR observation; the timer captures `[weak self]` and the
/// observation holds the ticker weakly (`ObservationLoop`), so neither keeps
/// it alive and both no-op once it is gone.
@MainActor
final class WorkoutTicker {
    let core: RecordingCore
    let services: WorkoutServices
    let settingsProvider: @MainActor () -> UserSettings
    let lifecycle: WorkoutLifecycle
    let workoutHR: WorkoutHR
    let motion: WorkoutMotion
    let dfa: LiveDFAAnalyzer
    let intervalController: IntervalController
    let routeGuidance: WorkoutRouteGuidance
    let sensors: WorkoutSensors
    let capture: WorkoutCapture
    let signals: WorkoutLiveSignals
    let coaching: WorkoutCoachingInputs
    let voiceCoach: WorkoutVoiceCoach
    let aiContext: WorkoutAIContextBuilder
    let pauseControl: WorkoutPauseControl

    var tickTimer: Timer?
    var hrSubscription: ObservationHandle?

    init(
        core: RecordingCore, services: WorkoutServices, settingsProvider: @escaping @MainActor () -> UserSettings,
        lifecycle: WorkoutLifecycle, workoutHR: WorkoutHR, motion: WorkoutMotion, dfa: LiveDFAAnalyzer,
        intervalController: IntervalController, routeGuidance: WorkoutRouteGuidance, sensors: WorkoutSensors,
        capture: WorkoutCapture, signals: WorkoutLiveSignals, coaching: WorkoutCoachingInputs,
        voiceCoach: WorkoutVoiceCoach, aiContext: WorkoutAIContextBuilder, pauseControl: WorkoutPauseControl
    ) {
        (self.core, self.services, self.settingsProvider) = (core, services, settingsProvider)
        (self.lifecycle, self.workoutHR, self.motion, self.dfa) = (lifecycle, workoutHR, motion, dfa)
        (self.intervalController, self.routeGuidance, self.sensors) = (intervalController, routeGuidance, sensors)
        (self.capture, self.signals, self.coaching) = (capture, signals, coaching)
        (self.voiceCoach, self.aiContext, self.pauseControl) = (voiceCoach, aiContext, pauseControl)
    }

    /// The paired Watch: the source of the Watch-routed strap beats and the
    /// wrist HR, and where the live state is pushed.
    var watchBridge: WatchConnectivityBridge { services.watchConnectivityBridge }
}
