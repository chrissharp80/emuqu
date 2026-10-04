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

    func testHistoryCalendarWithSessionsRenders() {
        let sessions = (0 ..< 12).map { SnapshotFixtures.overnightSession(dayOffset: -$0) }
        assertSnapshot(
            of: NavigationStack {
                HistoryCalendarView(allSessions: sessions, onDelete: { _ in false })
            },
            named: "screen-history-calendar"
        )
    }

    /// The empty calendar is what a new user sees, and it is the state most
    /// likely to be broken by a change written against populated data.
    func testHistoryCalendarEmptyRenders() {
        assertSnapshot(
            of: NavigationStack {
                HistoryCalendarView(allSessions: [], onDelete: { _ in false })
            },
            named: "screen-history-calendar-empty"
        )
    }

    // MARK: - Settings subpages
    //
    // Reached rarely, so rarely looked at, and the diagnostic ones are what a
    // user opens when something has already gone wrong.

    func testErrorCatalogRenders() {
        assertSnapshot(
            of: NavigationStack { ErrorCatalogView() },
            named: "screen-error-catalog"
        )
    }

    func testDebugLogRenders() {
        assertSnapshot(
            of: NavigationStack { DebugLogView() },
            named: "screen-debug-log"
        )
    }

    func testCrashLogRenders() {
        assertSnapshot(
            of: NavigationStack { CrashLogView() },
            named: "screen-crash-log"
        )
    }

    func testPermissionsSettingsRenders() {
        assertSnapshot(
            of: NavigationStack { PermissionsSettingsPage() },
            named: "screen-permissions"
        )
    }

    // MARK: - Safety

    /// The get-me-back screen is a safety feature: it is opened by someone who
    /// is lost. It must render.
    func testGetMeBackRenders() {
        assertSnapshot(
            of: NavigationStack { GetMeBackView() },
            named: "screen-get-me-back"
        )
    }

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

    // MARK: - Tag sheet
    //
    // Bindings are supplied as constants: this pins the rendering, not the
    // editing behaviour, which is what a snapshot can honestly check.

    func testAddTagSheetRenders() {
        assertSnapshot(
            of: AddTagSheet(
                tagName: .constant("Post-travel"),
                tagColor: .constant(.orange),
                onSave: {}
            ),
            named: "sheet-add-tag"
        )
    }

    func testAddTagSheetEmptyNameRenders() {
        // The empty name is the state the save button should reflect.
        assertSnapshot(
            of: AddTagSheet(tagName: .constant(""), tagColor: .constant(.blue), onSave: {}),
            named: "sheet-add-tag-empty"
        )
    }
}
