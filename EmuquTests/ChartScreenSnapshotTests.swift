@testable import Emuqu
import SwiftUI
import XCTest

/// Snapshot coverage for the dashboard, the training-load trajectory, and the
/// remaining information screens.
///
/// `LoadTrajectoryView` draws the CTL/ATL/TSB curves a user makes training
/// decisions from, plus the comeback / peaking / overreach / monotony flags. It
/// is dense arithmetic-driven drawing with a lot of conditional state, which is
/// the kind of view a refactor breaks quietly.
@MainActor
final class ChartScreenSnapshotTests: XCTestCase {
    private func hosted(_ view: some View) -> some View {
        NavigationStack { view }
            .environment(SnapshotFixtures.collector())
            .environment(SettingsManager.shared)
            .environment(StoreKitManager.shared)
            .environment(ArchiveSignal())
            .environment(MorningCoordination())
    }

    /// Six weeks of building load: CTL climbing, ATL spikier, TSB drifting
    /// negative. Deterministic — every value is a function of the day index.
    private func samples(days: Int = 42) -> [LoadTrajectoryView.DailySample] {
        var out: [LoadTrajectoryView.DailySample] = []
        for i in 0 ..< days {
            let offset: TimeInterval = Double(i - days) * 86_400
            let date = SnapshotFixtures.anchor.addingTimeInterval(offset)
            let progress: Double = Double(i) / Double(days)
            let ctl: Double = 30 + 25 * progress
            let atl: Double = ctl + 12 * sin(Double(i) / 3.0)
            let trimp: Double = i % 7 == 0 ? 0 : 60 + 30 * cos(Double(i) / 2.0)
            out.append(
                LoadTrajectoryView.DailySample(
                    id: date, date: date, ctl: ctl, atl: atl, tsb: ctl - atl, trimp: trimp
                )
            )
        }
        return out
    }

    /// Split out of the literal below: interpolating into a UUID string inside
    /// a struct initializer made the expression too slow for the type checker.
    private static func workoutId(_ index: Int) -> UUID {
        let suffix = String(format: "%012d", index)
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)") ?? UUID()
    }

    private func recentWorkouts() -> [LoadTrajectoryView.RecentWorkout] {
        var out: [LoadTrajectoryView.RecentWorkout] = []
        for i in 0 ..< 4 {
            // Counted back from now, not from the frozen anchor: each row
            // says how long ago it was ("3 days ago"), and an anchored date
            // reads "5 years ago", a label that changes as the years pass.
            let date = Date().addingTimeInterval(-Double(i + 3) * 86_400 - 3_600)
            let minutes: Int = 40 + i * 5
            let trimp: Double = 80 - Double(i) * 6
            out.append(
                LoadTrajectoryView.RecentWorkout(
                    id: Self.workoutId(i),
                    sportSymbolName: "figure.run",
                    sportLabel: "Run",
                    date: date,
                    durationMinutes: minutes,
                    trimp: trimp,
                    loadSource: nil
                )
            )
        }
        return out
    }

    func testLoadTrajectoryRenders() {
        assertSnapshot(
            of: hosted(
                LoadTrajectoryView(
                    samples: samples(),
                    weeklyTrimp: 420,
                    weeklyTrimpDelta: 35,
                    rampRate: 4.2,
                    comebackActive: false,
                    peakingDetected: false,
                    overreachActive: false,
                    monotonyFlagged: false,
                    recentWorkouts: recentWorkouts(),
                    onComebackTap: {},
                    onPeakingTap: {},
                    onOverreachTap: {}
                )
            ),
            named: "chart-load-trajectory"
        )
    }

    /// Every warning flag lit at once. These are the states a user only sees
    /// when their training has gone wrong, so they are the least exercised by
    /// hand and the most consequential to render incorrectly.
    func testLoadTrajectoryWithAllFlagsRenders() {
        assertSnapshot(
            of: hosted(
                LoadTrajectoryView(
                    samples: samples(),
                    weeklyTrimp: 720,
                    weeklyTrimpDelta: 180,
                    rampRate: 12.5,
                    comebackActive: true,
                    peakingDetected: true,
                    overreachActive: true,
                    monotonyFlagged: true,
                    recentWorkouts: recentWorkouts(),
                    onComebackTap: {},
                    onPeakingTap: {},
                    onOverreachTap: {}
                )
            ),
            named: "chart-load-trajectory-flagged"
        )
    }

    /// A full baseline (thirty fixture nights) in a folder of this test's own,
    /// so the dashboard shows its verdict rather than "Building your baseline".
    /// Full, not just past 14 nights: between 14 and 28 the dashboard shows a
    /// one-time toast and records in UserDefaults that it has.
    private func establishedBaseline() -> BaselineTracker {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DashboardBaseline-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                // swallow-ok: the folder is temporary and may never have been created.
            }
        }
        let tracker = BaselineTracker(baselineFile: directory.appendingPathComponent("HRVBaseline.json"))
        let nights = (0 ..< 30).map { SnapshotFixtures.overnightSession(dayOffset: -$0) }
        tracker.rebuildFromSessions(nights, sleepSchedule: SleepSchedule(bedtimeHour: 22, bedtimeMinute: 0, sleepHours: 8))
        return tracker
    }

    /// Given a fixed today (`SnapshotFixtures.today`): the recent-days strip
    /// and the night-age captions are counted from today.
    func testDashboardRenders() {
        assertSnapshot(
            of: hosted(
                DashboardV2View(
                    sessions: (0 ..< 6).map { SnapshotFixtures.overnightSession(dayOffset: -$0) },
                    totalSessionCount: 6,
                    isActive: true,
                    scrollToTopToken: UUID(),
                    onStartRecording: {},
                    onViewReport: { _ in }
                )
                .environment(SnapshotFixtures.collector(baselineTracker: establishedBaseline()))
            )
            .environment(\.currentDate) { SnapshotFixtures.today },
            named: "screen-dashboard"
        )
    }

    /// A brand-new install: no readings at all.
    func testDashboardEmptyRenders() {
        useEmptyDashboardCache()
        assertSnapshot(
            of: hosted(
                DashboardV2View(
                    sessions: [],
                    totalSessionCount: 0,
                    isActive: true,
                    scrollToTopToken: UUID(),
                    onStartRecording: {},
                    onViewReport: { _ in }
                )
            ),
            named: "screen-dashboard-empty"
        )
    }

    func testReportsListRenders() {
        assertSnapshot(of: hosted(ReportsListView()), named: "screen-reports-list")
    }

    func testPaywallRenders() {
        assertSnapshot(of: hosted(PaywallView()), named: "screen-paywall")
    }

    func testMetricInfoSheetRenders() {
        assertSnapshot(of: hosted(MetricInfoSheet(metricLabel: "RMSSD")), named: "sheet-metric-info")
    }
}
