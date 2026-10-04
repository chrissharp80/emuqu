import XCTest

/// Appearance / Dark Mode coverage.
///
/// `SettingsManager.settings.appearanceTheme` controls the
/// `.preferredColorScheme(...)` modifier applied at the `WindowGroup`.
/// Reduce-Motion / Reduce-Transparency are honoured at view level; the
/// theme-switch surface needs its own coverage.
///
/// This suite exercises:
///
///   • Settings → Appearance is reachable.
///   • Theme picker exposes Light / Dim / Dark options.
///   • Picking a non-default option does not crash.
///
/// We don't pixel-compare colors — that's brittle and out of scope
/// for XCUITest. We assert structural correctness only.
@MainActor
final class AppearanceUITests: XCTestCase {

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

    private func navigateToAppearance() throws {
        // Not `tabBar.buttons["Settings"]` with a More fallback that queries
        // `app.buttons["Settings"]`: Settings is not a tab and the More row's
        // label is title-plus-subtitle, so both miss and an `XCTSkipUnless`
        // on them turns every test in this class into a skip.
        XCTAssertTrue(UITestNav.openSettings(app),
                      "Settings must be reachable — \(UITestFind.onScreen(app))")
        let entry = UITestNav.scrollTo(app, identifier: UITestID.settingsAppearance, label: "Appearance")
        XCTAssertTrue(entry.exists,
                      "Appearance must be reachable from Settings — \(UITestFind.onScreen(app))")
        guard entry.exists else { return }
        entry.tap()
    }

    /// Appearance page surfaces the theme controls.
    func testAppearancePageExposesThemeControls() throws {
        try navigateToAppearance()
        // Expect to find any of: "Light" / "Dim" / "Dark" labels.
        let predicates = [
            NSPredicate(format: "label CONTAINS[c] %@", "Light"),
            NSPredicate(format: "label CONTAINS[c] %@", "Dim"),
            NSPredicate(format: "label CONTAINS[c] %@", "Dark")
        ]
        let anyVisible = predicates.contains { p in
            app.staticTexts.matching(p).firstMatch.waitForExistence(timeout: UITestTiming.s(3))
                || app.buttons.matching(p).firstMatch.waitForExistence(timeout: UITestTiming.s(1))
        }
        XCTAssertTrue(
            anyVisible,
            "Appearance page must expose Light / Dim / Dark theme controls"
        )
    }

    /// Tapping a theme control must not crash — the
    /// `.preferredColorScheme` swap re-renders the entire window
    /// hierarchy, which is the riskiest moment for SwiftUI identity
    /// regressions.
    func testThemeSwitchDoesNotCrash() throws {
        try navigateToAppearance()
        let darkPredicate = NSPredicate(format: "label CONTAINS[c] %@", "Dark")
        let darkButton = app.buttons.matching(darkPredicate).firstMatch
        try XCTSkipUnless(
            darkButton.waitForExistence(timeout: UITestTiming.s(3)),
            "Dark mode button not exposed in this build"
        )
        UITestFind.tapSafely(darkButton, in: app)
        // Wait for any re-render. The tab bar should persist.
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: UITestTiming.s(5)),
                      "Tab bar must persist after theme switch")
    }
}
