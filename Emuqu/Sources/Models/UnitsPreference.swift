import Foundation

// MARK: - Units Preference
//
// Workout metrics need to respect the user's region. US users expect miles +
// feet + /mi pace; most of the rest of the world uses km + meters + /km.
// Default is inferred from the device locale (Locale.current.measurementSystem
// is .us for United States, .metric / .uk otherwise) but the user can
// override in settings if the default is wrong.
enum UnitsPreference: String, Codable, CaseIterable, Identifiable {
    case auto       // follow locale
    case metric     // km, m, /km
    case imperial   // mi, ft, /mi

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: "Automatic"
        case .metric: "Metric"
        case .imperial: "Imperial"
        }
    }

    /// Effective units after resolving `.auto` against the current locale.
    var resolved: UnitsPreference {
        guard self == .auto else { return self }
        return Locale.current.measurementSystem == .us ? .imperial : .metric
    }

    // MARK: Formatting helpers

    func formatDistance(meters: Double) -> String {
        switch resolved {
        case .imperial:
            let miles = meters / 1_609.344
            return String(format: "%.2f mi", miles)
        case .metric, .auto:
            return String(format: "%.2f km", meters / 1_000)
        }
    }

    func formatElevation(meters: Double) -> String {
        switch resolved {
        case .imperial:
            let feet = meters * UnitConstants.feetPerMeter
            return "\(Int(feet.rounded())) ft"
        case .metric, .auto:
            return "\(Int(meters.rounded())) m"
        }
    }

    /// Pace = seconds per unit distance (km or mi).
    func formatPace(secondsPerMeter: Double?) -> String? {
        guard let s = secondsPerMeter, s.isFinite, s > 0 else { return nil }
        switch resolved {
        case .imperial:
            let secPerMi = s * 1_609.344
            let mins = Int(secPerMi) / 60
            let secs = Int(secPerMi) % 60
            return String(format: "%d:%02d /mi", mins, secs)
        case .metric, .auto:
            let secPerKm = s * 1_000
            let mins = Int(secPerKm) / 60
            let secs = Int(secPerKm) % 60
            return String(format: "%d:%02d /km", mins, secs)
        }
    }

    /// Convenience — compute pace from elapsed seconds + distance in meters.
    func formatPace(elapsedSec: Int, distanceMeters: Double) -> String? {
        guard distanceMeters > 50, elapsedSec > 10 else { return nil }
        return formatPace(secondsPerMeter: Double(elapsedSec) / distanceMeters)
    }

    // MARK: - Chart axis helpers

    /// Pace as a single minutes-per-unit number suitable for plotting on a
    /// chart axis. `secPerKm` is what WorkoutSample stores; we convert to
    /// min/km or min/mi depending on user preference.
    func paceDisplayMinutes(from secPerKm: Double) -> Double {
        switch resolved {
        case .imperial:
            return secPerKm * 1.609_344 / 60.0
        case .metric, .auto:
            return secPerKm / 60.0
        }
    }

    /// Label for the pace chart Y-axis and export header.
    var paceSuffix: String {
        switch resolved {
        case .imperial: return "min/mi"
        case .metric, .auto: return "min/km"
        }
    }
}

// MARK: - Settings-level helper
//
// A single resolved preference read/written under a known key. Stored in
// the App Group UserDefaults suite (NOT `UserDefaults.standard`) so a
// reinstall doesn't reset the user's metric/imperial preference back to
// `auto` and silently flip displays — a bug pattern that has hit a real
// user ("kg even though I preferred metric").
//
// On first read after this change, we migrate any prior `.standard`
// value into the suite so users who had set a preference under the old
// scheme don't lose it.
enum UnitsPreferenceStore {
    private static let key = "fitness.unitsPreference"
    private static var suite: UserDefaults { SharedUserDefaults.appGroup }

    static var current: UnitsPreference {
        get {
            // App Group first, fall back to legacy standard suite once,
            // and copy across so the next read finds it in the App Group.
            if let raw = suite.string(forKey: key),
               let parsed = UnitsPreference(rawValue: raw) {
                return parsed
            }
            if let legacy = UserDefaults.standard.string(forKey: key),
               let parsed = UnitsPreference(rawValue: legacy) {
                suite.set(legacy, forKey: key)
                return parsed
            }
            return .auto
        }
        set {
            suite.set(newValue.rawValue, forKey: key)
        }
    }
}

// MARK: - Shared User Defaults (App Group)
//
// Wrapper around `UserDefaults(suiteName:)` for the app's App Group.
// User preferences stored here survive `app-uninstall + reinstall`
// cycles (Xcode triggers these on certain build/structure changes —
// an embedded-Watch-app change once wiped a production user's
// settings). Only preference-flavoured keys belong
// here; transient state (in-flight recording, debug flags) can stay
// on `UserDefaults.standard` where reinstall-wipe is harmless.
enum SharedUserDefaults {
    /// Computed: `UserDefaults` is not `Sendable`, and Foundation caches the
    /// suite instance itself, so there is nothing to hold on to here.
    static var appGroup: UserDefaults {
        if let group = UserDefaults(suiteName: AppConfig.appGroupIdentifier) {
            return group
        }
        return .standard
    }
}
