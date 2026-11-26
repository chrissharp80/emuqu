@testable import Emuqu
import SwiftUI
import XCTest

/// Snapshot coverage for the dashboard, full and empty.
///
/// Not snapshot-tested: the Load & Trajectory screen, the reports list and the
/// metric info sheet. Their layout includes system navigation chrome (large
/// titles, sheet bars) that settles at different offsets with timing, their
/// content is static or covered by the component snapshots, and their
/// behaviour is covered by unit and UI tests.
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

    // The paywall has no snapshot: its button shows the price StoreKit
    // returns ("Unlock for $9.99") or "Purchase" when it returns none, and
    // what a test host's StoreKit returns depends on that simulator. An
    // `SKTestSession` over `Configuration.storekit` would fix the product, but
    // `import StoreKitTest` does not build here: its headers use
    // `SKPaymentTransactionState`, deprecated in iOS 18, and with warnings
    // treated as errors the module fails to precompile.
}
