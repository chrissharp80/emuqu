@testable import Emuqu
import SwiftUI
import XCTest

/// Snapshot coverage for the detail screens a user drills into from a result.
///
/// `RecoveryScoreDetailView` (2,088 lines), `HRVDetailV2View` (1,351),
/// `SleepDetailV2View` (1,193) and `WorkoutSummaryV2View` (1,138) are where the
/// numbers behind a score are explained. They are also where a user goes when
/// they doubt a reading, so rendering them wrong costs trust directly.
///
/// `baselineStats` is nil in these: that is the state before enough history
/// exists to have a baseline, which every user passes through and which a
/// change written against populated data is most likely to break.
@MainActor
final class DetailScreenSnapshotTests: XCTestCase {
    private func hosted(_ view: some View) -> some View {
        NavigationStack { view }
            .environment(RRCollector())
            .environment(SettingsManager.shared)
            .environment(StoreKitManager.shared)
            .environment(ArchiveSignal())
    }

    private var recent: [HRVSession] {
        (1 ... 5).map { SnapshotFixtures.overnightSession(dayOffset: -$0) }
    }

    func testRecoveryScoreDetailRenders() {
        assertSnapshot(
            of: hosted(
                RecoveryScoreDetailView(
                    session: SnapshotFixtures.overnightSession(),
                    result: SnapshotFixtures.analysisResult(),
                    recentSessions: recent,
                    baselineStats: nil,
                    totalSessionCount: 6
                )
            ),
            named: "detail-recovery-score"
        )
    }

    func testHRVDetailRenders() {
        assertSnapshot(
            of: hosted(
                HRVDetailV2View(
                    session: SnapshotFixtures.overnightSession(),
                    result: SnapshotFixtures.analysisResult(),
                    recentSessions: recent,
                    baselineStats: nil
                )
            ),
            named: "detail-hrv"
        )
    }

    func testSleepDetailRenders() {
        assertSnapshot(
            of: hosted(
                SleepDetailV2View(
                    session: SnapshotFixtures.overnightSession(),
                    sleepData: SnapshotFixtures.sleepData(),
                    recoveryVitals: SnapshotFixtures.recoveryVitals(),
                    recentSessions: recent,
                    temperatureUnit: .celsius,
                    typicalSleepHours: 7.5,
                    userAge: 38
                )
            ),
            named: "detail-sleep"
        )
    }

    /// No HealthKit sleep and no vitals is the common case for a user with a
    /// strap but no watch.
    func testSleepDetailWithoutHealthKitRenders() {
        assertSnapshot(
            of: hosted(
                SleepDetailV2View(
                    session: SnapshotFixtures.overnightSession(),
                    sleepData: nil,
                    recoveryVitals: nil,
                    recentSessions: recent,
                    temperatureUnit: .celsius,
                    typicalSleepHours: 7.5,
                    userAge: 38
                )
            ),
            named: "detail-sleep-no-healthkit"
        )
    }

    func testWorkoutSummaryRenders() throws {
        let session = SnapshotFixtures.workoutSession()
        let workout = try XCTUnwrap(session.workoutMetadata, "fixture must carry workout metadata")
        assertSnapshot(
            of: hosted(WorkoutSummaryV2View(session: session, workout: workout)),
            named: "detail-workout-summary"
        )
    }
}
