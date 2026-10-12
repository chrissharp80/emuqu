import XCTest

/// A background → foreground round trip.
///
/// The app has no widget: this file once tested a widget publisher that no
/// longer exists, and what remained was this round trip, which is worth
/// keeping on its own. Going to the background runs the app's scene-phase
/// work (auto-archiving a pending session, stopping ambient location), and
/// coming back runs the rest (resuming sync, rescheduling the morning
/// notification, re-checking the entitlement). None of it may crash the app
/// or leave the UI unresponsive.
///
/// This suite asserts:
///
///   • After a Home press and re-activation the app is in the foreground
///     with the screen it was on — the Record tab, selected before
///     backgrounding — still showing. A crash and relaunch would not leave
///     it there: a relaunch under `-UITests-FreshInstall` starts again at the
///     first-run gates.
///   • The tab bar still takes a tap afterwards.
@MainActor
final class BackgroundForegroundUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-UITests-FreshInstall"] + UITestLanguage.english
        app.launch()
        UITestLaunch.toMainUI(app)
    }

    override func tearDown() async throws {
        app = nil
    }

    func testBackgroundForegroundCycleSurvives() {
        XCTAssertTrue(
            UITestNav.selectTab(app, identifier: UITestID.tabRecord, title: UITestID.tabRecordTitle),
            "The Record tab must open before backgrounding — \(UITestFind.onScreen(app))"
        )
        UITestLaunch.backgroundToPersist(app)

        XCTAssertEqual(app.state, .runningForeground, "The app must come back to the foreground")
        let recordContent = UITestFind.anyElement(in: app, identifier: UITestID.tabRecord)
        XCTAssertTrue(
            recordContent.waitForExistence(timeout: UITestTiming.s(8)),
            "The app must return to the Record tab it left, not relaunch — \(UITestFind.onScreen(app))"
        )
        XCTAssertTrue(
            UITestNav.selectTab(app, identifier: UITestID.tabDashboard, title: UITestID.tabDashboardTitle),
            "The tab bar must still respond after a foreground cycle — \(UITestFind.onScreen(app))"
        )
    }
}
