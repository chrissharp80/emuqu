import Foundation

/// The course a workout follows, when it follows one, and where the user is
/// on it: a GPX the user loaded before starting, or a saved route the
/// recogniser matched part-way in.
///
/// When `planned` is set, every tick computes a fresh `RouteProgress`, so the
/// coach knows the climbs ahead. Route-aware coaching is opt-in, so most
/// workouts leave it nil.
@Observable
@MainActor
final class WorkoutRouteGuidance {
    /// The course. Setting it forgets the last projected point.
    var planned: Route? {
        didSet { lastProgressIndex = nil }
    }

    /// The route point the last tick projected onto. Passed back to
    /// `RouteProgress.compute` so a route that loops back near itself keeps
    /// the user's place instead of jumping to the closer leg.
    @ObservationIgnored var lastProgressIndex: Int?

    /// True when `planned` was assigned by the recogniser matching a route
    /// the user saved to their library, rather than a hand-loaded GPX.
    /// Drives the "Following Daily 1" banner.
    var wasAutoDetected = false

    /// Reverse when the recognised match runs the saved route backwards, so
    /// the climb cues read right and the user sees the app understood.
    var direction: RouteLibrary.Direction = .forward

    /// The saved route the recogniser bound as `planned`, nil for a
    /// hand-loaded GPX, so deleting that saved route unbinds it.
    @ObservationIgnored var savedRouteId: UUID?

    /// Track length at which route auto-detection next runs: it first runs
    /// at `RouteLibrary.detectionTriggerMeters` of movement, and while
    /// nothing matches, again after each further stretch of that length
    /// (a warm-up leg before joining a saved loop must not rule the loop
    /// out for the rest of the workout). 0 = not tried yet.
    var nextDetectionAtMeters: Double = 0

    /// The ground ahead and this spot, from the user's past GPS workouts:
    /// with or without a route, the climb coming and what it did to their
    /// heart rate.
    @ObservationIgnored let places = LivePlaceMemory()
}
