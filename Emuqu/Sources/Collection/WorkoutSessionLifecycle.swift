import Foundation

/// Bringing a workout up and the derived metrics it reports: the start
/// sequence and its deferred work (the strap's own backup, the start
/// baselines), the archive write, and normalized power / METs / the coach
/// report.
///
/// Start is the most instrumented path in this codebase (see
/// `WorkoutStartLatencyTracker`). Owned by the recorder and built once. The
/// closures it hands out (deferred tasks, interval callbacks, the context
/// providers given to the conversation and `LiveWorkoutBroker`) capture
/// `[weak self]`, so none keeps it alive, and each answers nil-safely once it
/// is gone.
@MainActor
final class WorkoutSessionLifecycle {
    let core: RecordingCore
    let services: WorkoutServices
    let settingsProvider: @MainActor () -> UserSettings
    let conversation: VoiceConversationController
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
    let pauseControl: WorkoutPauseControl
    let voiceCoach: WorkoutVoiceCoach
    let ticker: WorkoutTicker
    let aiContext: WorkoutAIContextBuilder

    init(
        core: RecordingCore, services: WorkoutServices, settingsProvider: @escaping @MainActor () -> UserSettings,
        conversation: VoiceConversationController, lifecycle: WorkoutLifecycle, workoutHR: WorkoutHR,
        motion: WorkoutMotion, dfa: LiveDFAAnalyzer, intervalController: IntervalController, routeGuidance: WorkoutRouteGuidance,
        sensors: WorkoutSensors, capture: WorkoutCapture, signals: WorkoutLiveSignals, coaching: WorkoutCoachingInputs,
        pauseControl: WorkoutPauseControl, voiceCoach: WorkoutVoiceCoach, ticker: WorkoutTicker, aiContext: WorkoutAIContextBuilder
    ) {
        (self.core, self.services, self.settingsProvider, self.conversation) = (core, services, settingsProvider, conversation)
        (self.lifecycle, self.workoutHR, self.motion, self.dfa) = (lifecycle, workoutHR, motion, dfa)
        (self.intervalController, self.routeGuidance, self.sensors) = (intervalController, routeGuidance, sensors)
        (self.capture, self.signals, self.coaching) = (capture, signals, coaching)
        (self.pauseControl, self.voiceCoach, self.ticker, self.aiContext) = (pauseControl, voiceCoach, ticker, aiContext)
    }

    /// The paired Watch, whose own workout session start brings up.
    var watchBridge: WatchConnectivityBridge { services.watchConnectivityBridge }
}
