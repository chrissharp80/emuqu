@testable import Emuqu
import SwiftUI
import XCTest

/// Snapshot coverage for self-contained view components.
///
/// These take plain values rather than environment objects, which makes them
/// cheap to pin and means a change to any of them is caught by a test rather
/// than by someone opening the screen.
///
/// Several are states a user only reaches when something has gone wrong — a
/// device with unrecovered data on it, a fetch that is retrying. Those are
/// exactly the screens least likely to be checked by hand and most costly to
/// render broken, because the user is already in trouble when they see them.
@MainActor
final class ComponentSnapshotTests: XCTestCase {
    // MARK: - Feeling badges

    func testMorningFeelingBadgeRenders() {
        assertSnapshot(of: MorningFeelingBadge(feeling: 4), named: "badge-morning-feeling")
    }

    func testWorkoutFeelingBadgeWithNoteRenders() {
        assertSnapshot(
            of: WorkoutFeelingBadge(feeling: 3, note: "Legs heavy on the climb"),
            named: "badge-workout-feeling"
        )
    }

    func testWorkoutFeelingBadgeWithoutNoteRenders() {
        assertSnapshot(
            of: WorkoutFeelingBadge(feeling: 5, note: nil),
            named: "badge-workout-feeling-no-note"
        )
    }

    // MARK: - Device recovery
    //
    // The user sees these after a session that did not come back cleanly.

    func testRecoverableDataCardRenders() {
        assertSnapshot(
            of: RecoverableDataCard(
                deviceName: "Polar H10 9BC21F2A",
                onRecover: {},
                onDiscard: {}
            ),
            named: "card-recoverable-data"
        )
    }

    func testFetchProgressCardMidDownloadRenders() {
        assertSnapshot(
            of: FetchProgressCard(
                progress: PolarManager.FetchProgress(
                    stage: .fetchingData, progress: 0.45,
                    attempt: 1, maxAttempts: 3,
                    statusMessage: "Downloading from device..."
                ),
                deviceName: "Polar H10 9BC21F2A",
                onCancel: {}
            ),
            named: "card-fetch-progress"
        )
    }

    /// The retry state renders a different message — "(attempt 2/3)" — and is
    /// the one a user hits when their strap is misbehaving.
    func testFetchProgressCardRetryingRenders() {
        assertSnapshot(
            of: FetchProgressCard(
                progress: PolarManager.FetchProgress(
                    stage: .retrying, progress: 0.2,
                    attempt: 2, maxAttempts: 3,
                    statusMessage: "Retrying..."
                ),
                deviceName: "Polar H10 9BC21F2A",
                onCancel: {}
            ),
            named: "card-fetch-progress-retry"
        )
    }

    // MARK: - Training detail
    //
    // The nil-metrics case was tried first and rejected by the harness: it
    // renders a single flat colour, so a reference would have been a test that
    // could never fail. Populated is the state worth pinning anyway — it draws
    // the ATL/CTL/TSB figures a user makes training decisions from.

    func testTrainingDetailWithMetricsRenders() {
        let day = Date(timeIntervalSince1970: 1_622_534_400)
        let metrics = TrainingMetrics(
            atl: 62.4,
            ctl: 55.1,
            tsb: -7.3,
            dailyTrimp: [
                day: 88.0,
                day.addingTimeInterval(-86_400): 41.0,
                day.addingTimeInterval(-172_800): 0.0
            ],
            todayTrimp: 88.0,
            todayWorkouts: [],
            recentWorkouts: []
        )
        // Wrapped in a NavigationStack: the view's body is scroll content that
        // lays out to nothing without a container, which the blank guard caught.
        assertSnapshot(
            of: NavigationStack {
                TrainingDetailView(trainingMetrics: metrics, trainingContext: nil)
            },
            named: "screen-training-detail"
        )
    }
}
