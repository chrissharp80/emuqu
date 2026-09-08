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
