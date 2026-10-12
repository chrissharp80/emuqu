import XCTest

/// AI Assistant tab coverage.
///
/// The Assistant owns: chat surface, disclaimer gate, prefab questions, model
/// picker, voice mode, provider consent sheet, medical-query guard.
///
/// This suite asserts the structural contract without sending real
/// requests (no API keys are configured in test runs). What we test:
///
///   • Tab reachable when enabled in this build.
///   • DisclaimerSheet presents on first open and is dismissible.
///   • Prefab-question chips render and are tappable.
///   • Composer / input field reachable.
///   • Empty-state copy renders before any messages exist.
///   • The chat surface tolerates "no API key configured" gracefully
///     (no crash, no blocking modal that can't be dismissed).
///
/// Every test launches as a fresh install, where enableAIAssistant
/// (Settings → Performance) is on, so a Flo tab that cannot be reached is a
/// failure, not a skip.
@MainActor
final class AssistantUITests: XCTestCase {

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

    /// Not a four-predicate guess over "Assistant" / "Coach" / "Flo" / "AI".
    /// The tab is titled "Flo"; "Coach" means the in-workout trigger voice and
    /// is not a tab at all. A fresh install has the tab, so not finding it
    /// fails the test (and, with `continueAfterFailure` off, stops it there).
    private func navigateToAssistant() {
        let found = UITestNav.selectTab(app, identifier: UITestID.tabCoach, title: UITestID.tabCoachTitle)
        XCTAssertTrue(found, "The Flo tab must be reachable on a fresh install — \(UITestFind.onScreen(app))")
    }

    /// After the disclosure, Flo shows something the user can ask through:
    /// the composer, the prefab chips (the only input with Apple's on-device
    /// model and no key), or the setup screen when no model is available.
    private func assertInputSurfaceIsShown(_ context: String) {
        // `TextField(axis: .vertical)` reports as a text view rather than a
        // text field once it can grow, so the composer is matched across
        // element types rather than as `textFields[...]`.
        let surfaces = [
            UITestFind.anyElement(in: app, identifier: UITestID.assistantComposer),
            UITestFind.anyElement(in: app, identifier: UITestID.assistantPrefabChips),
            UITestFind.anyElement(in: app, identifier: "assistant.setup")
        ]
        XCTAssertTrue(
            surfaces.contains { $0.waitForExistence(timeout: UITestTiming.s(8)) },
            "\(context): Flo must present a composer, its prefab chips or its setup screen — " +
                UITestFind.onScreen(app)
        )
    }

    // MARK: - Disclaimer flow

    /// The first time the user opens the Assistant, `DisclaimerSheet`
    /// presents with its disclosure, and it cannot be dismissed until
    /// acknowledged. A fresh install must show it, its accept button
    /// ("I understand — continue", found by identifier) must take it away,
    /// and Flo's input surface must be there behind it.
    func testFirstOpenPresentsDisclaimer() throws {
        navigateToAssistant()
        // Identified, not a label predicate, which would also match the
        // *health* disclaimer's CTA one layer down.
        XCTAssertTrue(
            UITestFind.acceptAssistantDisclaimer(app),
            "A fresh install must present the Flo disclosure and accept it — \(UITestFind.onScreen(app))"
        )
        assertInputSurfaceIsShown("After dismissing the disclaimer")
    }

    // MARK: - Prefab questions

    /// Above the input bar, the Assistant exposes a row of prefab
    /// questions ("How am I doing today?", etc.). We don't tap them
    /// — that would fire a real send if a provider is configured —
    /// but we assert at least one is rendered.
    func testPrefabQuestionsRender() throws {
        navigateToAssistant()
        UITestFind.acceptAssistantDisclaimer(app, timeout: UITestTiming.s(3))

        // The chips sit above the composer whenever a model can answer (with
        // Apple's on-device model and no key they are the only input). With no
        // model at all, Flo shows its setup screen instead of chips.
        if UITestFind.anyElement(in: app, identifier: "assistant.setup").waitForExistence(timeout: UITestTiming.s(3)) {
            return
        }
        XCTAssertTrue(
            UITestFind.anyElement(in: app, identifier: "assistant.prefabChips").waitForExistence(timeout: UITestTiming.s(5)),
            "The prefab-question row must render — \(UITestFind.onScreen(app))"
        )
        let first = NSPredicate(format: "label BEGINSWITH %@", "How am I doing today")
        XCTAssertTrue(
            app.buttons.matching(first).firstMatch.waitForExistence(timeout: UITestTiming.s(3))
                || app.staticTexts.matching(first).firstMatch.exists,
            "The first prefab question must be shown — \(UITestFind.onScreen(app))"
        )
    }

    // MARK: - No-API-key state

    /// Without any configured API key + with Apple Intelligence
    /// available, the chat tab must not present a blocking alert, and once
    /// the disclosure is accepted the user can reach the input surface; a
    /// failed send surfaces inline as a turn, not as a modal.
    func testNoAPIKeyDoesNotBlockChat() throws {
        navigateToAssistant()
        // The accept button sits at the end of a scrolling sheet; the helper
        // scrolls to it (a plain tap can land off-screen and leave the sheet up).
        XCTAssertTrue(
            UITestFind.acceptAssistantDisclaimer(app),
            "The Flo disclosure must be shown and accepted first — \(UITestFind.onScreen(app))"
        )
        // Wait briefly for any pending alert.
        let alert = app.alerts.firstMatch
        XCTAssertFalse(
            alert.waitForExistence(timeout: UITestTiming.s(2)),
            "Assistant must not present a blocking alert when no API key is configured"
        )
        assertInputSurfaceIsShown("With no API key")
        XCTAssertFalse(
            app.buttons[UITestID.assistantDisclaimerAccept].exists,
            "The disclosure is still up over the chat — \(UITestFind.onScreen(app))"
        )
    }
}
