import Combine
import CoreLocation
import Foundation

/// Published motion / GPS / pedometer metrics for an active workout.
///
/// Split out from `WorkoutRecorder` so the workout live-view doesn't
/// re-render on HR beats just because distance ticks (and vice versa).
/// Without the split, every 1 Hz incremental tick invalidates the entire
/// recorder subscription; views that show only the map or only the stat
/// chips subscribe to this object alone.
///
/// Writers: `WorkoutRecorder.incrementalBackupTick` + `resetMetrics`
/// (reads from `WorkoutLocationManager`, `WorkoutPedometer`, and the
/// foot-pod). Back-compat forwarding on the recorder keeps
/// `recorder.distanceMeters` etc. working.
@Observable
@MainActor
final class WorkoutMotion {
    /// Cumulative GPS distance in meters (max of foot-pod, GPS, pedometer).
    var distanceMeters: Double = 0

    /// Cumulative elevation gain in meters from GPS.
    var elevationGainMeters: Double = 0

    /// Current GPS track — updated each tick so the live map view can
    /// draw the polyline without reaching through `locationManager`.
    var liveTrack: [CLLocation] = []

    /// Live step count from CMPedometer.
    var stepCount: Int = 0

    /// Current cadence in steps/min (foot pod when connected, else pedometer).
    var cadenceStepsPerMin: Double?

    /// Instantaneous running power in watts from the foot pod.
    var powerWatts: Int?

    /// Whether a foot pod is currently providing data (speed or power).
    var footPodActive: Bool = false

    /// Reset all motion metrics back to zero/nil state.
    func reset() {
        distanceMeters = 0
        elevationGainMeters = 0
        liveTrack = []
        stepCount = 0
        cadenceStepsPerMin = nil
        powerWatts = nil
        footPodActive = false
    }
}
