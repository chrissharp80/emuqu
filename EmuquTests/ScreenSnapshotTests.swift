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

    // MARK: - Not pinned
    //
    // A reference must be the same picture on every machine on every day.
    // These screens draw something no fixture here controls, so they have no
    // snapshot:
    //
    // - `HistoryCalendarView` opens on the month that contains today, so its
    //   picture changes every month.
    // - `ErrorCatalogView` and `DebugLogView` list the process's own log, which
    //   the tests running before them write to, with the time each line was
    //   written.
    // - `CrashLogView` reads the crash reports on the device running the tests.
    // - `PermissionsSettingsPage` shows the Apple Health authorization the
    //   simulator happens to hold.

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
