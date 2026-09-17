import XCTest

/// The sensor-management sheet.
///
/// ## Why this suite exists
///
/// Every reading the app produces comes from a paired strap, so "I can't get
/// my strap connected" is the failure that makes the whole app useless — and
/// this sheet is where the user goes to fix it. It lists the Polar strap, the
/// foot pod and the PM5, and it owns the pair / reconnect / disconnect
/// actions.
///
/// It had no UI coverage. Its route in is the strap pill in the Fitness tab's
/// sport row, which is exactly the kind of small, unlabelled control that
/// silently stops opening anything.
///
/// Nothing here taps "Pair a strap": `startScanning()` raises the system
/// Bluetooth permission alert, which a simulator answers for nobody and which
/// would then sit on top of every test that follows. The assertion is that
/// the affordance is present and reachable — the part that broke.
@MainActor
final class SensorSheetUITests: XCTestCase {

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

    private func openSensorSheet() {
        openFitnessTab()
        let pill = app.buttons[UITestID.fitnessStrapPill]
        XCTAssertTrue(
            pill.waitForExistence(timeout: UITestTiming.s(10)),
            "The Fitness tab's sport row must show the strap pill — \(UITestFind.onScreen(app))"
        )
        XCTAssertTrue(UITestFind.tapSafely(pill, in: app), "The strap pill must be tappable")
    }

    /// Asserted rather than skipped. The Fitness tab CAN be hidden — Settings
    /// → Modes → Hide Fitness tab — and `FitnessTabUITests` skips on that for
    /// good reason. This suite cannot be in that state: every case launches
    /// under `-UITests-FreshInstall`, so the setting is at its default and the
    /// tab is shown. A skip here could only ever fire when the default
    /// changed, and it would report that as green.
    private func openFitnessTab() {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: UITestTiming.s(8)), "Tab bar required")
        XCTAssertTrue(UITestNav.selectTab(app, identifier: UITestID.tabFitness, title: UITestID.tabFitnessTitle),
                      "A fresh install must show the Fitness tab — \(UITestFind.onScreen(app))")
    }

    private var sheetRoot: XCUIElement {
        app.descendants(matching: .any)[UITestID.sensorsRoot].firstMatch
    }

    // MARK: - Cases

    func testStrapPillOpensTheSensorSheet() {
        openSensorSheet()
        XCTAssertTrue(
            sheetRoot.waitForExistence(timeout: UITestTiming.s(10)),
            "Tapping the strap pill must present the sensor sheet — \(UITestFind.onScreen(app))"
        )
    }

    /// With nothing paired — the state every new user and every App Store
    /// reviewer is in — the sheet's job is to offer pairing. A sheet that
    /// renders three empty sections and no way forward is the dead end this
    /// asserts against.
    func testSheetOffersPairingWhenNoStrapIsKnown() {
        openSensorSheet()
        XCTAssertTrue(sheetRoot.waitForExistence(timeout: UITestTiming.s(10)))
        let pair = UITestFind.row(in: app, identifier: UITestID.sensorsPairStrap, label: "Pair")
        XCTAssertTrue(
            pair.waitForExistence(timeout: UITestTiming.s(8)),
            "With no strap paired the sheet must offer 'Pair a strap' — \(UITestFind.onScreen(app))"
        )
    }

    /// A sheet that cannot be dismissed traps the user in it. Swiped down
    /// rather than tapping Done, which carries only its localized title.
    func testSensorSheetDismissesBackToFitness() {
        openSensorSheet()
        XCTAssertTrue(sheetRoot.waitForExistence(timeout: UITestTiming.s(10)))
        app.swipeDown(velocity: .fast)
        let fitnessRoot = app.descendants(matching: .any)[UITestID.fitnessRoot].firstMatch
        XCTAssertTrue(
            fitnessRoot.waitForExistence(timeout: UITestTiming.s(10)),
            "Dismissing the sensor sheet must return to the Fitness tab — \(UITestFind.onScreen(app))"
        )
        XCTAssertTrue(app.tabBars.firstMatch.exists, "The tab bar must be reachable again")
    }
}
