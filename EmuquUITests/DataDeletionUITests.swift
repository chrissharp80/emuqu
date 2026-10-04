import XCTest

/// Delete-All-Data flow coverage.
///
/// `DataPurgeService.purgeAllUserData(...)` is the GDPR / CCPA
/// "right to erasure" entry point, and a past bug (widget data wasn't
/// being purged) makes this surface critical.
///
/// This suite walks Settings → Advanced → Delete All Data and asserts:
///
///   • The destructive-action confirmation pattern fires (typed
///     confirmation string OR explicit second-tap-to-confirm).
///   • Tapping "Cancel" / dismissing returns the user to Settings
///     without firing the purge.
///   • The success summary surfaces every category the report tracks.
///
/// We do NOT actually fire the purge in CI because it touches the
/// shared App Group container that other tests in the run may
/// depend on. The test that reaches the confirmation step uses
/// `XCTSkipUnless` on the actual destructive button if a confirmation
/// gate isn't present.
@MainActor
final class DataDeletionUITests: XCTestCase {

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

    private func navigateToDeleteAllData() throws {
        // Not `tabBar.buttons["Settings"]` with a More fallback that queries
        // `app.buttons["Settings"]`: Settings is not a tab and the More row's
        // label is title-plus-subtitle, so both miss and an `XCTSkipUnless`
        // on them turns every test in this class into a skip.
        XCTAssertTrue(UITestNav.openSettings(app),
                      "Settings must be reachable — \(UITestFind.onScreen(app))")

        // Settings → Advanced Data Controls → Delete All My Data, by
        // identifier. The row labels are title-plus-subtitle, so the label
        // predicates this replaces matched nothing and the `XCTSkipUnless`
        // turned the whole class into skips.
        let advanced = UITestNav.scrollTo(app, identifier: UITestID.settingsAdvancedDataControls,
                                          label: "Advanced Data Controls")
        XCTAssertTrue(advanced.exists,
                      "Advanced Data Controls must be reachable — \(UITestFind.onScreen(app))")
        guard advanced.exists else { return }
        advanced.tap()

        let deleteRow = UITestFind.row(in: app, identifier: UITestID.settingsDeleteAllData,
                                       label: "Delete All My Data")
        XCTAssertTrue(deleteRow.waitForExistence(timeout: UITestTiming.s(5)),
                      "Advanced Data Controls must list the delete route — \(UITestFind.onScreen(app))")
        deleteRow.tap()
    }

    // MARK: - Confirmation gate

    /// The destructive-action page must require an explicit confirmation
    /// step before firing. This catches accidental wipes from a
    /// fat-fingered tap.
    func testDeleteAllDataRequiresConfirmation() throws {
        try navigateToDeleteAllData()
        // We're now on `DeleteAllDataPage`. The page must surface a
        // primary destructive button — we look for it but DO NOT tap
        // it. Then we look for a confirmation modal / typed-string
        // requirement.
        // The page is a `Form`, and the destructive button
        // sits below three explanatory sections, so on a 402 pt-wide phone it
        // is off-screen on arrival and not in the accessibility tree at all
        // until it scrolls in.
        var destructiveButton = UITestFind.anyElement(in: app, identifier: UITestID.deleteAllDataConfirmButton)
        for _ in 0 ..< 8 where !destructiveButton.exists {
            app.swipeUp()
            destructiveButton = UITestFind.anyElement(in: app, identifier: UITestID.deleteAllDataConfirmButton)
        }
        XCTAssertTrue(
            destructiveButton.waitForExistence(timeout: UITestTiming.s(5)),
            "Delete-All-Data page must surface a clearly-labeled destructive action — \(UITestFind.onScreen(app))"
        )
        // The gate itself, which is the point of the page:
        // the button is inert until the confirmation phrase has been typed
        // verbatim. Asserting only that the button *exists* would pass on a
        // build where the gate had been removed.
        XCTAssertFalse(
            destructiveButton.isEnabled,
            "The destructive button must stay disabled until the confirmation phrase is typed"
        )
        var confirmField = UITestFind.anyElement(in: app, identifier: UITestID.deleteAllDataConfirmField)
        for _ in 0 ..< 8 where !confirmField.exists {
            app.swipeUp()
            confirmField = UITestFind.anyElement(in: app, identifier: UITestID.deleteAllDataConfirmField)
        }
        XCTAssertTrue(
            confirmField.exists,
            "The page must ask for a typed confirmation phrase"
        )
        // The button must NOT be the only thing on screen — there
        // should be explanatory copy listing what's deleted (the
        // runbook list includes the widget purge).
        let copyPredicates: [NSPredicate] = [
            NSPredicate(format: "label CONTAINS[c] %@", "irreversible"),
            NSPredicate(format: "label CONTAINS[c] %@", "permanent"),
            NSPredicate(format: "label CONTAINS[c] %@", "cannot be undone"),
            NSPredicate(format: "label CONTAINS[c] %@", "remove")
        ]
        let warningExists = copyPredicates.contains { p in
            app.staticTexts.matching(p).firstMatch.waitForExistence(timeout: UITestTiming.s(2))
        }
        XCTAssertTrue(
            warningExists,
            "Delete-All-Data page must explain that the action is irreversible"
        )
    }

    /// Dismissing the page (back-nav, swipe, cancel) must return the
    /// user to Settings without firing the purge.
    func testDeleteAllDataCancelDoesNotFirePurge() throws {
        try navigateToDeleteAllData()
        let backButtons = app.navigationBars.buttons.allElementsBoundByIndex
        guard let back = backButtons.first else {
            throw XCTSkip("No navigation back button reachable in this layout")
        }
        back.tap()
        // Should be back at Settings — assert any Settings-page row
        // exists.
        let advancedRoot = UITestFind.row(in: app, identifier: UITestID.settingsDeleteAllData,
                                          label: "Delete All My Data")
        XCTAssertTrue(
            advancedRoot.waitForExistence(timeout: UITestTiming.s(5)),
            "Cancelling Delete-All-Data must return to the page it was opened from"
        )

        // The purge resets the disclaimer acceptance, so a relaunch that
        // keeps this run's state (no `-UITests-FreshInstall`) would open on
        // the disclaimer again had it fired.
        app.terminate()
        app.launchArguments = ["-UITests"] + UITestLanguage.english
        app.launch()
        XCTAssertFalse(
            app.buttons[UITestID.disclaimerAgree].waitForExistence(timeout: UITestTiming.s(5)),
            "Leaving Delete-All-Data reset the disclaimer — the purge ran"
        )
    }
}
