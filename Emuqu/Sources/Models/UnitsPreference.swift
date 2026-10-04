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
        case .auto: String(localized: "Automatic", bundle: LanguageManager.appBundle)
        case .metric: String(localized: "Metric", bundle: LanguageManager.appBundle)
        case .imperial: String(localized: "Imperial", bundle: LanguageManager.appBundle)
        }
    }

    /// Effective units after resolving `.auto` against the current locale.
    var resolved: UnitsPreference {
        guard self == .auto else { return self }
        return Locale.current.measurementSystem == .us ? .imperial : .metric
    }

    // MARK: Formatting helpers
    //
    // Numbers and unit symbols follow the app's language ("3,45 km", "3.45
    // km", "3,45 км"), not a fixed English "%.2f km".

    func formatDistance(meters: Double) -> String {
        switch resolved {
        case .imperial:
            return Self.measurement(meters / 1_609.344, .miles, fractionDigits: 2)
        case .metric, .auto:
            return Self.measurement(meters / 1_000, .kilometers, fractionDigits: 2)
        }
    }

    func formatElevation(meters: Double) -> String {
        switch resolved {
        case .imperial:
            return Self.measurement((meters * UnitConstants.feetPerMeter).rounded(), .feet, fractionDigits: 0)
        case .metric, .auto:
            return Self.measurement(meters.rounded(), .meters, fractionDigits: 0)
        }
    }

    /// Pace = seconds per unit distance (km or mi).
    func formatPace(secondsPerMeter: Double?) -> String? {
        guard let s = secondsPerMeter, s.isFinite, s > 0 else { return nil }
        switch resolved {
        case .imperial:
            let time = Self.minutesSeconds(s * 1_609.344)
            return String(localized: "\(time) /mi", bundle: LanguageManager.appBundle)
        case .metric, .auto:
            let time = Self.minutesSeconds(s * 1_000)
            return String(localized: "\(time) /km", bundle: LanguageManager.appBundle)
        }
    }

    /// "5:07" — minutes and zero-padded seconds, as pace is written everywhere.
    private static func minutesSeconds(_ seconds: Double) -> String {
        let whole = Int(min(seconds, Double(Int.max / 2)))
        return "\(whole / 60):\(String(format: "%02d", whole % 60))"
    }

    /// A length in the given unit, its number and abbreviation in the app's
    /// language.
    private static func measurement(_ value: Double, _ unit: UnitLength, fractionDigits: Int) -> String {
        let formatter = MeasurementFormatter()
        formatter.locale = LanguageManager.appLocale
        formatter.unitOptions = .providedUnit
        formatter.unitStyle = .medium
        formatter.numberFormatter.locale = LanguageManager.appLocale
        formatter.numberFormatter.minimumFractionDigits = fractionDigits
        formatter.numberFormatter.maximumFractionDigits = fractionDigits
        return formatter.string(from: Measurement(value: value, unit: unit))
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
        case .imperial: return String(localized: "min/mi", bundle: LanguageManager.appBundle)
        case .metric, .auto: return String(localized: "min/km", bundle: LanguageManager.appBundle)
        }
    }
}

// MARK: - Settings-level helper
//
// A single resolved preference read/written under a known key. Stored in
// the App Group UserDefaults suite (not `UserDefaults.standard`), with the
// app's other preference keys.
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
// Only preference-flavoured keys belong here; transient state (in-flight
// recording, debug flags) stays on `UserDefaults.standard`. Neither store
// survives deleting the app.
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
