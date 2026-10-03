import CoreLocation
import SwiftUI

/// The workout statistics cards of the post-workout summary: pace, heart rate,
/// power and cadence charts, the elevation profile, the heart-rate-recovery
/// card and the derived display values that sit beside them.
///
/// Split out of `FitnessPostSummaryView`, alongside [ThresholdCards] and
/// [Alpha1ReportCards]. It needs the
/// session, the settings object and the GPS track; `units` reads the
/// process-wide store.
///
/// `elevationSeries` and `hrrProvenanceLabel` are statics here. Both touch
/// no instance state, and this is the only place
/// that needs them beyond the share sheet, which reaches them through a
/// forwarder.
///
/// Deliberately NOT a `View`, for the same reason as [ThresholdCards]: it
/// returns the same view trees the extension returned, so SwiftUI view
/// identity, animation and `@State` behaviour are unchanged. `@MainActor`
/// because it was main-actor isolated before the split, by virtue of extending
/// a `View`.
@MainActor
struct WorkoutStatsCards {
    let session: HRVSession
    let settingsManager: SettingsManager
    let track: [CLLocation]

    var units: UnitsPreference { UnitsPreferenceStore.current }
}

/// Active (un-paused) workout time for display: duration, average pace and
/// calories. Recorded samples are stamped with the recorder's clock, which
/// stops while paused, so the last sample's offset is the active time. With
/// no samples it falls back to the wall-clock start → end.
enum WorkoutActiveTime {
    static func seconds(samples: [WorkoutSample]?, wallClock: TimeInterval?) -> TimeInterval? {
        if let last = samples?.last?.offsetSec, last > 0 { return TimeInterval(last) }
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
