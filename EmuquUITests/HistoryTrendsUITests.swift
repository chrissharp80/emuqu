import XCTest

/// History + Trends surface coverage.
///
/// Both views render off the same archive subscription, and on a fresh
/// install the archive is empty.
///
/// The History tab uses pagination (10 sessions at a time) and exposes
/// search / filter controls. Trends has period-switching controls
/// (1W / 1M / 3M / All Time) and a stat grid.
///
/// These tests assert the surfaces are reachable, render without crashing
/// and expose at least one interactive control. History has no entry point
/// until the archive holds a reading, so the History cases relaunch with
/// `-UITests-SeedArchive`, which has the app score one synthetic night
/// through its own morning pipeline and archive it before the first screen.
/// One case keeps the empty archive and asserts the Day-1 checklist is what
/// the user sees instead.
@MainActor
final class HistoryTrendsUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-UITests", "-UITests-FreshInstall"]
        app.launch()
        UITestLaunch.toMainUI(app)
    }

    override func tearDown() async throws {
        app = nil
    }

    /// Neither destination is a tab: History is reached from the Dashboard's
    /// Recent strip and Trends from the More menu (build plan §D4/§M1). A
    /// label-matching tab helper guarded by `XCTSkipUnless` skips every test
    /// in this class, which reads as green — the suite proves nothing about
    /// either surface.
    /// History's only route is the Recent strip's "View all" (build plan
    /// §D4), and the strip needs a reading. Relaunch with the seed, then open
    /// it; failing to reach History is a failure, not a skip.
    private func openHistoryWithSeededArchive() {
        app.terminate()
        app.launchArguments = ["-UITests", "-UITests-FreshInstall", "-UITests-SeedArchive"]
        app.launch()
        // The seed is scored before the first screen, so the disclaimer
        // arrives a few seconds after the tab bar; wait for it rather than
        // let the gate walk conclude there is nothing to dismiss.
        _ = app.buttons[UITestID.disclaimerAgree].waitForExistence(timeout: UITestTiming.s(30))
        UITestLaunch.toMainUI(app)
        XCTAssertTrue(
            UITestNav.openHistory(app),
            "History must be reachable from the Recent strip once the archive holds a reading — \(UITestFind.onScreen(app))"
        )
    }

    /// Trends, with one reading in the archive.
    ///
    /// The empty-archive cases below cannot reach the charts at all: with no
    /// sessions every series is empty and the view draws its placeholder. A
    /// single point is the case that actually breaks chart code — a domain
    /// whose lower and upper bounds are equal, a trend line through one
    /// sample, a "change since" with nothing to compare against.
    private func openTrendsWithSeededArchive() {
        app.terminate()
        app.launchArguments = ["-UITests", "-UITests-FreshInstall", "-UITests-SeedArchive"]
        app.launch()
        _ = app.buttons[UITestID.disclaimerAgree].waitForExistence(timeout: UITestTiming.s(30))
        UITestLaunch.toMainUI(app)
        openTrends()
    }

    private func openTrends() {
        XCTAssertTrue(UITestNav.openTrends(app),
                      "Trends must be reachable from More — \(UITestFind.onScreen(app))")
    }

    // MARK: - History

    /// With no reading there is no History entry point, and the Dashboard
    /// shows the Day-1 checklist in place of the Recent strip.
    func testEmptyArchiveShowsDay1ChecklistInsteadOfHistory() {
        let checklist = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "first recovery score")
        ).firstMatch
        XCTAssertTrue(checklist.waitForExistence(timeout: UITestTiming.s(5)),
                      "The Day-1 checklist must render on an empty archive — \(UITestFind.onScreen(app))")
        // Checked second: the route search scrolls the dashboard to the bottom.
        XCTAssertFalse(UITestNav.openHistory(app), "An empty archive must not offer a History entry point")
    }

    /// History renders once the archive holds a reading.
    func testHistoryRendersWithAReading() {
        openHistoryWithSeededArchive()
        // Look for at least one of: empty-state copy, list view, or scrollable
        // surface — none of which should crash on an empty archive.
        let landmarks: [NSPredicate] = [
            NSPredicate(format: "label CONTAINS[c] %@", "No sessions"),
            NSPredicate(format: "label CONTAINS[c] %@", "Take your first"),
            NSPredicate(format: "label CONTAINS[c] %@", "History")
        ]
        let listExists = app.scrollViews.firstMatch.waitForExistence(timeout: UITestTiming.s(5))
            || app.collectionViews.firstMatch.waitForExistence(timeout: UITestTiming.s(2))
        let copyExists = landmarks.contains { p in
            app.staticTexts.matching(p).firstMatch.waitForExistence(timeout: UITestTiming.s(1))
        }
        XCTAssertTrue(
            listExists || copyExists,
            "History tab must render either a list/scroll view or empty-state copy"
        )
    }

    /// History exposes a search field, and a query that matches nothing
    /// leaves the screen standing.
    func testHistorySearchWithNoMatchIsSafe() {
        openHistoryWithSeededArchive()
        let searchField = app.textFields[UITestID.historySearch]
        XCTAssertTrue(searchField.waitForExistence(timeout: UITestTiming.s(8)),
                      "History must expose its search field — \(UITestFind.onScreen(app))")
        searchField.tap()
        searchField.typeText("xyzunlikely")
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.exists, "Tab bar must persist after a search with no matches")
    }

    // MARK: - Trends

    /// Trends tab reachable + empty-state safe.
    func testTrendsTabRendersOnEmptyArchive() throws {
        openTrends()
        // Look for any chart or stat-grid landmark.
        let landmarks: [NSPredicate] = [
            NSPredicate(format: "label CONTAINS[c] %@", "Trends"),
            NSPredicate(format: "label CONTAINS[c] %@", "1W"),
            NSPredicate(format: "label CONTAINS[c] %@", "All Time"),
            NSPredicate(format: "label CONTAINS[c] %@", "RMSSD"),
            NSPredicate(format: "label CONTAINS[c] %@", "score")
        ]
        let copyExists = landmarks.contains { p in
            app.staticTexts.matching(p).firstMatch.waitForExistence(timeout: UITestTiming.s(1))
                || app.buttons.matching(p).firstMatch.waitForExistence(timeout: UITestTiming.s(1))
        }
        let scrollExists = app.scrollViews.firstMatch.waitForExistence(timeout: UITestTiming.s(5))
        XCTAssertTrue(
            copyExists || scrollExists,
            "Trends tab must render at least one period-control or scroll view"
        )
    }

    /// Switching the range chips on an empty archive must not crash.
    ///
    /// Was `app.buttons["1W"]` … `["All Time"]` behind an
    /// `XCTSkipUnless(tappedAny)`. `TrendsV2View.TimeRange` renders "7", "14",
    /// "30", "90", "All", so nothing ever matched and the test skipped every
    /// run — the one outcome that cannot catch a crash. Keyed to the range
    /// value now, and every chip must be present.
    func testTrendsPeriodSwitchOnEmptyArchive() {
        openTrends()
        for rangeValue in [7, 14, 30, 90, 0] {
            let chip = app.buttons["trends.range.\(rangeValue)"]
            XCTAssertTrue(chip.waitForExistence(timeout: UITestTiming.s(3)),
                          "Trends must expose the \(rangeValue)-day range chip — \(UITestFind.onScreen(app))")
            guard chip.exists, UITestFind.isSafelyHittable(chip, in: app) else { continue }
            chip.tap()
        }
        XCTAssertTrue(
            app.tabBars.firstMatch.exists,
            "Tab bar must persist through period-switch on empty archive"
        )
    }

    /// The same sweep with a reading present, which is a different code path:
    /// the charts have a series to plot and the stat grid has numbers to
    /// compute. Switching every range means each window gets asked for a
    /// domain — including the 7-day window, where one point is the whole
    /// dataset.
    func testTrendsPeriodSwitchWithAReading() {
        openTrendsWithSeededArchive()
        for rangeValue in [7, 14, 30, 90, 0] {
            let chip = app.buttons["trends.range.\(rangeValue)"]
            XCTAssertTrue(chip.waitForExistence(timeout: UITestTiming.s(5)),
                          "Trends must expose the \(rangeValue)-day range chip — \(UITestFind.onScreen(app))")
            UITestFind.tapSafely(chip, in: app)
        }
        XCTAssertTrue(
            app.tabBars.firstMatch.exists,
            "Tab bar must persist through a period-switch sweep with a reading archived"
        )
    }
}
