import XCTest

/// Permission-state coverage on a fresh install.
///
/// XCUITest cannot deny a permission ahead of time, and the app has no
/// launch argument that simulates a denied HealthKit, location or microphone
/// grant, so this suite cannot drive the denied state itself. What it
/// asserts is what a fresh install, which has granted nothing, must show:
///
///   • The Dashboard shows the first-reading prompt, not empty cards that
///     read as real zeroes.
///   • Opening Get Me Back shows its one-time disclaimer, its screen, its
///     location guidance or the system's location prompt — never nothing.
///
/// Voice mode is not entered: its first use raises the system microphone
/// prompt, which this suite cannot answer. That opening Flo raises no app
/// alert is `AssistantUITests.testNoAPIKeyDoesNotBlockChat`.
@MainActor
final class PermissionDenialUITests: XCTestCase {

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

    /// Swipes the screen up until `element` can be tapped.
    private func scrollUntilHittable(_ element: XCUIElement, attempts: Int = 6) -> Bool {
        for _ in 0 ..< attempts {
            if element.exists, element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }

    // MARK: - Fresh-install Dashboard

    /// Nothing is recorded and Apple Health has granted nothing, so the
    /// Dashboard must say how to start rather than show cards of zeroes.
    func testFreshInstallDashboardShowsTheFirstReadingPrompt() {
        XCTAssertTrue(
            UITestNav.selectTab(app, identifier: UITestID.tabDashboard, title: UITestID.tabDashboardTitle),
            "Dashboard tab must be selectable — \(UITestFind.onScreen(app))"
        )
        let prompt = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Take your first reading")).firstMatch
        XCTAssertTrue(
            prompt.waitForExistence(timeout: UITestTiming.s(8)),
            "A fresh install must show the first-reading prompt — \(UITestFind.onScreen(app))"
        )
    }

    // MARK: - Get Me Back without a location grant

    /// Location has not been granted on a fresh install. Tapping Get Me Back
    /// must lead somewhere: its one-time disclaimer, its location guidance,
    /// or the system's location prompt.
    func testGetMeBackRespondsWithoutALocationGrant() {
        XCTAssertTrue(
            UITestNav.selectTab(app, identifier: UITestID.tabFitness, title: UITestID.tabFitnessTitle),
            "Fitness tab must be selectable — \(UITestFind.onScreen(app))"
        )
        let tile = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Get Me Back")).firstMatch
        XCTAssertTrue(scrollUntilHittable(tile), "Get Me Back tile must be on the Fitness tab")
        tile.tap()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let disclaimer = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "I understand")).firstMatch
        let guidance = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Get Me Back needs location")).firstMatch
        let screen = app.navigationBars["Get Me Back"]
        let responded = disclaimer.waitForExistence(timeout: UITestTiming.s(5))
            || guidance.exists || screen.exists || springboard.alerts.firstMatch.exists
        XCTAssertTrue(responded, "Get Me Back did nothing without a location grant — \(UITestFind.onScreen(app))")
    }
}
