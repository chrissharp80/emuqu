import CoreLocation
import Foundation
import MapKit

// MARK: - ActiveRouteSession
//
// Continuous turn-by-turn for the AI's `directions.routeTo`
// tool. The tool alone returns the FIRST 1–3 step instructions and
// stops — useful as an opening narration but worthless as the user
// walks. This service holds an active `MKRoute` in memory and tracks
// which step the user is currently on, so a follow-up question
// ("what's next?", "did I miss the turn?") can be answered against
// the user's actual position.
//
// **Lifecycle.** One active session at a time. `engage(...)` stores a
// route + destination. `currentStep(for:)` is queried per-fix (or per
// AI tool call) and returns the most relevant upcoming step + distance.
// `disengage()` clears it. The service is offline-once-engaged: once
// `MKDirections.calculate()` returns, the polyline + step list live
// fully in memory; no further network is required to answer "what's
// my next turn".
//
// **Step matching.** A route's steps each have a `polyline` covering a
// segment. Naive "closest-step-by-distance" works fine for foot pace —
// at <2 m/s, the user advances through one step every ~30 s, much
// slower than our 25 m / 60 s reverse-geocode tick. For driving we'd
// want a tighter geometric off-route check; foot-mode users notice
// "you missed the turn" via the arrow and visual world long before an
// app does, so we keep it simple here.

final class ActiveRouteSession: @unchecked Sendable {
    static let shared = ActiveRouteSession()

    /// Internal step abstraction. Decouples the session from
    /// `MKRouteStep` so synthetic step lists (built from a saved
    /// route's polyline by `SavedRouteStepBuilder`) can engage the
    /// same session as MKDirections-backed routes. Both code paths
    /// converge here.
    ///
    /// Exists so saved-route navigation can fire the
    /// same TurnAlertEngine / TurnMarkerEngine that
    /// `directions.routeTo` already drives.
    struct InternalStep {
        let instructions: String
        let distance: CLLocationDistance
        let polyline: MKPolyline
    }

    private let lock = NSLock()
    private var _steps: [InternalStep] = []
    private var _totalDistance: CLLocationDistance = 0
    private var _totalDuration: TimeInterval = 0
    private var _destinationLabel: String = ""
    private var _destinationCoord: CLLocationCoordinate2D?
    private var _engagedAt: Date?
    /// Index of the most recently entered step, sticky so we don't
    /// jump backwards through the route when GPS jitter places the
    /// user momentarily closer to an earlier step's polyline.
    private var _currentStepIndex: Int = 0
    /// Set once a fix lands more than `departureMeters` from the route's end.
    /// A loop ends where it starts, so until the user has been away from the
    /// end, being near it is the start, not the finish.
    private var _hasLeftEnd = false
    private static let departureMeters: CLLocationDistance = 50

    private init() {}

    /// Engage a new MKDirections-backed turn-by-turn session.
    /// Replaces any previously-engaged session. Internally
    /// normalizes MKRoute.steps into the same `InternalStep` shape
    /// the saved-route path uses.
    func engage(
        route: MKRoute,
        destinationLabel: String,
        destinationCoord: CLLocationCoordinate2D
    ) {
        let normalized: [InternalStep] = route.steps.map { step in
            InternalStep(
                instructions: step.instructions,
                distance: step.distance,
                polyline: step.polyline
            )
        }
        engageInternal(
            steps: normalized,
            totalDistance: route.distance,
            totalDuration: route.expectedTravelTime,
            destinationLabel: destinationLabel,
            destinationCoord: destinationCoord
        )
    }

    /// Engage a synthetic step list (e.g. from a saved route's
    /// polyline). Same downstream behaviour as the MKDirections
    /// path — `currentStep(for:)`, `snapshot()`, and the alert /
    /// marker engines see no difference.
    func engageSyntheticRoute(
        steps: [InternalStep],
        totalDistance: CLLocationDistance,
        totalDuration: TimeInterval,
        destinationLabel: String,
        destinationCoord: CLLocationCoordinate2D
    ) {
        engageInternal(
            steps: steps,
            totalDistance: totalDistance,
            totalDuration: totalDuration,
            destinationLabel: destinationLabel,
            destinationCoord: destinationCoord
        )
    }

    private func engageInternal(
        steps: [InternalStep],
        totalDistance: CLLocationDistance,
        totalDuration: TimeInterval,
        destinationLabel: String,
        destinationCoord: CLLocationCoordinate2D
    ) {
        lock.lock(); defer { lock.unlock() }
        _steps = steps
        _totalDistance = totalDistance
        _totalDuration = totalDuration
        _destinationLabel = destinationLabel
        _destinationCoord = destinationCoord
        _engagedAt = Date()
        _currentStepIndex = 0
        _hasLeftEnd = false
    }

    /// Drop the active session. Called when the user reaches the
    /// destination, manually clears via the AI ("never mind"), or a
    /// new route is engaged.
    func disengage() {
        lock.lock(); defer { lock.unlock() }
        _steps = []
        _totalDistance = 0
        _totalDuration = 0
        _destinationLabel = ""
        _destinationCoord = nil
        _engagedAt = nil
        _currentStepIndex = 0
        _hasLeftEnd = false
    }

    /// Public read of the engaged route's metadata. nil when no
    /// session is engaged.
    func snapshot() -> Snapshot? {
        lock.lock(); defer { lock.unlock() }
        guard !_steps.isEmpty, let coord = _destinationCoord else { return nil }
        return Snapshot(
            destinationLabel: _destinationLabel,
            destinationLatitude: coord.latitude,
            destinationLongitude: coord.longitude,
            totalDistanceMeters: _totalDistance,
            totalDurationSeconds: _totalDuration,
            stepCount: _steps.count,
            currentStepIndex: _currentStepIndex,
            engagedAt: _engagedAt ?? Date()
        )
    }

