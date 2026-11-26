@testable import Emuqu
import SwiftUI
import XCTest

/// Snapshot coverage for whole screens and shared chart furniture.
///
/// The view layer is ~73,000 lines; unit tests cannot execute a `some View`
/// body, so it is otherwise barely covered. These pin screens a
/// user actually navigates to, and the tooltips and rows that several charts
/// share — the shared pieces being where a change quietly reaches more than one
/// screen at once.
///
/// Inputs come from `SnapshotFixtures`, which is entirely frozen.
@MainActor
final class ScreenSnapshotTests: XCTestCase {
    // MARK: - Chart furniture
    //
    // These are drawn by more than one chart, so a change here lands in
    // several places at once — the reason they are worth pinning on their own
    // rather than only through the charts that embed them.

    func testChartTooltipRenders() {
        assertSnapshot(
            of: ChartTooltip(value: "148", unit: "bpm", time: "02:41", color: .red),
            named: "tooltip-heart-rate"
        )
    }

    // MARK: - History
    //
    // The calendar opens on the month that contains today and rings today,
    // so it is given a fixed today (`SnapshotFixtures.today`).

    func testHistoryCalendarWithSessionsRenders() {
        let sessions = (0 ..< 12).map { SnapshotFixtures.overnightSession(dayOffset: -$0) }
        assertSnapshot(
            of: NavigationStack {
                HistoryCalendarView(allSessions: sessions, onDelete: { _ in false })
            }
            .environment(\.currentDate) { SnapshotFixtures.today },
            named: "screen-history-calendar"
        )
    }

    /// The empty calendar is what a new user sees, and it is the state most
    /// likely to be broken by a change written against populated data.
    func testHistoryCalendarEmptyRenders() {
        assertSnapshot(
            of: NavigationStack {
                HistoryCalendarView(allSessions: [], onDelete: { _ in false })
            }
            .environment(\.currentDate) { SnapshotFixtures.today },
            named: "screen-history-calendar-empty"
        )
    }

    // Not snapshot-tested: the error catalog, debug log and Get Me Back screens and the tag sheet. The layout includes system navigation
    // chrome (large titles, sheet bars, the tab bar) that settles at different
    // offsets with timing, the content is static or covered by the component
    // snapshots, and the behaviour is covered by unit and UI tests.
    //
    // Not pinned at all: `CrashLogView` reads the crash report file at a fixed
    // path on the device running the tests, and `PermissionsSettingsPage` shows
    // the Apple Health authorization the simulator happens to hold.

    // MARK: - Frequency bands
    //
    // The LF/HF split is one of the headline HRV readouts. It takes only the
    // frequency-domain metrics, so it pins cheaply.

    func testFrequencyBandsRenders() throws {
        let bands = try XCTUnwrap(
            SnapshotFixtures.analysisResult().frequencyDomain,
            "the fixture must carry frequency-domain metrics"
        )
        assertSnapshot(
            of: FrequencyBandsView(frequencyDomain: bands),
            named: "chart-frequency-bands"
        )
    }
}
