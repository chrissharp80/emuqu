import CoreLocation
import Foundation

/// How much to trust a GPS fix, and how to say so.
///
/// Kept out of `GetMeBackView` so it is testable; as a `private` enum inside
/// the view nothing tests it, and two crashing defects follow:
///
///  * `currentAccuracyMeters` falls back to `.greatestFiniteMagnitude` when
///    there is no fix. That value IS finite, so an `isFinite` guard lets it
///    through, and the label then computes `Int(1.8e308)` — which traps. The
///    screen dies whenever the accuracy ribbon draws before GPS has locked,
///    which is precisely when someone who is lost opens it.
///  * CoreLocation reports a NEGATIVE `horizontalAccuracy` to mean the fix is
///    invalid. A bare `case ..<10` matches `-1` and reports "GPS strong",
///    telling a lost user to trust an arrow built from a fix CoreLocation has
///    already disowned.
///
/// Get Me Back is a safety feature. Being wrong here points someone the wrong
/// way in the dark, so the rule is: when in doubt, say we are waiting.
enum GPSAccuracyLevel: String, CaseIterable, Equatable {
    case good
    case ok
    case poor
    /// No usable fix. The arrow is hidden and the user is told to wait —
    /// pointing someone in a wrong direction is worse than not pointing.
    case waiting

    /// Metres above which a fix is not worth showing a direction for.
    static let unusableAboveMetres: Double = 100

    /// Classify a CoreLocation `horizontalAccuracy`, in metres.
    ///
    /// `nil` means there is no fix at all, which is `.waiting` rather than a
    /// sentinel value that later arithmetic has to remember to special-case.
    static func classify(horizontalAccuracyMetres accuracy: Double?) -> GPSAccuracyLevel {
        guard let accuracy, accuracy.isFinite, accuracy >= 0 else { return .waiting }
        switch accuracy {
        case ..<10: return .good
        case ..<30: return .ok
        case ..<unusableAboveMetres: return .poor
        default: return .waiting
        }
    }

    /// The rounded metres to show beside the label, or nil when the value
    /// cannot be represented — in which case the caller shows the waiting
    /// text rather than a number.
    static func displayMetres(_ meters: Double?) -> Int? {
        guard let meters, meters.isFinite,
              meters >= Double(Int.min), meters <= Double(Int.max) else { return nil }
        return Int(meters)
    }

    /// Whether a direction arrow should be drawn at all.
    var showsDirection: Bool { self != .waiting }
}
