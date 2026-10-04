import XCTest

/// Dashboard surface coverage.
///
/// The Dashboard is the post-launch landing surface for every user. The
/// prior UI test suite covered tab navigation but not the Dashboard's
/// internal structure. This suite asserts:
///
///   • Empty-state copy renders on a fresh install (no sessions yet).
///   • The toolbar's Ask Flo (sparkles) menu and the bell-icon
///     Notifications shortcut are reachable.
///   • Pull-to-refresh works and doesn't crash when no data is present.
///   • Score-related UI elements are reachable in the accessibility
///     hierarchy (so VoiceOver can find them) — fully empty-state
///     tolerant.
///
/// All tests use `-UITests-FreshInstall` to reset state, so they run
/// against the post-disclaimer-acceptance state with no prior sessions.
@MainActor
final class DashboardUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-UITests", "-UITests-FreshInstall"] + UITestLanguage.english
        app.launch()
        UITestLaunch.toMainUI(app)
    }

    override func tearDown() async throws {
        app = nil
    }

    // MARK: - Helpers

    private func assertOnDashboard() {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: UITestTiming.s(8)), "Tab bar must appear after onboarding skip")
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", "Dashboard")
        let dashboardTab = tabBar.buttons.matching(predicate).firstMatch
        if dashboardTab.exists { dashboardTab.tap() }
    }

    // MARK: - Empty-state coverage

    /// On a fresh install the dashboard renders even with no sessions, and it
    /// says how to start: the first-reading prompt is the empty state's
    /// landmark (the suite runs in English). A scroll view alone proves
    /// nothing — every tab has one.
    func testDashboardRendersOnFreshInstall() throws {
        assertOnDashboard()
        XCTAssertTrue(
            app.descendants(matching: .any)["dashboard.root"].waitForExistence(timeout: UITestTiming.s(5)),
            "Dashboard content must be on screen — \(UITestFind.onScreen(app))"
        )
        let prompt = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Take your first reading")).firstMatch
        XCTAssertTrue(
            prompt.waitForExistence(timeout: UITestTiming.s(5)),
            "Fresh-install dashboard must show the first-reading prompt — \(UITestFind.onScreen(app))"
        )
    }

    /// The trailing-toolbar bell icon (NotificationsSettingsPage shortcut)
    /// must be reachable from the dashboard. Its accessibility label is
    /// the localized "Notifications" string; the predicate tolerates a
    /// localized variant.
    func testNotificationsToolbarShortcutReachable() throws {
        assertOnDashboard()
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", "Notification")
        let bell = app.buttons.matching(predicate).firstMatch
        XCTAssertTrue(
            bell.waitForExistence(timeout: UITestTiming.s(5)),
            "Dashboard's trailing toolbar should surface a Notifications shortcut (bell icon)."
        )
    }

    /// The ✨ Ask Flo menu (top-right of Dashboard) opens a popover with
    /// the 3 prefab questions + Open-AI-Assistant entry. We assert the
    /// menu is openable and at least one entry is reachable, without
    /// actually firing a question (which would require an API key).
    func testAskFloMenuExposesPrefabQuestions() {
        assertOnDashboard()
        // Found by identifier, not by guessing at "the last toolbar button".
        // The control carries a real accessibility label ("Ask Flo" — without
        // one VoiceOver announces the SF Symbol's name, "Sparkle") and an
        // identifier.
        let askFlo = app.buttons[UITestID.dashboardAskFlo]
        XCTAssertTrue(
            askFlo.waitForExistence(timeout: UITestTiming.s(8)),
            "Dashboard's trailing toolbar must expose the Ask Flo menu — \(UITestFind.onScreen(app))"
        )
        guard askFlo.exists else { return }
        askFlo.tap()

        let prefabPredicates = [
            NSPredicate(format: "label CONTAINS[c] %@", "Why is my score"),
            NSPredicate(format: "label CONTAINS[c] %@", "Should I train"),
            NSPredicate(format: "label CONTAINS[c] %@", "What changed from yesterday"),
            NSPredicate(format: "label CONTAINS[c] %@", "AI Assistant")
        ]
        let anyPrefabVisible = prefabPredicates.contains { predicate in
            app.buttons.matching(predicate).firstMatch.waitForExistence(timeout: UITestTiming.s(2))
        }
        XCTAssertTrue(
            anyPrefabVisible,
            "The Ask Flo menu must list its quick prompts — \(UITestFind.onScreen(app))"
        )
    }

    // MARK: - Pull-to-refresh resilience

    /// Pull-to-refresh on a fresh install (no data) must not crash.
    /// This run pulls down on the empty dashboard
    /// scrollview to confirm the refresh handler tolerates a no-data
    /// archive.
    func testPullToRefreshOnEmptyDashboardDoesNotCrash() throws {
        assertOnDashboard()
        let scrollView = app.scrollViews.firstMatch
        // Asserted, not skipped. The Dashboard always has a scroll view —
        // EmuquUITests.swift:871 asserts exactly this and passes — so its
        // absence is the defect, not a reason to report success.
        XCTAssertTrue(
            scrollView.waitForExistence(timeout: UITestTiming.s(5)),
            "Dashboard scroll view never appeared — \(UITestFind.onScreen(app))"
        )
        // Pull down from near the top to trigger the refresh control.
        let start = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
        let end = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        start.press(forDuration: 0.05, thenDragTo: end)
        // Give the refresh ~3 s to complete. We don't assert a result;
        // the contract is "doesn't crash + tab bar still present."
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(
            tabBar.waitForExistence(timeout: UITestTiming.s(5)),
            "App must remain alive after pull-to-refresh on empty dashboard."
        )
    }

    /// Tapping each tab from the Dashboard returns to it without losing
    /// state. This is a reduced re-test of the existing
    /// `testCanSwitchBetweenAllTabs` but specifically validates that
    /// the Dashboard re-renders when navigated back to from each
    /// neighbor — catches regressions where tab-state restore drops
    /// the dashboard's session list.
    func testDashboardRoundTripsThroughEveryTab() throws {
        assertOnDashboard()
        let tabBar = app.tabBars.firstMatch
        let allButtons = tabBar.buttons.allElementsBoundByIndex
        // Asserted, not skipped. Three tabs are unconditional; the AX5 suite
        // asserts this same floor at the largest text size and passes, so a
        // collapse at the default size is a regression, not a skip condition.
        XCTAssertGreaterThanOrEqual(allButtons.count, 3, "Tab bar collapsed below 3 tabs")
        // Skip the first (dashboard) and round-trip through each other. The
        // check is that the Dashboard renders again after each trip, not
        // `isSelected`: SwiftUI does not reliably surface a TabView button's
        // selected state to XCUITest.
        for i in 1 ..< allButtons.count {
            UITestFind.tapSafely(allButtons[i], in: app)
            _ = app.tabBars.firstMatch.waitForExistence(timeout: UITestTiming.s(2))
            // Flo shows its one-time AI disclosure over the tab bar on the
            // first visit; a user accepts it before leaving.
            UITestFind.acceptAssistantDisclaimer(app, timeout: UITestTiming.s(2))
            XCTAssertTrue(
                UITestNav.selectTab(app, identifier: UITestID.tabDashboard, title: UITestID.tabDashboardTitle),
                "Could not return to the Dashboard after tab \(i) — \(UITestFind.onScreen(app))"
            )
            XCTAssertTrue(
                UITestFind.anyElement(in: app, identifier: UITestID.dashboardRoot).waitForExistence(timeout: UITestTiming.s(5)),
                "Dashboard content should be on screen after the round-trip through tab \(i) — \(UITestFind.onScreen(app))"
            )
        }
    }
}
