import XCTest

/// Settings sub-page coverage.
///
/// Settings owns 21+ sub-pages. This suite walks
/// every sub-page reachable from the Settings root and asserts:
///
///   • Tapping the row leaves the Settings root (the row is covered by the
///     pushed page or sheet).
///   • The app is still running in the foreground on the destination.
///   • Back navigation returns to the Settings root with the row tappable.
///
/// Each test is independent so a failure in one sub-page doesn't
/// cascade. Rows are found by accessibility identifier.
@MainActor
final class SettingsNavigationUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-UITests", "-UITests-FreshInstall"] + UITestLanguage.english
        app.launch()
        UITestLaunch.toMainUI(app)
        navigateToSettings()
    }

    override func tearDown() async throws {
        app = nil
    }

    // MARK: - Helpers

    /// More → Settings, by accessibility identifier.
    ///
    /// Not `tabBar.buttons["Settings"]` or `app.buttons["Settings"]` inside
    /// More. Neither matches: Settings is not a tab in the five-tab IA, and
    /// the More row's accessibility label is its title AND subtitle joined
    /// ("Settings, Profile, sources, modes, coach"), which an exact-match
    /// query misses. A miss runs every test in this suite against the More
    /// menu instead of Settings — the `mustExist: false` ones pass vacuously
    /// and the `mustExist: true` ones fail.
    private func navigateToSettings() {
        // Routed through the shared navigator, which taps
        // the tab and then confirms the switch actually took. Tapping once and
        // assuming is not safe: a tap can land while a transition is still in
        // flight and change nothing, and the failure then surfaces on a later
        // assertion pointing at the wrong screen.
        //
        // Wrapped in a relaunch loop. This runs in `setUp`, so it
        // executes once per test in the class — twenty-odd app launches per
        // run. `openSettings` already retries the tap internally, and that was
        // still not enough: on a loaded host a launch occasionally comes up
        // with the tab bar present but not yet driveable, and no amount of
        // tapping fixes that particular app instance. A fresh launch does.
        //
        // The loop asserts only after the last attempt, so a genuine
        // regression still fails — it just is not allowed to fail because one
        // launch out of twenty came up wedged.
        let attempts = 3
        for attempt in 1 ... attempts {
            if UITestNav.openSettings(app),
               UITestFind.row(in: app, identifier: UITestID.settingsProfile, label: "Profile")
               .waitForExistence(timeout: UITestTiming.s(5)) {
                return
            }
            guard attempt < attempts else { break }
            app.terminate()
            app.launch()
            _ = UITestLaunch.toMainUI(app)
        }
        XCTFail("Settings root should render after \(attempts) launches — \(UITestFind.onScreen(app))")
    }

    /// Walks a Settings row: scroll it into view, tap, assert the destination
    /// rendered, pop back.
    ///
    /// This replaces a second walker that matched rows by
    /// English label with `mustExist: false`, which was how sixteen of the
    /// eighteen tests in this class were written. `mustExist: false` means "if
    /// the row isn't found, pass anyway" — so every one of them passed without
    /// visiting the page it is named after. Every Settings root row now carries
    /// an identifier, so the permissive form is gone and the assertion is real.
    private func walkSubPage(
        identified identifier: String,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let row = scrolledIntoView(identifier: identifier, label: label)
        XCTAssertTrue(
            row.exists,
            "Settings row '\(identifier)' should exist — \(UITestFind.onScreen(app))",
            file: file, line: line
        )
        guard row.exists else { return }
        row.tap()

        // The Settings root already has a navigation bar and text, so neither
        // proves anything moved. The tapped row leaving the screen does: it
        // stops being hittable once a page is pushed (or a sheet covers it).
        XCTAssertTrue(
            waitUntil(UITestTiming.s(5)) { !row.exists || !row.isHittable },
            "'\(identifier)' tap did not leave the Settings root — \(UITestFind.onScreen(app))",
            file: file, line: line
        )
        XCTAssertEqual(app.state, .runningForeground, "'\(identifier)' destination crashed the app", file: file, line: line)

        popToSettingsRoot()
        let returned = scrolledIntoView(identifier: identifier, label: label)
        XCTAssertTrue(
            waitUntil(UITestTiming.s(5)) { returned.exists && returned.isHittable },
            "Back from '\(identifier)' did not return to the Settings root — \(UITestFind.onScreen(app))",
            file: file, line: line
        )
    }

    /// Polls `condition` until it holds or `timeout` passes.
    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    /// Settings is a long list, and a row below the fold is not in the
    /// accessibility tree at all until it scrolls in. See `UITestNav.scrollTo`.
    @discardableResult
    private func scrolledIntoView(identifier: String, label: String) -> XCUIElement {
        UITestNav.scrollTo(app, identifier: identifier, label: label)
    }

    private func popToSettingsRoot() {
        let backButtons = app.navigationBars.buttons.allElementsBoundByIndex
        if let back = backButtons.first, back.exists { back.tap() }
        _ = app.navigationBars.firstMatch.waitForExistence(timeout: UITestTiming.s(3))
    }

    // MARK: - Sub-page coverage

    /// Profile + Health: birthdate, fitness level, max HR, body weight, etc.
    func testProfileSubpageRenders() {
        walkSubPage(identified: UITestID.settingsProfile, label: "Profile")
    }

    /// Biometrics: HR-derived fields (max HR, resting HR, LTHR, FTP).
    func testBiometricsSubpageRenders() {
        walkSubPage(identified: UITestID.settingsBiometrics, label: "Biometrics")
    }

    /// Wearables: Polar pairing, foot pod, Concept2, Zwift broadcaster.
    func testWearablesSubpageRenders() {
        walkSubPage(identified: UITestID.settingsWearables, label: "Wearables")
    }

    /// Reports: PDF generation toggles, weekly Coach Report toggle.
    func testReportsSubpageRenders() {
        walkSubPage(identified: UITestID.settingsReports, label: "Reports")
    }

    /// Sleep: bedtime, sleep schedule, split-sleep merge gap.
    func testSleepSubpageRenders() {
        // Identifier, not `CONTAINS[c] "Sleep"` — that predicate matched the
        // "Connect Apple Health, For sleep + vitals" banner and then failed on
        // hittability, which read as a Settings regression rather than a test
        // targeting the wrong element.
        walkSubPage(identified: UITestID.settingsSleep, label: "Sleep")
    }

    /// Training: training-load integration toggle, training break editor.
    func testTrainingSubpageRenders() {
        walkSubPage(identified: UITestID.settingsTraining, label: "Training")
    }

    /// Modes: hide Fitness tab toggle, comeback mode editor.
    func testModesSubpageRenders() {
        walkSubPage(identified: UITestID.settingsModes, label: "Modes")
    }

    /// AI Assistant settings (skip when AI tab is disabled in this build).
    func testAIAssistantSubpageRenders() throws {
        // By identifier. The row is titled "Flo" and sits
        // under a section header that is also "Flo", so the old
        // `label CONTAINS[c] "Flo"` query matched the header — which is not
        // tappable — roughly as often as it matched the row.
        let row = UITestFind.row(in: app, identifier: UITestID.settingsFlo, label: "Flo")
        try XCTSkipUnless(row.waitForExistence(timeout: UITestTiming.s(3)),
                          "Flo (AI) disabled in this build; settings row hidden")
        row.tap()
        let navBar = app.navigationBars.firstMatch
        XCTAssertTrue(navBar.waitForExistence(timeout: UITestTiming.s(3)),
                      "Flo settings page must render a navigation bar")
        let backButtons = app.navigationBars.buttons.allElementsBoundByIndex
        if let back = backButtons.first { back.tap() }
    }

    /// Notifications: morning notification scheduler toggle, time picker.
    func testNotificationsSubpageRenders() {
        walkSubPage(identified: UITestID.settingsNotifications, label: "Notifications")
    }

    /// Appearance: light / dim / dark + accent color picker.
    func testAppearanceSubpageRenders() {
        walkSubPage(identified: UITestID.settingsAppearance, label: "Appearance")
    }

    /// Performance: feature flags, voice / watch / AI master switches.
    func testPerformanceSubpageRenders() {
        walkSubPage(identified: UITestID.settingsPerformance, label: "Performance")
    }

    /// Language: in-app language picker.
    func testLanguageSubpageRenders() {
        walkSubPage(identified: UITestID.settingsLanguage, label: "Language")
    }

    /// Advanced data controls + Troubleshooting (data wipe, debug log,
    /// keyboard performance capture).
    func testTroubleshootingSubpageRenders() {
        walkSubPage(identified: UITestID.settingsTroubleshooting, label: "Troubleshooting")
    }

    /// About / Help cluster: methodology, disclaimer, privacy policy,
    /// open-source notices.
    func testHelpCenterSubpageRenders() {
        walkSubPage(identified: UITestID.settingsHelpCenter, label: "Help & Learn")
    }

    /// Privacy Policy must always be reachable from Settings (App
    /// Store guideline 5.1.1).
    func testPrivacyPolicySubpageRenders() {
        walkSubPage(identified: UITestID.settingsPrivacyPolicy, label: "Privacy Policy")
    }

    /// Health Disclaimer re-accessible at any time.
    func testHealthDisclaimerSubpageRenders() {
        walkSubPage(identified: UITestID.settingsHealthDisclaimer, label: "Health Disclaimer")
    }

    /// Open Source Licenses (`AcknowledgementsView`). The row must
    /// navigate to the list of SPM dependencies.
    func testOpenSourceLicensesSubpageRenders() {
        // Was `cells CONTAINS[c] "Open Source"` behind an
        // `XCTSkipUnless`, and the row renders as a button, so this skipped
        // every run. App Store compliance depends on the page being reachable;
        // "not present in this build" was never an acceptable outcome.
        let target = scrolledIntoView(identifier: UITestID.settingsAcknowledgements, label: "Open Source")
        XCTAssertTrue(target.exists,
                      "Open Source Licenses must be reachable — \(UITestFind.onScreen(app))")
        guard target.exists else { return }
        target.tap()
        // Zip is the last entry in the list, so it is below
        // the fold on every device; waiting for it in place reports it missing.
        //
        // Completeness is not checked here — a hand-written list goes stale
        // (RxSwift stopped being a dependency when the Polar SDK moved to
        // 8.2.0) while `check_acknowledgements_complete.sh` compares every
        // entry against `Package.resolved`, which cannot. What this test owns
        // is that the page actually renders and scrolls to its last entry.
        let names = ["polar-ble-sdk", "swift-protobuf", "Zip"]
        for name in names {
            let pkg = app.staticTexts[name]
            var found = pkg.waitForExistence(timeout: UITestTiming.s(3))
            for _ in 0 ..< 10 where !found {
                app.swipeUp()
                found = pkg.exists
            }
            XCTAssertTrue(
                found,
                "AcknowledgementsView must list `\(name)`"
            )
        }
        let backButtons = app.navigationBars.buttons.allElementsBoundByIndex
        if let back = backButtons.first { back.tap() }
    }

    /// Delete-All-Data row reachable. The actual purge is exercised in
    /// `DataDeletionUITests`; here we just confirm the entry point.
    /// The previous version searched the Settings *root*
    /// for "Delete All Data", skipped when it wasn't there (it never is — the
    /// row lives one level down, under Advanced Data Controls) and then closed
    /// with `XCTAssertTrue(true)`. Two ways of asserting nothing in six lines.
    func testDeleteAllDataEntryReachable() {
        let advanced = scrolledIntoView(identifier: UITestID.settingsAdvancedDataControls,
                                        label: "Advanced Data Controls")
        XCTAssertTrue(advanced.exists,
                      "Advanced Data Controls must be reachable — \(UITestFind.onScreen(app))")
        guard advanced.exists else { return }
        advanced.tap()

        let deleteRow = UITestFind.row(in: app, identifier: UITestID.settingsDeleteAllData,
                                       label: "Delete All My Data")
        XCTAssertTrue(deleteRow.waitForExistence(timeout: UITestTiming.s(5)),
                      "Advanced Data Controls must list the delete route — \(UITestFind.onScreen(app))")
        popToSettingsRoot()
    }
}
