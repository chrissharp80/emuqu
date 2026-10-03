import Foundation
import Observation

/// Published morning-processing and device-refinement coordination state.
///
/// Split out from `RRCollector` so the morning/results screens that track
/// analysis progress (and the dashboard's sleep-data refresh signal) don't
/// re-render on unrelated BLE / archive / streaming updates.
///
/// Writers: the morning-processing and acceptance extensions push here.
/// Readers: `RecordView`, `MorningResultsView`, `RecoveryDashboardView`.
/// The collector keeps back-compat get/set forwarding so existing extension
/// code migrates incrementally.
@MainActor
@Observable
final class MorningCoordination {
    /// Progress of the morning overnight processing pipeline, or nil when idle.
    var morningStatus: RRCollector.MorningProcessingStatus?

    /// True while the background H10 internal-memory fetch is in progress.
    var isDeviceFetchInProgress: Bool = false

    /// A just-recovered interrupted workout awaiting the user's review/trim,
    /// or nil when there's nothing to review. Set after a crash recovery so
    /// the user can confirm the duration (and trim off any tail the strap
    /// recorded after the workout) before keeping it — instead of a silent
    /// archive of a possibly-wrong-length session.
    var recoveredWorkoutReview: RecoveredWorkoutReview?

    struct RecoveredWorkoutReview: Equatable {
        let sessionId: UUID
        let sport: String
        let durationSec: Double
        let distanceMeters: Double
        let avgHR: Int
    }

    /// Incremented when new sleep data arrives from HealthKit (Apple Watch
    /// sync). Views observe to re-fetch sleep and update composite scores.
    var sleepDataVersion: Int = 0

    /// Incremented when new recovery-vitals samples arrive from HealthKit
    /// (respiratory rate, SpO2, wrist temperature, resting HR). The Apple
    /// Watch writes these MINUTES to HOURS after sleep ends — the snapshot
    /// captured at session-acceptance time is frequently empty as a result.
    /// Views observe this to re-fetch vitals and re-archive the session
    /// snapshot so SleepDetailView doesn't show blanks for "most nights".
    var vitalsDataVersion: Int = 0
}
