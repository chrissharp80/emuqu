@testable import Emuqu
import SwiftUI
import XCTest

/// Snapshot coverage for the overnight chart stack and the vitals detail.
///
/// `OvernightChartsView` computes its own statistics from the session, so these
/// exercise `computeOvernightStats` end to end as well as the drawing: the HR
/// curve, the rolling RMSSD trace, the analysis-window highlight and the sleep
/// row. That computation decides which slice of the night a recovery score is
/// built from, so a change to it moves every score the user sees.
@MainActor
final class OvernightSnapshotTests: XCTestCase {
    private func hosted(_ view: some View) -> some View {
        NavigationStack { view }
            .environment(RRCollector())
            .environment(SettingsManager.shared)
            .environment(ArchiveSignal())
    }

    func testOvernightChartsRenders() {
        assertSnapshot(
            of: hosted(
                OvernightChartsView(
                    session: SnapshotFixtures.overnightSession(),
                    result: SnapshotFixtures.analysisResult()
                )
            ),
            named: "chart-overnight"
        )
    }

    /// With HealthKit sleep supplied, the sleep row and the segment shading
    /// come from Apple's staging rather than the app's own estimate — a
    /// visibly different chart.
    func testOvernightChartsWithHealthKitSleepRenders() {
        assertSnapshot(
            of: hosted(
                OvernightChartsView(
                    session: SnapshotFixtures.overnightSession(),
                    result: SnapshotFixtures.analysisResult(),
                    healthKitSleep: SnapshotFixtures.sleepData()
                )
            ),
            named: "chart-overnight-healthkit"
        )
    }

    /// Manual window mode is what a user lands in after dragging the analysis
    /// window themselves.
    func testOvernightChartsManualWindowRenders() {
        assertSnapshot(
            of: hosted(
                OvernightChartsView(
                    session: SnapshotFixtures.overnightSession(),
                    result: SnapshotFixtures.analysisResult(),
                    isManualWindowMode: true,
                    manualResult: SnapshotFixtures.analysisResult()
                )
            ),
            named: "chart-overnight-manual-window"
        )
    }

    // MARK: - Vitals

    func testVitalsDetailRenders() {
        assertSnapshot(
            of: hosted(
                VitalsDetailV2View(
                    vitals: SnapshotFixtures.recoveryVitals(),
                    recentSessions: (0 ..< 5).map { SnapshotFixtures.overnightSession(dayOffset: -$0) },
                    temperatureUnit: .celsius
                )
            ),
            named: "detail-vitals"
        )
    }

    /// No watch means no vitals at all — the state a strap-only user is in
    /// every single morning.
    func testVitalsDetailWithoutDataRenders() {
        assertSnapshot(
            of: hosted(
                VitalsDetailV2View(
                    vitals: nil,
                    recentSessions: [],
                    temperatureUnit: .fahrenheit
                )
            ),
            named: "detail-vitals-empty"
        )
    }
}
