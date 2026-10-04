import XCTest

/// The morning results screen — the app's actual output.
///
/// ## Why this suite exists
///
/// Everything else the app does is in service of one screen: the recovery
/// score, the breakdown that explains it, and the metric cards under it.
/// `MorningResultsView` is what the user reads each morning, and History
/// re-opens the identical view for any past night.
///
/// The UI suite had never rendered it. Ninety tests walked the tab bar, the
/// settings tree and the empty states around it, and not one opened a
/// reading — because a fresh Debug install has no readings, and every route
/// in needs one. `-UITests-SeedArchive` removes that excuse: it scores one
/// synthetic night through `RRCollector.processOvernightData` — the real
/// pipeline, not a fixture — and archives it before the first screen.
///
/// So the screen that renders a NaN-clamped ring, a translated breakdown
/// message, a sleep card, a DFA card and a re-analysis panel was reachable by
/// every user on every morning and by no test on any run. A crash there is
/// the whole product; these cases are the ones that would say so.
///
/// Deliberately not covered here: re-analysis and PDF export, which spawn
/// long-running work and a share sheet the runner cannot dismiss reliably.
/// Their controls are snapshot-tested in `UncoveredScreenSnapshotTests`.
@MainActor
final class MorningResultsUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-UITests", "-UITests-FreshInstall", "-UITests-SeedArchive"] + UITestLanguage.english
        app.launch()
        // The seed is scored before the first screen, so the disclaimer can
        // arrive seconds after the tab bar. Wait for it rather than let the
        // gate walk conclude there is nothing to dismiss.
        _ = app.buttons[UITestID.disclaimerAgree].waitForExistence(timeout: UITestTiming.s(30))
        UITestLaunch.toMainUI(app)
    }

    override func tearDown() async throws {
        app = nil
    }

    // MARK: - The route in

    /// Dashboard → Recent strip → View all → the first row → the reading.
    ///
    /// Returns once the results screen is up, and fails the calling test at
    /// the step that actually broke rather than several assertions later.
    private func openSeededReading() {
        XCTAssertTrue(
            UITestNav.openHistory(app),
            "History must be reachable once the archive holds the seeded reading — \(UITestFind.onScreen(app))"
        )
        let row = app.descendants(matching: .any)[UITestID.historyEntryRow].firstMatch
        XCTAssertTrue(
            row.waitForExistence(timeout: UITestTiming.s(10)),
            "History must list the seeded reading — \(UITestFind.onScreen(app))"
        )
        XCTAssertTrue(UITestFind.tapSafely(row, in: app), "The reading's row must be tappable")
        XCTAssertTrue(
            resultsRoot.waitForExistence(timeout: UITestTiming.s(20)),
            "Tapping a reading must open its results — \(UITestFind.onScreen(app))"
        )
    }

    private var resultsRoot: XCUIElement {
        app.descendants(matching: .any)[UITestID.morningRoot].firstMatch
    }

    // MARK: - Cases

    /// The screen opens and stays up. That it opens as the readable body
    /// rather than the "not enough data" state is the next test's: the score
    /// ring renders only in the readable body.
    func testTappingAReadingOpensItsResults() {
        openSeededReading()
        XCTAssertTrue(resultsRoot.exists, "The results screen must stay up after presenting")
    }

    /// The hero ring is the one element the screen cannot be useful without.
    func testResultsShowTheRecoveryScoreCard() {
        openSeededReading()
        XCTAssertTrue(
            scoreRing.waitForExistence(timeout: UITestTiming.s(10)),
            "The recovery-score ring must render — \(UITestFind.onScreen(app))"
        )
    }

    private var scoreRing: XCUIElement {
        app.descendants(matching: .any)[UITestID.morningScoreRing].firstMatch
    }

    /// A ring with no number in it is the failure this catches: the score is
    /// clamped to a finite 0–100 precisely because a NaN would trap on the way
    /// to the ring, and a seeded night must come out the other side as a
    /// readable figure.
    ///
    /// Asserted against the ring's accessibility LABEL rather than a
    /// `staticTexts` match, because the ring is `accessibilityElement(children:
    /// .ignore)` — the number exists only inside that label, which is also the
    /// only form a VoiceOver user gets. The digits are ASCII in every locale
    /// (`Int` interpolation, not a formatter), so the pattern is not an
    /// English-copy match.
    func testTheScoreCardShowsANumericScore() {
        openSeededReading()
        XCTAssertTrue(
            scoreRing.waitForExistence(timeout: UITestTiming.s(10)),
            "The score ring must render — \(UITestFind.onScreen(app))"
        )
        let hasNumber = NSPredicate(format: "label MATCHES %@", ".*[0-9]+.*").evaluate(with: scoreRing)
        XCTAssertTrue(hasNumber, "The ring must announce a score; its label was '\(scoreRing.label)'")
    }

    /// The ⓘ next to the score opens "Understanding Your Score", the first
    /// thing a new user taps. It presents a sheet over the results; the
    /// results must survive its dismissal.
    func testScoreExplainerOpensAndCloses() {
        openSeededReading()
        // `anyElement`, not `buttons[...]`: the ⓘ is an `Image` in a
        // `.plain`-styled Button and does not surface under the buttons query.
        let explainer = UITestFind.anyElement(in: app, identifier: UITestID.morningScoreExplainer)
        XCTAssertTrue(
            explainer.waitForExistence(timeout: UITestTiming.s(10)),
            "The score card must offer its explainer — \(UITestFind.onScreen(app))"
        )
        XCTAssertTrue(UITestFind.tapSafely(explainer, in: app))
        dismissExplainer()
        XCTAssertTrue(
            resultsRoot.waitForExistence(timeout: UITestTiming.s(10)),
            "Closing the explainer must return to the results — \(UITestFind.onScreen(app))"
        )
    }

    /// The article's only dismissal is a toolbar Done, which SwiftUI renders
    /// with its localized title and no identifier. Swipe the sheet down
    /// instead: gesture-based, so it is the same in all 17 locales.
    private func dismissExplainer() {
        _ = app.scrollViews.firstMatch.waitForExistence(timeout: UITestTiming.s(5))
        app.swipeDown(velocity: .fast)
    }

    /// The screen is a tall stack of cards — sleep, HRV, DFA, training load,
    /// tags, export. Scrolling to the bottom renders every one of them, and a
    /// card that traps on the seeded night takes the app down here.
    ///
    /// One direction only, and not by accident: History presents these results
    /// in a sheet, so a downward swipe is a dismissal gesture, not a scroll.
    /// Scrolling back up dragged the sheet away and the assertion that
    /// followed reported a missing screen as if the app had died. Swipes are
    /// aimed at the scroll view rather than the application for the same
    /// reason.
    func testResultsScrollThroughEveryCardWithoutCrashing() {
        openSeededReading()
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: UITestTiming.s(10)),
                      "The results must render in a scroll view — \(UITestFind.onScreen(app))")
        for _ in 0 ..< 10 { scroll.swipeUp() }
        XCTAssertTrue(
            resultsRoot.exists,
            "The results must survive scrolling to the last card — \(UITestFind.onScreen(app))"
        )
    }

    /// A seeded reading is a real archived session, so the Dashboard shows a
    /// score rather than the Day-1 checklist. That checklist is what an empty
    /// archive renders (`HistoryTrendsUITests`), so its absence here is the
    /// evidence the seeded night reached the Dashboard's own surface.
    func testDashboardShowsTheReadingRatherThanTheDay1Checklist() {
        UITestNav.selectTab(app, identifier: UITestID.tabDashboard, title: UITestID.tabDashboardTitle)
        let dashboard = app.descendants(matching: .any)[UITestID.dashboardRoot].firstMatch
        XCTAssertTrue(
            dashboard.waitForExistence(timeout: UITestTiming.s(15)),
            "The Dashboard must render — \(UITestFind.onScreen(app))"
        )
        let checklist = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "first recovery score")
        ).firstMatch
        XCTAssertFalse(
            checklist.waitForExistence(timeout: UITestTiming.s(3)),
            "With a reading archived, the Dashboard must not show the Day-1 checklist"
        )
    }
}
