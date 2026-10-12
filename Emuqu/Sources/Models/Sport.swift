import Foundation

// MARK: - Sport

/// Curated list of supported workout activities. We intentionally start small
/// and add more as demand surfaces rather than shipping a custom-activity
/// builder on day one.
enum Sport: String, Codable, CaseIterable, Identifiable {
    case run
    case trailRun = "trail_run"
    case walk
    case hike
    case bike
    case indoorBike = "indoor_bike"
    case treadmill
    /// Indoor rowing on a Concept2 PM5 (or any FTMS rower). Distance,
    /// stroke rate, watts, and drag factor come from the rower itself
    /// over BLE — GPS, motion, and pedometer sources are inappropriate
    /// (you're stationary). The rower's watts are recorded, but there is no
    /// rowing FTP, so no power-TSS: training load comes from heart rate.
    case row
    /// Air / assault bike. Indoor, interval-based conditioning. No BLE power
    /// meter here and not a steady-state endurance effort, so it's treated as
    /// a non-power sport (no FTP, no power-TSS). Strap HR only.
    case airBike = "air_bike"
    /// CrossFit / functional-fitness WOD. Indoor, interval-based, no pace or
    /// power meter — strap HR only, non-power sport.
    case crossFit = "crossfit"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .run: "Run"
        case .trailRun: "Trail Run"
        case .walk: "Walk"
        case .hike: "Hike"
        case .bike: "Ride"
        case .indoorBike: "Indoor Ride"
        case .treadmill: "Treadmill"
        case .row: "Row"
        case .airBike: "Air Bike"
        case .crossFit: "CrossFit"
        }
    }

    /// The sport's name in the app's language, for the screen and the spoken
    /// start cue. `displayName` stays English for the assistant, exports and
    /// logs; shown as-is it was English in every language.
    var localizedName: String {
        let b = LanguageManager.appBundle
        return switch self {
        case .run: String(localized: "Run", bundle: b)
        case .trailRun: String(localized: "Trail Run", bundle: b)
        case .walk: String(localized: "Walk", bundle: b)
        case .hike: String(localized: "Hike", bundle: b)
        case .bike: String(localized: "Ride", bundle: b)
        case .indoorBike: String(localized: "Indoor Ride", bundle: b)
        case .treadmill: String(localized: "Treadmill", bundle: b)
        case .row: String(localized: "Row", bundle: b)
        case .airBike: String(localized: "Air Bike", bundle: b)
        case .crossFit: String(localized: "CrossFit", bundle: b)
        }
    }

    var icon: String {
        switch self {
        case .run: "figure.run"
        case .trailRun: "figure.hiking"
        case .walk: "figure.walk"
        case .hike: "figure.hiking"
        case .bike: "bicycle"
        case .indoorBike: "figure.indoor.cycle"
        case .treadmill: "figure.run"
        case .row: "figure.rower"
        case .airBike: "figure.mixed.cardio"
        case .crossFit: "figure.strengthtraining.functional"
        }
    }

    /// Whether this sport benefits from GPS tracking.
    var usesGPS: Bool {
        switch self {
        case .run, .trailRun, .walk, .hike, .bike: true
        case .indoorBike, .treadmill, .row, .airBike, .crossFit: false
        }
    }
}
