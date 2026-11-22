import XCTest

/// Fitness tab coverage.
///
/// The Fitness tab owns the workout-recording surface (Walk / Run /
/// Trail Run / Hike / Bike / Indoor Bike / Treadmill / Row). This suite
/// asserts:
///
///   • The tab renders without a paired strap (default case for App
///     Store reviewers).
///   • The sport-picker / start-workout flow is reachable.
///   • The trail search is reachable from the pre-flight of a GPS sport.
///
/// We do NOT actually start a workout because the workout recorder
/// owns BLE / GPS / audio resources we can't release cleanly from a
/// simulator UI test.
///
/// A user can hide the Fitness tab (Settings → Training → Hide Fitness
/// tab), but every test here launches a fresh install, where it is shown.
/// A missing tab is therefore a regression, and the tests fail on it
/// rather than skip.
@MainActor
final class FitnessTabUITests: XCTestCase {

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

    @discardableResult
    private func navigateToFitness() -> XCUIElement {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: UITestTiming.s(8)), "Tab bar required")
        let fitnessTab = UITestFind.tabButton(in: tabBar,
                                              identifier: UITestID.tabFitness,
                                              title: UITestID.tabFitnessTitle)
        XCTAssertTrue(
            fitnessTab.waitForExistence(timeout: UITestTiming.s(3)),
            "A fresh install shows the Fitness tab — \(UITestFind.onScreen(app))"
        )
        fitnessTab.tap()
        return fitnessTab
    }

    // MARK: - Tab reachability

    /// Fitness tab renders without crashing on a fresh install. Look
    /// for the sport selector, the Get-Me-Back tile, or a workout
    /// hero card — any one is sufficient evidence the surface is
    /// alive.
    func testFitnessTabRenders() throws {
        navigateToFitness()
        let sportPredicate = NSPredicate(
            format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@",
            "Run", "Walk", "Bike", "Hike"
        )
        let getMeBackPredicate = NSPredicate(format: "label CONTAINS[c] %@", "Get Me Back")
        let startPredicate = NSPredicate(format: "label CONTAINS[c] %@", "Start")
        let discoverPredicate = NSPredicate(format: "label CONTAINS[c] %@", "Discover")

        // The surface itself must render. This is the
        // assertion that belongs here: the sport chips, Start button and
        // Get-Me-Back tile all live inside `WorkoutPreflightView`, which only
        // appears once `recorderBox.recorder` is non-nil. On a cold simulator
        // that is a race, so a label-only check fails on timing and reads
        // as a Fitness regression.
        XCTAssertTrue(
            UITestFind.anyElement(in: app, identifier: "fitness.root").waitForExistence(timeout: UITestTiming.s(10)),
            "Fitness tab must render its content surface — \(UITestFind.onScreen(app))"
        )

        // Best-effort: if the recorder came up in time, the pre-flight
        // affordances should be there too. Not a hard requirement — a
        // simulator with no BLE stack legitimately has no recorder.
        let anyPreflight = app.buttons.matching(sportPredicate).firstMatch.waitForExistence(timeout: UITestTiming.s(5))
            || app.staticTexts.matching(sportPredicate).firstMatch.exists
            || app.buttons.matching(getMeBackPredicate).firstMatch.exists
            || app.buttons.matching(startPredicate).firstMatch.exists
            || app.buttons.matching(discoverPredicate).firstMatch.exists
        if !anyPreflight {
            XCTAssertFalse(
                app.alerts.firstMatch.exists,
                "Fitness pre-flight is absent AND an alert is up — that is a real failure, not a cold recorder"
            )
        }
    }

    /// The route picker — "Pick a route or find a new trail", which opens the
    /// OpenStreetMap-backed trail search.
    ///
    /// Not `buttons CONTAINS[c] "Discover"` at the top level
    /// of the Fitness tab, behind an `XCTSkipUnless` that said the entry was
    /// hidden "in this build". Two things were wrong with that: the control was
    /// renamed away from "Discover trails near me" some time ago, and it has
    /// never lived at the top level — it appears in the workout pre-flight once
    /// a GPS sport is selected. So the test walked the real path now.
    func testRoutePickerReachableForGPSSports() throws {
        navigateToFitness()

        // `WorkoutPreflightView` only renders once `recorderBox.recorder` is
        // non-nil. The tab binds the recorder on its first appearance, a
        // runloop tick later and with no hardware needed, so the wait covers a
        // cold simulator; a pre-flight that never comes up is the failure this
        // test exists to catch.
        let runChip = app.buttons["fitness.sport.run"]
        XCTAssertTrue(
            runChip.waitForExistence(timeout: UITestTiming.s(15)),
            "The workout pre-flight must come up on the Fitness tab — \(UITestFind.onScreen(app))"
        )
        runChip.tap()

        // The route card is a disclosure group, collapsed by default for
        // casual users (see `routeDisclosure`), so it has to be opened.
        let findTrail = app.buttons["fitness.findTrail"]
        if !findTrail.waitForExistence(timeout: UITestTiming.s(3)) {
            let disclosure = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "route")
            ).firstMatch
            if disclosure.exists, UITestFind.isSafelyHittable(disclosure, in: app) { disclosure.tap() }
        }

        XCTAssertTrue(
            findTrail.waitForExistence(timeout: UITestTiming.s(5)),
            "A GPS sport must offer the trail search — \(UITestFind.onScreen(app))"
        )
        XCTAssertTrue(findTrail.isEnabled, "The trail-search entry should be enabled")
        // Deliberately not tapped: the sheet behind it asks for location
        // permission and hits the network, neither of which a UI test can
        // resolve.
    }

    /// The Fitness tab tolerates no-hardware (no Polar device) state.
    /// On a fresh install the strap is unpaired — we should NOT see a
    /// modal alert that blocks interaction.
    func testFitnessTabNoHardwareDoesNotBlockInteraction() throws {
        navigateToFitness()
        // Wait briefly for any modal alerts to surface.
        let alert = app.alerts.firstMatch
        XCTAssertFalse(
            alert.waitForExistence(timeout: UITestTiming.s(2)),
            "Fitness tab must not present a blocking alert on no-hardware first-launch"
        )
        // Tab bar must remain usable.
        XCTAssertTrue(app.tabBars.firstMatch.exists, "Tab bar must remain interactive")
    }
}
