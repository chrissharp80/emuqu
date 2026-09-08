import CoreMotion
import Foundation

// MARK: - Workout Pedometer
//
// CMPedometer-based distance + step tracking. Works INDOORS (unlike GPS) —
// uses the iPhone's accelerometer + Apple's fused motion model. Strictly
// complementary to WorkoutLocationManager: GPS owns the route/map/elevation
// for outdoor workouts; pedometer owns the distance metric so pacing around
// the house, treadmill, or weak-signal situations still register.
//
// Distance is reported in meters, same units as LocationTrackingManager, so
// the recorder can take `max(gpsDistance, pedometerDistance)` and the user
// gets the more accurate of the two automatically.
@Observable
@MainActor
final class WorkoutPedometer {
    private(set) var distanceMeters: Double = 0
    private(set) var stepCount: Int = 0
    private(set) var cadenceStepsPerMin: Double?
    private(set) var isAvailable: Bool = CMPedometer.isDistanceAvailable() && CMPedometer.isStepCountingAvailable()

    private let pedometer = CMPedometer()
    private var sessionStart: Date?

    // MARK: - Control

    func start() {
        guard isAvailable else { return }
        sessionStart = Date()
        distanceMeters = 0
        stepCount = 0
        cadenceStepsPerMin = nil
        subscribeToUpdates(from: sessionStart ?? Date())
    }

    /// `@Sendable` on the handler below is load-bearing, not decoration.
    ///
    /// Without it, the closure is formed inside a `@MainActor` type and handed
    /// to a parameter that is not itself `@Sendable`, so Swift gives it
    /// INHERITED main-actor isolation and emits an executor precondition at its
    /// entry. CoreMotion does not call it on the main thread — it calls it on a
    /// dispatch workloop worker — so that precondition runs
    /// `dispatch_assert_queue(main)`, and libdispatch answers a failed queue
    /// assertion with `__builtin_trap()`. The process dies of SIGTRAP inside the
    /// first pedometer callback of the workout, roughly a second after Start,
    /// having recorded nothing. A field crash log resolves frame for frame to
    /// exactly that: `_dispatch_assert_queue_fail` ←
    /// `_swift_task_checkIsolatedSwift` ← this closure ← CoreMotion ← a dispatch
    /// workloop thread. It cost a user their whole walk.
    ///
    /// `@Sendable` makes the closure nonisolated, so no executor check runs in
    /// it at all. `PedometerSample` then carries the reading across to the main
    /// actor as plain values — the hop this code always meant to make, and the
    /// reason `CMPedometerData` itself must not be captured.
    ///
    /// `scripts/check_coremotion_handler_isolation.sh` holds the line for every
    /// other CoreMotion entry point.
    private func subscribeToUpdates(from start: Date) {
        pedometer.startUpdates(from: start) { @Sendable [weak self] data, error in
            guard error == nil, let data else { return }
            let sample = PedometerSample(data)
            Task { @MainActor [weak self] in self?.apply(sample) }
        }
    }

    @MainActor
    private func apply(_ sample: PedometerSample) {
        if let meters = sample.publishableDistanceMeters { distanceMeters = meters }
        stepCount = sample.steps
        if let cadence = sample.publishableCadenceStepsPerMin { cadenceStepsPerMin = cadence }
    }

    func stop() {
        pedometer.stopUpdates()
    }

    func reset() {
        distanceMeters = 0
        stepCount = 0
        cadenceStepsPerMin = nil
    }
}

// MARK: - Pedometer Sample

/// One CoreMotion reading, reduced to values that can cross to the main actor.
///
/// It is a file-scope type rather than a member of `WorkoutPedometer` because
/// the class is `@MainActor` and a nested type would inherit that isolation —
/// which would put the main-actor hop back inside the CoreMotion callback,
/// where it is exactly the thing that crashes (see `start()`).
///
/// `CMPedometerData` is a reference type that CoreMotion owns and hands to its
/// own callback thread. Copying the three numbers out on that thread is what
/// makes the handler sendable; the object itself never leaves it.
struct PedometerSample: Sendable {
    /// Straight from CoreMotion — unvalidated. Read through
    /// `publishableDistanceMeters` / `publishableCadenceStepsPerMin`.
    let rawDistanceMeters: Double?
    let steps: Int
    let rawCadenceStepsPerSecond: Double?

    init(distanceMeters: Double?, steps: Int, cadenceStepsPerSecond: Double?) {
        rawDistanceMeters = distanceMeters
        self.steps = steps
        rawCadenceStepsPerSecond = cadenceStepsPerSecond
    }

    /// Distance to publish, or nil to leave the last good value standing.
    ///
    /// CoreMotion values are unvalidated OS input, and the published distance
    /// is divided and then converted with `Int(...)` in several places (split
    /// index, mile marker, MET pace) — `Int(Double.nan)` TRAPS, and so does a
    /// value past `Int.max`. The GPS path is already safe because its
    /// `distanceDelta >= minimumMovementMeters` guard rejects NaN. Reject
    /// rather than clamp: a bad reading means no new distance this tick, not a
    /// fabricated one.
    var publishableDistanceMeters: Double? {
        guard let meters = rawDistanceMeters, meters.isFinite, meters >= 0 else { return nil }
        return meters
    }

    /// CMPedometer reports cadence in steps/second; the UI shows steps/min.
    /// Same reject-don't-clamp rule as the distance above.
    var publishableCadenceStepsPerMin: Double? {
        guard let cadence = rawCadenceStepsPerSecond, cadence.isFinite, cadence >= 0 else { return nil }
        return cadence * 60
    }
}

extension PedometerSample {
    init(_ data: CMPedometerData) {
        self.init(
            distanceMeters: data.distance?.doubleValue,
            steps: data.numberOfSteps.intValue,
            cadenceStepsPerSecond: data.currentCadence?.doubleValue
        )
    }
}
