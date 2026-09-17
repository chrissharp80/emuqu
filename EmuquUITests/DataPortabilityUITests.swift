import XCTest

/// Getting data out of the app, and back in.
///
/// ## Why this suite exists
///
/// The app's privacy claim is that the data is the user's: it exports to CSV
/// and JSON and imports RR intervals from other tools. Both screens live two
/// taps inside Settings → Data, both were reachable by every user, and
/// neither had ever been opened by a test — `SettingsNavigationUITests` stops
/// at the Data page itself.
///
/// These cases open each screen and assert its controls are there. They stop
/// short of tapping Export: a real export writes a file and presents a
/// `UIActivityViewController`, a system sheet whose dismissal is not reliable
/// from the runner, and a share sheet left standing fails every test that
/// follows it in the class. The export ACTION is covered by unit tests over
/// the exporters; what was untested, and is tested here, is whether the user
/// can reach the button at all.
@MainActor
final class DataPortabilityUITests: XCTestCase {

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

    /// More → Settings → Data. Every case here starts from that page.
    private func openDataSettings() {
        XCTAssertTrue(UITestNav.openSettings(app),
                      "Settings must be reachable from More — \(UITestFind.onScreen(app))")
        let row = UITestNav.scrollTo(app, identifier: UITestID.settingsData, label: "Data")
        XCTAssertTrue(row.exists, "Settings must list the Data page — \(UITestFind.onScreen(app))")
        XCTAssertTrue(UITestFind.tapSafely(row, in: app), "The Data row must be tappable")
    }

    /// Both routes are `NavigationLink`s inside a `List`, so they can be
    /// below the fold on a small screen; scroll before judging them missing.
    private func openPortabilityRow(_ identifier: String, label: String) {
        openDataSettings()
        let row = UITestNav.scrollTo(app, identifier: identifier, label: label)
        XCTAssertTrue(row.exists,
                      "The Data page must list '\(label)' — \(UITestFind.onScreen(app))")
        XCTAssertTrue(UITestFind.tapSafely(row, in: app), "'\(label)' must be tappable")
    }

    // MARK: - Export

    func testExportScreenIsReachableFromSettings() {
        openPortabilityRow(UITestID.dataExport, label: "Export")
        let root = app.descendants(matching: .any)[UITestID.exportRoot].firstMatch
        XCTAssertTrue(
            root.waitForExistence(timeout: UITestTiming.s(10)),
            "Settings → Data → Export Data must open the export screen — \(UITestFind.onScreen(app))"
        )
    }

    /// RR intervals are the export that matters: they are the raw data every
    /// metric is recomputed from, and the only one that makes the archive
    /// portable rather than merely readable.
    func testExportScreenOffersTheRawIntervalExport() {
        openPortabilityRow(UITestID.dataExport, label: "Export")
        let rrExport = UITestFind.row(in: app, identifier: UITestID.exportRRIntervals, label: "RR Intervals")
        XCTAssertTrue(
            rrExport.waitForExistence(timeout: UITestTiming.s(10)),
            "The export screen must offer the RR-interval export — \(UITestFind.onScreen(app))"
        )
    }

    // MARK: - Import

    func testImportScreenIsReachableFromSettings() {
        openPortabilityRow(UITestID.dataImport, label: "Import")
        let selectFile = UITestFind.row(in: app, identifier: UITestID.importSelectFile, label: "Select File")
        XCTAssertTrue(
            selectFile.waitForExistence(timeout: UITestTiming.s(10)),
            "Settings → Data → Import must open a screen offering a file picker — \(UITestFind.onScreen(app))"
        )
    }

    /// The picker itself is a system `fileImporter`, so it is not tapped
    /// here — but the screen behind it has to survive being left and
    /// re-entered, which is the path a user takes after cancelling one.
    func testImportScreenSurvivesLeavingAndReturning() {
        openPortabilityRow(UITestID.dataImport, label: "Import")
        _ = app.descendants(matching: .any)[UITestID.importSelectFile].firstMatch
            .waitForExistence(timeout: UITestTiming.s(10))
        UITestNav.selectTab(app, identifier: UITestID.tabDashboard, title: UITestID.tabDashboardTitle)
        openPortabilityRow(UITestID.dataImport, label: "Import")
        let selectFile = UITestFind.row(in: app, identifier: UITestID.importSelectFile, label: "Select File")
        XCTAssertTrue(
            selectFile.waitForExistence(timeout: UITestTiming.s(10)),
            "The import screen must render again after leaving it — \(UITestFind.onScreen(app))"
        )
    }
}
