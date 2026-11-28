import CoreLocation
import SwiftUI

/// The workout statistics cards of the post-workout summary: pace, heart rate,
/// power and cadence charts, the elevation profile, the heart-rate-recovery
/// card and the derived display values that sit beside them.
///
/// It needs the
/// session, the settings object and the GPS track; `units` reads the
/// process-wide store.
///
/// `elevationSeries` and `hrrProvenanceLabel` are statics here: both touch
/// no instance state, and only these cards use them.
///
/// Deliberately NOT a `View`: it returns view trees into the host view's
/// body, so SwiftUI view identity, animation and `@State` stay the host's.
/// `@MainActor` because those trees are built inside the host's
/// main-actor-isolated `body`.
@MainActor
struct WorkoutStatsCards {
    let session: HRVSession
    let settingsManager: SettingsManager
    let track: [CLLocation]

    var units: UnitsPreference { UnitsPreferenceStore.current }
}

/// Active (un-paused) workout time for display: duration, average pace and
/// calories. A workout saved with its active time (`WorkoutMetadata.activeSeconds`,
/// the wall clock less the pauses) shows that: its samples can stop while
/// the phone is locked. One saved before shows what it always did: the
/// samples are stamped with the recorder's clock, which stops while paused,
/// so the last sample's offset is the active time; with no samples, the
/// wall-clock start → end.
enum WorkoutActiveTime {
    static func seconds(metadata: WorkoutMetadata?, wallClock: TimeInterval?) -> TimeInterval? {
        if let active = metadata?.activeSeconds, active > 0 { return active }
        if let last = metadata?.samples?.last?.offsetSec, last > 0 { return TimeInterval(last) }
        return wallClock
    }
}

/// Unit symbols and measurements in the app language ("km", "mi", "ft",
/// "km/h", "kcal"), via `MeasurementFormatter` so no unit string needs a
/// catalog entry. Always the unit passed in: the caller has already applied
/// the user's units preference.
enum LocalizedUnit {
    static func symbol(_ unit: Unit) -> String {
        formatter(fractionDigits: 0).string(from: unit)
    }

    static func format(_ value: Double, _ unit: Unit, fractionDigits: Int = 0) -> String {
        formatter(fractionDigits: fractionDigits).string(from: Measurement(value: value, unit: unit))
    }

    private static func formatter(fractionDigits: Int) -> MeasurementFormatter {
        let f = MeasurementFormatter()
        f.locale = LanguageManager.appLocale
        f.unitStyle = .medium
        f.unitOptions = .providedUnit
        f.numberFormatter.locale = LanguageManager.appLocale
        f.numberFormatter.minimumFractionDigits = fractionDigits
        f.numberFormatter.maximumFractionDigits = fractionDigits
        return f
    }
}
