import XCTest

/// Widget integration coverage from the iOS app side.
///
/// XCUITest cannot drive the home-screen widget directly (the widget
/// runs in its own extension process and SpringBoard owns the home
/// screen). What we CAN test from the iOS app side is whether the
/// publisher path runs without crashing, since
/// `WidgetDataPublisher.publishToday(...)` calls
/// `WidgetCenter.shared.reloadAllTimelines()` which invokes the
/// extension. If the App Group identifier is wrong or
/// the extension panics on read, the publisher call itself doesn't
/// crash — but downstream events do.
///
/// This suite asserts:
///
///   • Adding the widget doesn't crash the iOS app process. We can't
///     add the widget programmatically, but we can verify the iOS
///     app survives a backgrounding round-trip — which is when iOS
///     evaluates whether to ask the widget extension to re-render.
///
/// The structural tests (suite-name pin, round-trip read/write) live
/// in the unit-test target's `WidgetDataPublisherTests.swift`.
@MainActor
final class WidgetIntegrationUITests: XCTestCase {

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

    /// Backgrounding + foregrounding is the most common path that
    /// triggers a WidgetCenter timeline reload. A round-trip should
    /// not crash the iOS app process or kick it out of the test
    /// session.
    func testBackgroundForegroundCycleSurvives() throws {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: UITestTiming.s(8)))
        // Send to background.
        XCUIDevice.shared.press(.home)
        // Brief wait — let the system process the backgrounding.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(springboard.waitForExistence(timeout: UITestTiming.s(5)),
                      "Home screen must appear after backgrounding")
        // Re-activate.
        app.activate()
        XCTAssertTrue(
            tabBar.waitForExistence(timeout: UITestTiming.s(8)),
            "App must rehydrate the tab bar after a foreground cycle " +
            "(WidgetCenter.reloadAllTimelines fires here on real devices)"
        )
    }
}