    /// The "upcoming" step is the one AFTER what the user is currently
    /// traversing — that's the instruction they need ("turn right onto
    /// Oak in 200 ft"). On the last step, that IS the destination.
    func currentStep(for location: CLLocation) -> StepResult? {
        lock.lock()
        defer { lock.unlock() }
        guard !_steps.isEmpty, let lastStep = _steps.last else { return nil }
        noteDeparture(from: location, lastStep: lastStep)
        advanceStepIndex(for: location)
        let upcomingStep = _steps[min(_currentStepIndex + 1, _steps.count - 1)]
        return StepResult(
            currentStepIndex: _currentStepIndex,
            currentInstruction: _steps[_currentStepIndex].instructions,
            upcomingInstruction: upcomingStep.instructions,
            distanceToUpcomingStepMeters: polylineDistance(
                from: location, to: upcomingStep.polyline, preferStart: true
            ),
            // Total remaining distance = sum of remaining-step distances.
            remainingDistanceMeters: _steps.suffix(from: _currentStepIndex).reduce(0.0) { $0 + $1.distance },
            destinationLabel: _destinationLabel,
            arrived: hasArrived(at: location, lastStep: lastStep)
        )
    }

    /// Within 25 m of the route's end, on its last step, after the user has
    /// been away from the end — so a loop doesn't arrive at its start. Must
    /// be called with `lock` held.
    private func hasArrived(at location: CLLocation, lastStep: InternalStep) -> Bool {
        guard _hasLeftEnd, _currentStepIndex == _steps.count - 1,
              let end = routeEnd(lastStep) else { return false }
        return Self.distance(from: location, to: end) <= 25
    }

    /// Must be called with `lock` held.
    private func noteDeparture(from location: CLLocation, lastStep: InternalStep) {
        guard !_hasLeftEnd, let end = routeEnd(lastStep) else { return }
        _hasLeftEnd = Self.distance(from: location, to: end) > Self.departureMeters
    }

    /// Where the route ends: the last point of the last step's polyline, else
    /// the destination it was built for. Not `polyline.coordinate`, which is
    /// the centre of the polyline's bounding box — halfway along a straight
    /// final leg. Must be called with `lock` held.
    private func routeEnd(_ lastStep: InternalStep) -> CLLocationCoordinate2D? {
        let count = lastStep.polyline.pointCount
        guard count > 0 else { return _destinationCoord }
        return lastStep.polyline.points()[count - 1].coordinate
    }

    /// Find the closest step polyline to the user's current position. Steps
    /// are short and ordered, so we walk forward from the current sticky
    /// index — never back. That avoids GPS jitter causing "you're back at
    /// step 1" false positives when the user briefly drifts near an earlier
    /// turn. Must be called with `lock` held.
    ///
    /// The last step is out of reach until the user has been away from the
    /// route's end: on a loop the finish is the start, and proximity alone
    /// would put the user on the last step at the first fix.
    private func advanceStepIndex(for location: CLLocation) {
        let lastEnterable = _hasLeftEnd ? _steps.count - 1 : max(0, _steps.count - 2)
        let lookahead = min(lastEnterable, _currentStepIndex + 5)
        guard _currentStepIndex <= lookahead else { return }
        var bestIndex = _currentStepIndex
        var bestDistance = Double.greatestFiniteMagnitude
        for i in _currentStepIndex ... lookahead {
            let dist = polylineDistance(from: location, to: _steps[i].polyline)
            if dist < bestDistance {
                bestDistance = dist
                bestIndex = i
            }
        }
        if bestIndex > _currentStepIndex {
            _currentStepIndex = bestIndex
        }
    }

    private static func distance(from location: CLLocation, to coord: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: coord.latitude, longitude: coord.longitude).distance(from: location)
    }

    // MARK: - Public types

    struct Snapshot {
        let destinationLabel: String
        let destinationLatitude: Double
        let destinationLongitude: Double
        let totalDistanceMeters: Double
        let totalDurationSeconds: TimeInterval
        let stepCount: Int
        let currentStepIndex: Int
        let engagedAt: Date
    }

    struct StepResult {
        let currentStepIndex: Int
        /// The instruction for the segment the user is currently on.
        /// Often empty for the first auto-generated step ("Proceed to
        /// Maple Ave"); use `upcomingInstruction` for narration.
        let currentInstruction: String
        /// "Turn right onto Oak St" — the next thing the user
        /// must DO. This is what the AI should narrate.
        let upcomingInstruction: String
        let distanceToUpcomingStepMeters: Double
        let remainingDistanceMeters: Double
        let destinationLabel: String
        /// True when the user is within 25 m of the destination.
        let arrived: Bool
    }

    // MARK: - Private geometry

    /// Distance from a point to a polyline. Returns the minimum
    /// over the polyline's vertex coordinates — good enough for foot-
    /// pace navigation. With `preferStart=true` we take the polyline's
    /// FIRST coordinate specifically (used to compute "distance to
    /// start of the upcoming step"; the user wants to know how far
    /// until they need to turn, not how far the closest vertex of
    /// the next leg is).
    private func polylineDistance(
        from location: CLLocation,
        to polyline: MKPolyline,
        preferStart: Bool = false
    ) -> Double {
        let pointCount = polyline.pointCount
        guard pointCount > 0 else { return .greatestFiniteMagnitude }
        let points = polyline.points()
        if preferStart {
            let coord = points[0].coordinate
            return CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                .distance(from: location)
        }
        var best = Double.greatestFiniteMagnitude
        for i in 0 ..< pointCount {
            let coord = points[i].coordinate
            let d = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                .distance(from: location)
            if d < best { best = d }
        }
        return best
    }
}
