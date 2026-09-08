import CoreLocation
import Foundation

// AI context building lives in `WorkoutAIContextBuilder` — 526
// lines out of what was the largest type in the codebase.
//
// These forwarders keep the call sites across the app and the test suite
// working. They are the
// recorder's context API; the behaviour lives one reference away.

extension WorkoutRecorder {
    /// The assistant-context subsystem. Lazy: a workout recorded with the
    /// assistant idle never builds one.
    var aiContext: WorkoutAIContextBuilder {
        WorkoutAIContextBuilder(recorder: self)
    }

    func buildContext(sport: Sport) -> WorkoutAIContext {
        aiContext.buildContext(sport: sport)
    }

    func attemptAutoRouteDetection(sport: Sport) {
        aiContext.attemptAutoRouteDetection(sport: sport)
    }

    func updateThresholdBreaches(sport: Sport) {
        aiContext.updateThresholdBreaches(sport: sport)
    }

    func computeCurrentGradePercent() -> Double? {
        aiContext.computeCurrentGradePercent()
    }

    func recentSplitPacesSecPerKm() -> [Double] {
        aiContext.recentSplitPacesSecPerKm()
    }

    func liveRouteTopologySnapshot(
        currentLocation: CLLocation?
    ) -> AssistantContext.LiveWorkoutSnapshot.RouteTopologySnapshot? {
        aiContext.liveRouteTopologySnapshot(currentLocation: currentLocation)
    }

    func liveWeatherSnapshot() -> AssistantContext.LiveWorkoutSnapshot.WeatherSnapshot? {
        aiContext.liveWeatherSnapshot()
    }

    func liveIntervalProgressSnapshot() -> AssistantContext.LiveWorkoutSnapshot.IntervalProgressSnapshot? {
        aiContext.liveIntervalProgressSnapshot()
    }

    func archiveWorkoutTrackAsBreadcrumbTrail(track: [CLLocation], sport: Sport, start: Date) {
        aiContext.archiveWorkoutTrackAsBreadcrumbTrail(track: track, sport: sport, start: start)
    }

    /// `sportFTP` is a pure lookup over settings — no recorder state at all —
    /// so it forwards to the builder's static rather than taking an instance.
    static func sportFTP(for sport: Sport, settings: UserSettings) -> Int? {
        WorkoutAIContextBuilder.sportFTP(for: sport, settings: settings)
    }
}
