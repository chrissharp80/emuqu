import XCTest

/// Record tab coverage.
///
/// The Record tab is the entry point for HRV recording sessions. The
/// session chooser's header is covered in `EmuquUITests`; this suite covers
/// the chooser's three session cards, the no-strap connect panel, and that
/// the panel area scrolls.
///
/// This suite asserts:
///   • The session chooser offers all three session types (Daily,
///     Extended, Nap).
///   • Without a paired strap, the connect panel offers "Scan for Devices"
///     (or, with Bluetooth denied, says so) — not a crash and not a blank
///     area.
///   • The Record panel scrolls both ways and the tab bar stays reachable.
@MainActor
final class RecordTabUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-UITests-FreshInstall"] + UITestLanguage.english
        app.launch()
        UITestLaunch.toMainUI(app)
        navigateToRecord()
    }

    override func tearDown() async throws {
        app = nil
    }

    /// Through the shared navigator, which polls for hittability and confirms
    /// the Record tab's content actually came up.
    private func navigateToRecord() {
        XCTAssertTrue(
            UITestNav.selectTab(app, identifier: UITestID.tabRecord, title: UITestID.tabRecordTitle),
            "The Record tab must open — \(UITestFind.onScreen(app))"
        )
    }

    // MARK: - Session-type selection

    /// Each of the three session cards must be on screen. The chooser's
    /// header is `EmuquUITests.testRecordViewShowsSessionSelector`'s; this
    /// pins the choices under it. Matched on the card's leading word, as
    /// each card's accessibility label is "<type> session — <subheading>".
    func testSessionTypeSelectorRenders() {
        for type in ["Daily", "Extended", "Nap"] {
            let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", type)).firstMatch
            XCTAssertTrue(
                card.waitForExistence(timeout: UITestTiming.s(5)),
                "Record tab must offer the \(type) session — \(UITestFind.onScreen(app))"
            )
        }
    }

    // MARK: - No-strap empty state

    /// Without a paired Polar device the connect panel must offer the scan
    /// that pairs one, or — when Bluetooth access was denied — say so with
    /// a way to Settings. Either is a way forward; a blank panel is not.
    /// Matched on the panel's own copy, so text elsewhere on the screen
    /// cannot satisfy it.
    func testNoStrapStateSurfacesGuidance() {
        let scan = app.buttons.matching(NSPredicate(format: "label ==[c] %@", "Scan for Devices")).firstMatch
        let bluetoothOff = app.staticTexts.matching(
            NSPredicate(format: "label ==[c] %@", "Bluetooth access is off")
        ).firstMatch
        let offered = scan.waitForExistence(timeout: UITestTiming.s(8)) || bluetoothOff.exists
        XCTAssertTrue(
            offered,
            "With no strap paired the Record tab must offer 'Scan for Devices' — \(UITestFind.onScreen(app))"
        )
    }

    // MARK: - Scrolling

    /// The Record panel scrolls both ways without crashing, and the tab bar
    /// is still there afterwards.
    func testRecordPanelScrollsWithoutCrashing() {
        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(
            scrollView.waitForExistence(timeout: UITestTiming.s(3)),
            "The Record tab must render its scroll view — \(UITestFind.onScreen(app))"
        )
        for _ in 0 ..< 4 { scrollView.swipeUp() }
        for _ in 0 ..< 4 { scrollView.swipeDown() }
        XCTAssertEqual(app.state, .runningForeground, "Scrolling the Record tab must not crash the app")
        XCTAssertTrue(app.tabBars.firstMatch.exists, "Record-tab scroll must not lose the tab bar")
    }
}
