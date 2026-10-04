import CoreLocation
import Foundation

// Pure geometry and physiology live in `WorkoutGeometry`, kept out of
// WorkoutRecorder.
//
// These forwarders keep every existing call site working. None of the
// functions references a member of the recorder, so nothing needs an `unowned`
// parent or a state hand-off: they are pure code, and inside the recorder
// class no test could reach them.

extension WorkoutRecorder {
    func trackLengthMeters(_ track: [CLLocation]) -> Double {
        WorkoutGeometry.trackLengthMeters(track)
    }

    func nextIndex(after startIdx: Int, atDistance meters: Double, in dists: [Double]) -> Int? {
        WorkoutGeometry.nextIndex(after: startIdx, atDistance: meters, in: dists)
    }

    func bearing(from a: Route.Point, to b: Route.Point) -> Double {
        WorkoutGeometry.bearing(from: a, to: b)
    }

    func signedBearingDelta(from a: Double, to b: Double) -> Double {
        WorkoutGeometry.signedBearingDelta(from: a, to: b)
    }

    func turnLabel(deltaDegrees delta: Double) -> String {
        WorkoutGeometry.turnLabel(deltaDegrees: delta)
    }

}
