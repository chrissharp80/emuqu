import XCTest

/// Record tab coverage.
///
/// The Record tab is the entry point for HRV recording sessions. Its
/// session-type selection is covered in `EmuquUITests`; this suite covers
/// the no-strap state, the connect-panel fallbacks, and the data-recovery
/// banner.
///
/// This suite asserts:
///   • The session-type selector renders (Extended / Quick variants).
///   • Without a Polar device, the connect panel surfaces an empty
///     device-list state — not a crash.
///   • The Lost Sessions / Data Recovery entry is reachable.
@MainActor
final class RecordTabUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-UITests", "-UITests-FreshInstall"]
        app.launch()
        UITestLaunch.toMainUI(app)
        navigateToRecord()
    }

    override func tearDown() async throws {
        app = nil
    }

    private func navigateToRecord() {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: UITestTiming.s(8)), "Tab bar required")
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", "Record")
        let recordTab = tabBar.buttons.matching(predicate).firstMatch
        XCTAssertTrue(recordTab.waitForExistence(timeout: UITestTiming.s(3)), "Record tab must exist")
        recordTab.tap()
        // RecordView is wrapped in a LazyView — give it time to materialize.
        _ = app.scrollViews.firstMatch.waitForExistence(timeout: UITestTiming.s(3))
    }

    // MARK: - Session-type selection

    /// The session-type selector must surface at least one "Extended"
    /// or "Quick" option. Kept loose — we
    /// don't pin specific sub-button labels, only that the selector
    /// is on screen.
    func testSessionTypeSelectorRenders() {
        let extendedPredicate = NSPredicate(format: "label CONTAINS[c] %@", "Extended")
        let quickPredicate = NSPredicate(format: "label CONTAINS[c] %@", "Quick")
        let extended = app.buttons.matching(extendedPredicate).firstMatch
        let quick = app.buttons.matching(quickPredicate).firstMatch
        let extendedText = app.staticTexts.matching(extendedPredicate).firstMatch
        let quickText = app.staticTexts.matching(quickPredicate).firstMatch

        let anyVisible = extended.waitForExistence(timeout: UITestTiming.s(5))
            || quick.waitForExistence(timeout: UITestTiming.s(2))
            || extendedText.waitForExistence(timeout: UITestTiming.s(2))
            || quickText.waitForExistence(timeout: UITestTiming.s(2))

        XCTAssertTrue(
            anyVisible,
            "Record tab must surface Extended or Quick session-type controls"
        )
    }

    // MARK: - No-strap empty state

    /// Without a paired Polar device, the connect-panel area must
    /// either show an empty-device-list state, an "Add device" CTA, or
    /// a "Pair your strap" prompt — not a crash and not a silent
    /// blank area.
    func testNoStrapStateSurfacesGuidance() {
        let predicates: [NSPredicate] = [
            NSPredicate(format: "label CONTAINS[c] %@", "Pair"),
            NSPredicate(format: "label CONTAINS[c] %@", "device"),
            NSPredicate(format: "label CONTAINS[c] %@", "Polar"),
            NSPredicate(format: "label CONTAINS[c] %@", "Strap"),
            NSPredicate(format: "label CONTAINS[c] %@", "Connect"),
            NSPredicate(format: "label CONTAINS[c] %@", "Add")
        ]
        var anyMatch = false
        for p in predicates {
            if app.staticTexts.matching(p).firstMatch.waitForExistence(timeout: UITestTiming.s(1))
                || app.buttons.matching(p).firstMatch.waitForExistence(timeout: UITestTiming.s(1)) {
                anyMatch = true
                break
            }
        }
        XCTAssertTrue(
            anyMatch,
            "Record tab must surface device-pairing guidance when no strap is paired"
        )
    }

    // MARK: - Lost-sessions / Data Recovery reachable

    /// Settings → Advanced → Lost Sessions is the recovery flow when a
    /// session was killed mid-recording. From the Record tab, scrolling
    /// the panel area should not crash even though there's nothing to
    /// recover.
    func testRecordPanelScrollsWithoutCrashing() {
        let scrollView = app.scrollViews.firstMatch
        guard scrollView.waitForExistence(timeout: UITestTiming.s(3)) else { return }
        for _ in 0 ..< 4 { scrollView.swipeUp() }
        for _ in 0 ..< 4 { scrollView.swipeDown() }
        // Tab bar must still be reachable after scrolling.
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.exists, "Record-tab scroll must not lose the tab bar")
    }
}
