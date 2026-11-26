import Foundation

/// Everything the assistant is told about a workout in progress: the per-tick
/// context snapshot, route topology and climbs ahead, threshold breaches,
/// split paces and current grade.
///
/// Owned by the recorder and built once. Reads the live state it is handed;
/// writes only the route's place and auto-detected match, the threshold
/// breach counts and the grade memo.
@MainActor
final class WorkoutAIContextBuilder {
    let core: RecordingCore
    let services: WorkoutServices
    let settingsProvider: @MainActor () -> UserSettings
    let lifecycle: WorkoutLifecycle
    let workoutHR: WorkoutHR
    let motion: WorkoutMotion
    let dfa: LiveDFAAnalyzer
    let routeGuidance: WorkoutRouteGuidance
    let sensors: WorkoutSensors
    let capture: WorkoutCapture
    let signals: WorkoutLiveSignals
    let coaching: WorkoutCoachingInputs

    init(
        core: RecordingCore, services: WorkoutServices, settingsProvider: @escaping @MainActor () -> UserSettings,
        lifecycle: WorkoutLifecycle, workoutHR: WorkoutHR, motion: WorkoutMotion, dfa: LiveDFAAnalyzer,
        routeGuidance: WorkoutRouteGuidance, sensors: WorkoutSensors, capture: WorkoutCapture,
        signals: WorkoutLiveSignals, coaching: WorkoutCoachingInputs
    ) {
        (self.core, self.services, self.settingsProvider) = (core, services, settingsProvider)
        (self.lifecycle, self.workoutHR, self.motion, self.dfa) = (lifecycle, workoutHR, motion, dfa)
        (self.routeGuidance, self.sensors, self.capture) = (routeGuidance, sensors, capture)
        (self.signals, self.coaching) = (signals, coaching)
    }
}
