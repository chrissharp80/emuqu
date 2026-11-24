import CoreLocation
import Foundation

// Pure geometry and physiology live in `WorkoutGeometry`; these forwarders
// give `WorkoutRecorder` callers the same entry points. None of the
// functions references a member of the recorder, so nothing needs an
// `unowned` parent or a state hand-off.

extension WorkoutRecorder {
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
