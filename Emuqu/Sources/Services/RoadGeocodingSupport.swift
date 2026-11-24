import CoreLocation
import Foundation

// The bearing helper: a free function `RoadGeocodingService` uses that does
// not belong to it. The geocoder's
// deadlines go through `runWithTimeout` (`Deadline.swift`).

// MARK: - Bearing helper
//
// Initial bearing from one coordinate to another, in degrees clockwise
// from true north (0°). Standard great-circle formula. Used by the
// tile-search ranking so the road parallel to the
// user's heading wins over a perpendicular cross street at intersections.
/// Initial great-circle bearing from `a` to `b`, in degrees clockwise from
/// true north, normalised to `[0, 360)`.
///
/// Internal rather than file-private so it is reachable from tests: it decides
/// which cross-street the assistant names during a workout, and a sign or
/// quadrant error there is silently wrong rather than visibly broken.
func bearingDegrees(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
    let lat1 = a.latitude * .pi / 180
    let lat2 = b.latitude * .pi / 180
    let dLon = (b.longitude - a.longitude) * .pi / 180
    let y = sin(dLon) * cos(lat2)
    let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
    let radians = atan2(y, x)
    let degrees = radians * 180 / .pi
    return (degrees + 360).truncatingRemainder(dividingBy: 360)
}
